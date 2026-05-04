#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK_DIR="${ROOT_DIR}/provisioning/apks"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found" >&2
  exit 1
fi

adb wait-for-device

install_apk() {
  local file="$1"
  local label="$2"
  if [ ! -f "${file}" ]; then
    echo "ERROR: missing ${label} at ${file}" >&2
    exit 1
  fi
  echo "Installing ${label}..."
  echo "  → Approve installation prompt on phone screen"
  adb install -r "${file}" || {
    echo "ERROR: Installation of ${label} failed." >&2
    echo "       This usually means the installation was cancelled on the phone." >&2
    echo "       On Xiaomi/MIUI, enable Developer options -> Install via USB." >&2
    echo "       MIUI may ask for Xiaomi account sign-in/verification to allow USB installs." >&2
    echo "       Please check the phone screen, approve the installation, and retry." >&2
    return 1
  }
  echo "  ✓ ${label} installed"
}

install_apk "${APK_DIR}/termux.apk" "Termux"
install_apk "${APK_DIR}/termux-boot.apk" "Termux:Boot"
install_apk "${APK_DIR}/home-assistant-companion.apk" "Home Assistant Companion"

if [ -f "${APK_DIR}/automate.apk" ]; then
  install_apk "${APK_DIR}/automate.apk" "Automate"
else
  echo "Skipping Automate (automate.apk not found)."
fi

echo "APK install phase complete."
