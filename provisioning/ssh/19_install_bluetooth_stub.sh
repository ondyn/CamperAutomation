#!/usr/bin/env bash
set -euo pipefail

# Deploy the Android/Termux bluetooth stub custom component into the active
# Home Assistant config on the phone.
#
# This stub:
#   1. Makes the bluetooth domain appear "set up" (returns True from async_setup)
#      without touching DBus or importing bluetooth_adapters.
#      → ESPHome (which lists bluetooth as a hard dependency) loads normally.
#
#   2. Registers a duck-typed no-op BluetoothManager via
#      habluetooth.central_manager.set_manager().
#      → Prevents "RuntimeError: BluetoothManager has not been set" that
#        crashes ESPHome's on_connect callback and keeps devices stuck
#        as unavailable after reconnect on Android/Termux (HA 2026.x).
#
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/19_install_bluetooth_stub.sh
# Or (auto-detect over ADB):
#   ./provisioning/ssh/19_install_bluetooth_stub.sh
#
# Optional variables:
#   SSH_PORT=8022
#   SSH_IDENTITY=~/.ssh/camper_automation_rsa
#   SSH_PASSWORD=secret
#   RESTART_HA=1  (default: 1)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_COMPONENT_DIR="${ROOT_DIR}/hass-config/custom_components/bluetooth"
SSH_PORT="${SSH_PORT:-8022}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"
RESTART_HA="${RESTART_HA:-1}"

if [ ! -d "${LOCAL_COMPONENT_DIR}" ]; then
  echo "ERROR: local bluetooth stub directory is missing: ${LOCAL_COMPONENT_DIR}" >&2
  exit 1
fi

if [ ! -f "${LOCAL_COMPONENT_DIR}/manifest.json" ]; then
  echo "ERROR: local manifest missing: ${LOCAL_COMPONENT_DIR}/manifest.json" >&2
  exit 1
fi

if [ ! -f "${LOCAL_COMPONENT_DIR}/__init__.py" ]; then
  echo "ERROR: local __init__.py missing: ${LOCAL_COMPONENT_DIR}/__init__.py" >&2
  exit 1
fi

auto_detect_phone_host_adb() {
  local host=""
  host="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell getprop dhcp.ap.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan1 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 route 2>/dev/null | awk '/wlan/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 | tr -d '\r' || true)"
  echo "${host}"
}

auto_detect_phone_user_adb() {
  local pkg_uid app_uid
  pkg_uid=$(adb shell dumpsys package com.termux 2>/dev/null | tr -d '\r' | awk -F= '/userId=/{print $2; exit}') || true
  if [[ -n "${pkg_uid:-}" && "${pkg_uid}" =~ ^[0-9]+$ && "${pkg_uid}" -ge 10000 ]]; then
    app_uid=$((pkg_uid - 10000))
    echo "u0_a${app_uid}"
    return 0
  fi
  return 1
}

if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST..."
  PHONE_HOST="$(auto_detect_phone_host_adb)"
  [ -n "${PHONE_HOST}" ] || { echo "ERROR: Could not auto-detect PHONE_HOST" >&2; exit 1; }
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER="$(auto_detect_phone_user_adb || true)"
  [ -n "${PHONE_USER}" ] || { echo "ERROR: Could not auto-detect PHONE_USER" >&2; exit 1; }
  echo "Detected PHONE_USER=${PHONE_USER}"
fi

SSH_ID_ARGS=()
if [ -f "${SSH_IDENTITY}" ] && [ -z "${SSH_PASSWORD}" ]; then
  SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
fi

SSH_TRANSPORT=(ssh)
SSH_AUTH_OPTS=()
if [ -n "${SSH_PASSWORD}" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required for password-based provisioning SSH flow." >&2
    exit 1
  fi
  SSH_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" ssh)
  SSH_AUTH_OPTS=(
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
  )
fi

SSH_BASE=("${SSH_TRANSPORT[@]}" -F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new)
if [ ${#SSH_AUTH_OPTS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_AUTH_OPTS[@]}")
fi
if [ ${#SSH_ID_ARGS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_ID_ARGS[@]}")
fi
SSH_BASE+=("${PHONE_USER}@${PHONE_HOST}")

echo "Resolving active Home Assistant config directory on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."
REMOTE_HASS_CONFIG_DIR="$("${SSH_BASE[@]}" 'env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s' <<'REMOTE_DETECT'
set -euo pipefail
unset BASH_ENV ENV

ROOT_HA_CONFIG="$HOME/.suroot/.homeassistant"
USER_HA_CONFIG="$HOME/.homeassistant"

if [ -f "$ROOT_HA_CONFIG/configuration.yaml" ] && [ -w "$ROOT_HA_CONFIG" ]; then
  echo "$ROOT_HA_CONFIG"
elif [ -f "$USER_HA_CONFIG/configuration.yaml" ] && [ -w "$USER_HA_CONFIG" ]; then
  echo "$USER_HA_CONFIG"
elif [ -d "$ROOT_HA_CONFIG" ] && [ -w "$ROOT_HA_CONFIG" ]; then
  echo "$ROOT_HA_CONFIG"
else
  mkdir -p "$USER_HA_CONFIG"
  echo "$USER_HA_CONFIG"
fi
REMOTE_DETECT
)"

if [ -z "${REMOTE_HASS_CONFIG_DIR}" ]; then
  echo "ERROR: could not determine remote HA config directory" >&2
  exit 1
fi

echo "Using remote Home Assistant config: ${REMOTE_HASS_CONFIG_DIR}"

echo "Creating backup and preparing target directory..."
"${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<REMOTE_PREP
set -euo pipefail
unset BASH_ENV ENV
TARGET_DIR="${REMOTE_HASS_CONFIG_DIR}/custom_components/bluetooth"
BACKUP_DIR="${REMOTE_HASS_CONFIG_DIR}/.backup/custom_components/bluetooth.\$(date +%Y%m%d-%H%M%S)"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/custom_components"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/.backup/custom_components"
if [ -d "\$TARGET_DIR" ]; then
  cp -a "\$TARGET_DIR" "\$BACKUP_DIR"
  echo "Backup created: \$BACKUP_DIR"
fi
rm -rf "\$TARGET_DIR"
mkdir -p "\$TARGET_DIR"
REMOTE_PREP

echo "Uploading bluetooth stub component files..."
REMOTE_COMPONENT_TAR="\$HOME/.cache/provisioning/bluetooth_stub.tar"
"${SSH_BASE[@]}" 'mkdir -p "$HOME/.cache/provisioning"'
tar -C "${ROOT_DIR}/hass-config" -cf - custom_components/bluetooth | "${SSH_BASE[@]}" "cat > \"${REMOTE_COMPONENT_TAR}\""
"${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<REMOTE_EXTRACT
set -euo pipefail
unset BASH_ENV ENV
TARGET_PARENT="${REMOTE_HASS_CONFIG_DIR}"
REMOTE_COMPONENT_TAR="\$HOME/.cache/provisioning/bluetooth_stub.tar"
tar -xf "\$REMOTE_COMPONENT_TAR" -C "\$TARGET_PARENT"
rm -f "\$REMOTE_COMPONENT_TAR"
[ -f "\$TARGET_PARENT/custom_components/bluetooth/manifest.json" ]
[ -f "\$TARGET_PARENT/custom_components/bluetooth/__init__.py" ]
echo "Bluetooth stub files verified on device."
REMOTE_EXTRACT

echo "Verifying stub manifest integrity..."
"${SSH_BASE[@]}" "REMOTE_HASS_CONFIG_DIR='${REMOTE_HASS_CONFIG_DIR}' env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<'REMOTE_VERIFY'
set -euo pipefail
unset BASH_ENV ENV
VENV_PY="$HOME/.venv/bin/python"
MANIFEST_PATH="${REMOTE_HASS_CONFIG_DIR}/custom_components/bluetooth/manifest.json"
if [ ! -x "$VENV_PY" ]; then
  echo "WARNING: HA venv python not found; skipping manifest parse check." >&2
  exit 0
fi
DOMAIN="$($VENV_PY -c 'import json, sys; d=json.load(open(sys.argv[1])); print(d["domain"])' "$MANIFEST_PATH")"
if [ "$DOMAIN" != "bluetooth" ]; then
  echo "ERROR: manifest domain mismatch: expected 'bluetooth', got '$DOMAIN'" >&2
  exit 1
fi
VERSION="$($VENV_PY -c 'import json, sys; d=json.load(open(sys.argv[1])); print(d.get("version",""))' "$MANIFEST_PATH")"
echo "Stub manifest OK: domain=bluetooth version=${VERSION}"
REQUIREMENTS="$($VENV_PY -c 'import json, sys; d=json.load(open(sys.argv[1])); print(len(d.get("requirements",[])))' "$MANIFEST_PATH")"
if [ "$REQUIREMENTS" != "0" ]; then
  echo "WARNING: bluetooth stub manifest lists requirements; this may pull in bluetooth_adapters and cause the original crash." >&2
fi
REMOTE_VERIFY

if [ "${RESTART_HA}" = "1" ]; then
  echo "Restarting Home Assistant..."
  "${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -lc '\$HOME/scripts/hassctl.sh restart && sleep 5 && \$HOME/scripts/hassctl.sh status'"
else
  echo "Skipping Home Assistant restart because RESTART_HA=${RESTART_HA}"
fi

echo "bluetooth stub deployment finished successfully."
echo "Next steps:"
echo "  - Open Home Assistant UI -> Settings -> Devices & Services -> Add Integration -> ESPHome"
echo "  - The bluetooth domain is now stubbed out and ESPHome should load without the DBus error."
echo "  - Check logs: tail -n 50 ~/.homeassistant/home-assistant.log | grep -E 'bluetooth|esphome'"
