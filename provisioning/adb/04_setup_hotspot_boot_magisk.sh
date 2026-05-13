#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_LOCAL="${ROOT_DIR}/provisioning/android/magisk-service/80-hotspot-on-boot.sh"
SCRIPT_REMOTE="/data/local/tmp/80-hotspot-on-boot.sh"
SCRIPT_FALLBACK_SD="/sdcard/Download/80-hotspot-on-boot.sh"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found" >&2
  exit 1
fi
if [ ! -f "${SCRIPT_LOCAL}" ]; then
  echo "ERROR: local script missing: ${SCRIPT_LOCAL}" >&2
  exit 1
fi

adb wait-for-device

if ! adb shell su -v >/dev/null 2>&1; then
  echo "ERROR: su/Magisk is not available over adb shell." >&2
  echo "Make sure root is installed and adb shell is authorized in Magisk." >&2
  exit 1
fi

adb push "${SCRIPT_LOCAL}" "${SCRIPT_REMOTE}"

install_with_su() {
  # IMPORTANT: pass the entire command as ONE string to adb shell so adb invokes
  # Android's /bin/sh -c "su -c '...'" rather than passing su/-c/cmd as separate
  # args.  The separate-args form runs in a different SELinux context that cannot
  # write to adb_data_file, causing "Permission denied" even as root.
  # Also use 'cp' not 'cat >': shell redirects in inner su -c can be blocked.
  local cmd="mkdir -p /data/adb/service.d && cp ${SCRIPT_REMOTE} /data/adb/service.d/80-hotspot-on-boot.sh && chmod 755 /data/adb/service.d/80-hotspot-on-boot.sh"
  adb shell "su -c '${cmd}'"
}

if install_with_su; then
  echo "Installed Magisk boot script: /data/adb/service.d/80-hotspot-on-boot.sh"
  echo "Reboot the phone and verify with: adb shell su -c 'logcat -d | grep camperautomation-hotspot'"
  exit 0
fi

echo "WARNING: adb shell root could not write /data/adb/service.d on this device." >&2
echo "         This Xiaomi build appears to block Magisk service.d writes from adb shell even with su." >&2

echo "Staging fallback copy to shared storage for Termux-based installation..."
adb shell "mkdir -p /sdcard/Download" >/dev/null
adb push "${SCRIPT_LOCAL}" "${SCRIPT_FALLBACK_SD}" >/dev/null
adb shell "chmod 644 ${SCRIPT_FALLBACK_SD}" >/dev/null 2>&1 || true

cat <<EOF
Automatic adb installation did not complete.

Fallback path prepared:
  ${SCRIPT_FALLBACK_SD}

Before using the shared-storage fallback in Termux, run once:
  termux-setup-storage

In Termux on the phone, run exactly:
  su -c 'mkdir -p /data/adb/service.d && cat ${SCRIPT_FALLBACK_SD} > /data/adb/service.d/80-hotspot-on-boot.sh && chmod 755 /data/adb/service.d/80-hotspot-on-boot.sh'

Then reboot and verify from laptop with:
  adb shell su -c 'logcat -d | grep camperautomation-hotspot'
EOF

exit 2
