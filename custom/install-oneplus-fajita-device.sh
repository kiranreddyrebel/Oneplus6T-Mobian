#!/usr/bin/env bash
# install-oneplus-fajita-device.sh
# Debian port of the postmarketOS device-oneplus-fajita APKBUILD (OnePlus 6T).
# Run AFTER install-oneplus-sdm845-firmware.sh.
set -uo pipefail

DEVICE="device-oneplus-fajita"
BRANCH="master"
BASE="https://gitlab.com/postmarketOS/pmaports/-/raw/${BRANCH}/device"
DIRS=(community testing main)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# --- 1. Dependencies available in Debian
echo "==> Installing Debian dependencies"
apt-get update
apt-get install -y curl git meson ninja-build build-essential pkg-config \
	alsa-ucm-conf udev systemd
# Optional Qualcomm helpers: packaged in newer Debian only, so install one by one
for p in qrtr-tools rmtfs pd-mapper tqftpserv libqrtr-dev libgbm-dev \
	hexagonrpcd hexagonrpcd-sdsp qbootctl soc-qcom-qbootctl; do
	apt-get install -y "$p" 2>/dev/null || echo "    (skipped: $p not in your Debian release)"
done

# --- 2. Download optional pmaports device files
# Missing upstream paths must not abort image construction. Local copies are
# used where this repository already contains known-good device configuration.
echo "==> Downloading device files from pmaports"
fetch_optional() {
	local f=$1 d
	for d in "${DIRS[@]}"; do
		if curl -fsSL "$BASE/$d/$DEVICE/$f" -o "$f"; then
			echo "    got $f ($d)"
			return 0
		fi
	done
	if [ -f "$SCRIPT_DIR/$f" ]; then
		cp "$SCRIPT_DIR/$f" "$f"
		echo "    got $f (repository fallback)"
		return 0
	fi
	echo "    skipped $f (not available upstream or locally)"
	return 0
}

FILES=(
	80-device-oneplus-fajita.preset
	81-libssc-oneplus-fajita.rules
	hexagonrpcd-sdsp.conf
	q6voiced.conf
	deviceinfo
)
for f in "${FILES[@]}"; do fetch_optional "$f"; done

# --- 3. Install available device configuration
 echo "==> Installing config files"
inst() { [ -f "$1" ] && install -Dm644 "$1" -t "$2"; }
inst 81-libssc-oneplus-fajita.rules   /usr/lib/udev/rules.d/
inst q6voiced.conf                    /usr/share/q6voiced/
inst hexagonrpcd-sdsp.conf            /usr/share/hexagonrpcd/
inst 80-device-oneplus-fajita.preset  /usr/lib/systemd/system-preset/
inst deviceinfo                       /usr/share/"$DEVICE"/

udevadm control --reload-rules 2>/dev/null && udevadm trigger 2>/dev/null || true

# Use packaged helpers when available. Source-building GitHub repositories is
# intentionally optional and must never make the image build depend on GitHub
# credentials or network authentication.
if command -v hexagonrpcd >/dev/null; then
	echo "    hexagonrpcd already installed"
else
	echo "    hexagonrpcd not available from Debian repos; skipped"
fi
if command -v qbootctl >/dev/null; then
	echo "    qbootctl already installed"
else
	echo "    qbootctl not available from Debian repos; skipped"
fi

# --- 4. Enable services listed in the preset (only if the unit exists)
if [ -f 80-device-oneplus-fajita.preset ]; then
	echo "==> Enabling services from the preset"
	systemctl daemon-reload 2>/dev/null || true
	while read -r action unit _; do
		[ "$action" = "enable" ] || continue
		if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
			systemctl enable "$unit" 2>/dev/null && echo "    enabled $unit" || true
		else
			echo "    skipped $unit (not installed on this system)"
		fi
	done < 80-device-oneplus-fajita.preset
fi

if command -v update-initramfs >/dev/null; then
	update-initramfs -u -k all || echo "    WARNING: initramfs refresh failed; continuing"
fi

cat <<'EOF'

Done. Optional OnePlus 6T configuration and packaged helpers have been applied.
EOF
