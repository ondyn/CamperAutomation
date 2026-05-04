#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Run inside Termux app on the phone (first interactive bootstrap).
# This keeps interactive steps minimal: storage permission + ssh password.

BOOTSTRAP_VERSION="2026-05-03.2"
echo "[bootstrap_termux] version=${BOOTSTRAP_VERSION}"

termux-wake-lock
termux-setup-storage || true

pkg update -y
pkg upgrade -y

# Termux package naming changed over time; pick available binutils variant.
BINUTILS_PKG=""
if pkg show binutils >/dev/null 2>&1; then
  BINUTILS_PKG="binutils"
elif pkg show binutils-is-llvm >/dev/null 2>&1; then
  BINUTILS_PKG="binutils-is-llvm"
else
  echo "WARNING: No known binutils package variant found; continuing without explicit binutils package."
fi

BASE_PACKAGES=(
  openssh git python rust uv tsu ffmpeg
  libxml2 libxslt pkg-config libffi libjpeg-turbo libpng
  patchelf ninja screen cmake python-psutil
)

if [ -n "${BINUTILS_PKG}" ]; then
  BASE_PACKAGES+=("${BINUTILS_PKG}")
fi

pkg install -y "${BASE_PACKAGES[@]}"

if ! command -v sshd >/dev/null 2>&1; then
  echo "ERROR: sshd missing after package install." >&2
  exit 1
fi

echo
echo "Set a password for SSH (Termux user):"
passwd

echo
echo "Starting sshd..."
sshd

if pgrep -x sshd >/dev/null 2>&1; then
  echo "sshd is running on port 8022"
else
  echo "ERROR: sshd did not start correctly." >&2
  exit 1
fi

echo
echo "Termux base bootstrap complete."
echo "Next: from your laptop, continue with provisioning/ssh/10_install_homeassistant_core.sh"
