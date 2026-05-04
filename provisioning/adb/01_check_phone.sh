#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${ROOT_DIR}/provisioning/logs"
mkdir -p "${LOG_DIR}"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found. Install Android platform-tools first." >&2
  exit 1
fi

adb start-server >/dev/null
adb wait-for-device

SERIAL="$(adb get-serialno)"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/phone-check-${TS}.log"

{
  echo "timestamp=$(date -u +%FT%TZ)"
  echo "serial=${SERIAL}"
  echo "manufacturer=$(adb shell getprop ro.product.manufacturer | tr -d '\r')"
  echo "model=$(adb shell getprop ro.product.model | tr -d '\r')"
  echo "device=$(adb shell getprop ro.product.device | tr -d '\r')"
  echo "android_release=$(adb shell getprop ro.build.version.release | tr -d '\r')"
  echo "sdk=$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
  echo "abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "bootloader_unlock_state=$(adb shell getprop ro.boot.flash.locked | tr -d '\r')"
  echo "verified_boot_state=$(adb shell getprop ro.boot.verifiedbootstate | tr -d '\r')"
  echo "adb_root_available=$(adb root >/dev/null 2>&1 && echo yes || echo no)"
  echo "magisk_present=$(adb shell su -v >/dev/null 2>&1 && echo yes || echo no)"
} | tee "${LOG_FILE}"

echo
echo "Phone baseline saved to: ${LOG_FILE}"
