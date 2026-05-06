#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK_DIR="${ROOT_DIR}/provisioning/apks"
mkdir -p "${APK_DIR}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb is required" >&2
  exit 1
fi

adb wait-for-device
ABI="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
SDK="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"

case "${ABI}" in
  arm64-v8a|aarch64) TERMUX_ASSET_RE='arm64-v8a' ;;
  armeabi-v7a|armv7l) TERMUX_ASSET_RE='armeabi-v7a' ;;
  x86_64) TERMUX_ASSET_RE='x86_64' ;;
  x86) TERMUX_ASSET_RE='x86' ;;
  *)
    echo "ERROR: unsupported ABI '${ABI}'" >&2
    exit 1
    ;;
esac

if [ "${SDK}" -lt 24 ]; then
  echo "ERROR: Android SDK ${SDK} is too old for current Termux releases (need Android 7+)." >&2
  exit 1
fi

github_asset_url() {
  local repo="$1"
  local pattern="$2"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | jq -r --arg p "${pattern}" '.assets[] | select(.name | contains($p) and (endswith(".apk") or endswith(".APK"))) | .browser_download_url' \
    | head -n 1
}

download_to() {
  local url="$1"
  local out="$2"
  if [ -z "${url}" ] || [ "${url}" = "null" ]; then
    echo "ERROR: unable to resolve download URL for ${out}" >&2
    exit 1
  fi
  echo "Downloading $(basename "${out}")"
  curl -fL "${url}" -o "${out}"
}

TERMUX_URL="$(github_asset_url termux/termux-app "${TERMUX_ASSET_RE}")"
TERMUX_API_URL="$(github_asset_url termux/termux-api "termux-api")"
TERMUX_BOOT_URL="$(github_asset_url termux/termux-boot "termux-boot")"
MAGISK_URL="$(github_asset_url topjohnwu/Magisk "Magisk-v")"
HA_URL="$(github_asset_url home-assistant/android "full")"

download_to "${TERMUX_URL}" "${APK_DIR}/termux.apk"
download_to "${TERMUX_API_URL}" "${APK_DIR}/termux-api.apk"
download_to "${TERMUX_BOOT_URL}" "${APK_DIR}/termux-boot.apk"
download_to "${MAGISK_URL}" "${APK_DIR}/magisk.apk"
download_to "${HA_URL}" "${APK_DIR}/home-assistant-companion.apk"

echo "APK download complete: ${APK_DIR}"
