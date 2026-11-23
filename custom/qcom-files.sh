#!/usr/bin/env bash
# qcom-files.sh
# Installs Qualcomm config files and enables services.
# Runs as root inside the debos chroot (no sudo needed).
set -eu

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# ---------------------------------------------------------------------------
# 1. Install config files
# ---------------------------------------------------------------------------
copy_file() {
    source_file="$SRC/$1"
    destination="$2"
    mode="$3"

    if [ ! -f "$source_file" ]; then
        echo "ERROR: Missing source file: $source_file" >&2
        exit 1
    fi

    install -D -m "$mode" "$source_file" "$destination"
    echo "Installed: $destination"
}

echo "Installing Qualcomm configuration files..."

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
# 2. Enable (and start, if systemd is actually running) services
#    Looks for each unit in the system and user unit directories and uses
#    the matching enable command.
# ---------------------------------------------------------------------------
SYS_DIRS="/etc/systemd/system /usr/lib/systemd/system /lib/systemd/system"
USER_DIRS="/etc/systemd/user /usr/lib/systemd/user /lib/systemd/user"

# systemd is only "live" on a booted system, not in a debos chroot.
if [ -d /run/systemd/system ]; then LIVE=1; else LIVE=0; fi

# Prints "system" or "user"; fails if the unit isn't installed anywhere.
find_unit() {
    for d in $SYS_DIRS; do
        if [ -f "$d/$1" ]; then echo system; return 0; fi
    done
    for d in $USER_DIRS; do
        if [ -f "$d/$1" ]; then echo user; return 0; fi
    done
    return 1
}

enable_unit() {
    unit=$1
    case "$unit" in
        *.service|*.socket|*.timer) ;;
        *) unit="$unit.service" ;;
    esac

    if ! scope=$(find_unit "$unit"); then
        echo "WARNING: $unit is not installed anywhere, skipping" >&2
        return 0
    fi

    if [ "$scope" = system ]; then
        if systemctl enable "$unit"; then
            echo "Enabled (system): $unit"
            if [ "$LIVE" = 1 ]; then
                systemctl start "$unit" || echo "WARNING: could not start $unit" >&2
            fi
        else
            echo "ERROR: failed to enable $unit" >&2
            return 1
        fi
    else
        # User units are enabled for all users via /etc/systemd/user and
        # start at login (default.target); they can't be started from root.
        if systemctl --global enable "$unit"; then
            echo "Enabled (user, all users): $unit"
        else
            echo "ERROR: failed to enable $unit" >&2
            return 1
        fi
    fi
}

echo
echo "Enabling services..."
if [ "$LIVE" = 1 ]; then systemctl daemon-reload; fi

rc=0
for u in \
    call_audio_idle_suspend_workaround \
    q6voiced \
    81voltd \
    qbootctl \
    touch-autobind \
    touch-rebind
do
    enable_unit "$u" || rc=1
done

# ---------------------------------------------------------------------------
# 3. SSH server (always set up; skip with ENABLE_SSH=0)
#    Login method:
#      - custom/authorized_keys present -> key login (password login off)
#      - no authorized_keys file        -> password login (the -p password)
#    Optional env: SSH_USER (default: the user with UID 1000, normally mobian),
#                  SSH_PASSWORD_AUTH=yes|no (override), ENABLE_SSH=0 (skip)
# ---------------------------------------------------------------------------
if [ "${ENABLE_SSH:-1}" = 1 ]; then
    SSH_USER="${SSH_USER:-$(getent passwd 1000 | cut -d: -f1)}"
    SSH_USER="${SSH_USER:-mobian}"
    if [ -f "$SRC/authorized_keys" ]; then
        SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-no}"
    else
        SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-yes}"
        echo "No authorized_keys found: enabling password login for '$SSH_USER'."
    fi

    echo
    echo "Setting up SSH for user '$SSH_USER'..."

    id "$SSH_USER" >/dev/null 2>&1 || {
        echo "ERROR: user '$SSH_USER' does not exist in the image" >&2
        exit 1
    }

    if [ ! -f "$SRC/authorized_keys" ] && [ "$SSH_PASSWORD_AUTH" != yes ]; then
        echo "ERROR: $SRC/authorized_keys is missing and password login is off;" >&2
        echo "       you would not be able to log in." >&2
        exit 1
    fi

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server

    # Drop-in (Debian's sshd_config includes sshd_config.d/*.conf at the top;
    # first value wins, hence the low number)
    install -d -m 755 /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/01-mobian.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication ${SSH_PASSWORD_AUTH}
PermitRootLogin no
EOF
    chmod 644 /etc/ssh/sshd_config.d/01-mobian.conf

    # authorized_keys
    SSH_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
    install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$SSH_HOME/.ssh"
    if [ -f "$SRC/authorized_keys" ]; then
        install -m 600 -o "$SSH_USER" -g "$SSH_USER" \
            "$SRC/authorized_keys" "$SSH_HOME/.ssh/authorized_keys"
        echo "Installed: $SSH_HOME/.ssh/authorized_keys"
    fi
    chown -R "$SSH_USER:$SSH_USER" "$SSH_HOME/.ssh"

    # Every image would otherwise share the same host keys: regenerate on first boot
    rm -f /etc/ssh/ssh_host_*
    cat > /etc/systemd/system/ssh-hostkeys.service <<EOF
[Unit]
Description=Generate SSH host keys on first boot
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF

    sshd -t || { echo "ERROR: sshd config check failed" >&2; exit 1; }
    systemctl enable ssh-hostkeys.service ssh.service
    echo "SSH enabled."
fi

if [ "$rc" -ne 0 ]; then
    echo "One or more services failed to enable (see errors above)." >&2
fi
exit "$rc"
