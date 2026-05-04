#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_LOCAL="${ROOT_DIR}/provisioning/android/magisk-service/80-hotspot-on-boot.sh"
SCRIPT_REMOTE="/data/local/tmp/80-hotspot-on-boot.sh"

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
adb shell su -c "mkdir -p /data/adb/service.d && cp ${SCRIPT_REMOTE} /data/adb/service.d/80-hotspot-on-boot.sh && chmod 755 /data/adb/service.d/80-hotspot-on-boot.sh"

echo "Installed Magisk boot script: /data/adb/service.d/80-hotspot-on-boot.sh"
echo "Reboot the phone and verify with: adb shell su -c 'logcat -d | grep camperautomation-hotspot'"
