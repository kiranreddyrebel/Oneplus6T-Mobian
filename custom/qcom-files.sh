
#!/usr/bin/env bash
# qcom-files.sh
# Qualcomm configuration and SSH setup for Mobian OnePlus 6T.
# Runs as root inside the Debos chroot.

set -Eeuo pipefail

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log() {
    echo
    echo "[$(date '+%F %T')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Verify root and required commands
# ---------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "This script must run as root."

for cmd in install systemctl apt-get getent ssh-keygen sshd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [ "$cmd" = sshd ] || [ "$cmd" = ssh-keygen ]; then
            continue
        fi
        die "Required command not found: $cmd"
    fi
done

# ---------------------------------------------------------------------------
# 2. Install Qualcomm configuration files
# ---------------------------------------------------------------------------

copy_file() {
    local source_file="$SRC/$1"
    local destination="$2"
    local mode="$3"

    [ -f "$source_file" ] || die "Missing source file: $source_file"

    install -D -m "$mode" "$source_file" "$destination"
    echo "Installed: $destination"
}

log "Installing Qualcomm configuration files..."

copy_file UPower.conf \
    /etc/UPower/UPower.conf.d/50-soc-qcom.conf 644

copy_file 51-qcom.conf \
    /usr/share/wireplumber/wireplumber.conf.d/51-qcom.conf 644

copy_file gstreamer.conf \
    /etc/environment.d/50-soc-qcom-gstreamer.conf 644

copy_file call_audio_idle_suspend_workaround.sh \
    /usr/sbin/call_audio_idle_suspend_workaround.sh 755

copy_file call_audio_idle_suspend_workaround.service \
    /usr/lib/systemd/user/call_audio_idle_suspend_workaround.service 644

# ---------------------------------------------------------------------------
# 3. Enable Qualcomm services
# ---------------------------------------------------------------------------

SYS_DIRS="/etc/systemd/system /usr/lib/systemd/system /lib/systemd/system"
USER_DIRS="/etc/systemd/user /usr/lib/systemd/user /lib/systemd/user"

if [ -d /run/systemd/system ]; then
    LIVE=1
else
    LIVE=0
fi

find_unit() {
    local unit="$1"
    local d

    for d in $SYS_DIRS; do
        if [ -f "$d/$unit" ]; then
            echo system
            return 0
        fi
    done

    for d in $USER_DIRS; do
        if [ -f "$d/$unit" ]; then
            echo user
            return 0
        fi
    done

    return 1
}

enable_unit() {
    local unit="$1"
    local scope

    case "$unit" in
        *.service|*.socket|*.timer) ;;
        *) unit="$unit.service" ;;
    esac

    if ! scope=$(find_unit "$unit"); then
        echo "WARNING: $unit not installed; skipping."
        return 0
    fi

    if [ "$scope" = system ]; then
        if systemctl enable "$unit"; then
            echo "Enabled system service: $unit"

            if [ "$LIVE" = 1 ]; then
                systemctl start "$unit" ||
                    echo "WARNING: Could not start $unit"
            fi
        else
            echo "ERROR: Failed to enable $unit" >&2
            return 1
        fi
    else
        if systemctl --global enable "$unit"; then
            echo "Enabled user service: $unit"
        else
            echo "ERROR: Failed to enable user service $unit" >&2
            return 1
        fi
    fi
}

log "Enabling Qualcomm services..."

if [ "$LIVE" = 1 ]; then
    systemctl daemon-reload
fi

rc=0

for unit in \
    call_audio_idle_suspend_workaround \
    q6voiced \
    81voltd \
    qbootctl \
    touch-autobind \
    touch-rebind
do
    enable_unit "$unit" || rc=1
done

# ---------------------------------------------------------------------------
# 4. Install and configure OpenSSH
# ---------------------------------------------------------------------------

if [ "${ENABLE_SSH:-1}" = 1 ]; then

    log "Installing OpenSSH server..."

    SSH_USER="${SSH_USER:-$(getent passwd 1000 | cut -d: -f1 || true)}"
    SSH_USER="${SSH_USER:-mobian}"

    if [ -f "$SRC/authorized_keys" ]; then
        SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"
    else
        SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-yes}"
        echo "No authorized_keys found: password authentication enabled."
    fi

    case "$SSH_PASSWORD_AUTH" in
        yes|no) ;;
        *) die "SSH_PASSWORD_AUTH must be yes or no." ;;
    esac

    id "$SSH_USER" >/dev/null 2>&1 ||
        die "SSH user does not exist: $SSH_USER"

    if [ ! -f "$SRC/authorized_keys" ] &&
       [ "$SSH_PASSWORD_AUTH" = no ]; then
        die "authorized_keys missing while password authentication is disabled."
    fi

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y --no-install-recommends openssh-server

    command -v sshd >/dev/null 2>&1 ||
        die "OpenSSH server installation failed: sshd not found."

    # Configure SSH
    install -d -m 755 /etc/ssh/sshd_config.d

    cat > /etc/ssh/sshd_config.d/01-mobian.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication ${SSH_PASSWORD_AUTH}
PermitRootLogin no
EOF

    chmod 644 /etc/ssh/sshd_config.d/01-mobian.conf

    # Configure authorized_keys
    SSH_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
    SSH_GROUP=$(id -gn "$SSH_USER")

    [ -n "$SSH_HOME" ] || die "SSH home directory is empty."

    install -d -m 700 -o "$SSH_USER" -g "$SSH_GROUP" \
        "$SSH_HOME/.ssh"

    if [ -f "$SRC/authorized_keys" ]; then
        install -m 600 -o "$SSH_USER" -g "$SSH_GROUP" \
            "$SRC/authorized_keys" \
            "$SSH_HOME/.ssh/authorized_keys"

        echo "Installed authorized_keys."
    fi

    chown -R "$SSH_USER:$SSH_GROUP" "$SSH_HOME/.ssh"

    # -------------------------------------------------------
    # Prepare runtime directory and temporary host keys
    # -------------------------------------------------------

    log "Preparing SSH configuration validation..."

    install -d -m 755 /run/sshd
    install -d -m 755 /etc/ssh

    ssh-keygen -A

    # Validate the SSH configuration
    if ! sshd -t; then
        rm -f /etc/ssh/ssh_host_*
        die "OpenSSH configuration validation failed."
    fi

    echo "OpenSSH configuration validation successful."

    # Remove temporary host keys so each device gets unique keys.
    rm -f /etc/ssh/ssh_host_*

    # Remove temporary runtime directory.
    rmdir /run/sshd 2>/dev/null || true

    # -------------------------------------------------------
    # First boot host-key generation service
    # -------------------------------------------------------

    cat > /etc/systemd/system/ssh-hostkeys.service <<'EOF'
[Unit]
Description=Generate SSH host keys on first boot
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service
RequiresMountsFor=/etc/ssh

[Service]
Type=oneshot
ExecStartPre=/usr/bin/install -d -m 755 /run/sshd
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/ssh-hostkeys.service

    # Enable both services
    systemctl enable ssh-hostkeys.service ssh.service

    log "OpenSSH server configured successfully."
fi

# ---------------------------------------------------------------------------
# 5. Mask unwanted services
# ---------------------------------------------------------------------------

log "Masking unwanted services..."

for unit in alsa-restore.service; do
    if systemctl mask "$unit"; then
        echo "Masked: $unit"
    else
        echo "WARNING: Could not mask $unit" >&2
    fi
done

# ---------------------------------------------------------------------------
# 6. Modem wakeup udev rule
# ---------------------------------------------------------------------------

log "Installing Qualcomm modem wakeup rule..."

install -d -m 755 /etc/udev/rules.d

cat > /etc/udev/rules.d/90-qcom-modem-wakeup.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="rpmsg", KERNEL=="4080000.remoteproc:glink-edge.IPCRTR.-1.-1", ATTR{power/wakeup}="enabled"
EOF

chmod 644 /etc/udev/rules.d/90-qcom-modem-wakeup.rules

echo "Installed modem wakeup rule."

# ---------------------------------------------------------------------------
# 7. Final validation
# ---------------------------------------------------------------------------

log "Running final validation..."

[ -x /usr/sbin/call_audio_idle_suspend_workaround.sh ] ||
    die "Audio workaround script is missing or not executable."

[ -f /etc/udev/rules.d/90-qcom-modem-wakeup.rules ] ||
    die "Modem wakeup rule is missing."

if [ "${ENABLE_SSH:-1}" = 1 ]; then
    [ -f /etc/systemd/system/ssh-hostkeys.service ] ||
        die "SSH host-key service is missing."

    [ -f /etc/systemd/system/multi-user.target.wants/ssh-hostkeys.service ] ||
        die "SSH host-key service is not enabled."

    [ -f /etc/systemd/system/multi-user.target.wants/ssh.service ] ||
        [ -L /etc/systemd/system/multi-user.target.wants/ssh.service ] ||
        die "SSH service is not enabled."
fi

if [ "$rc" -ne 0 ]; then
    die "One or more Qualcomm services failed to enable."
fi

log "All Qualcomm configuration tasks completed successfully."

exit 0
