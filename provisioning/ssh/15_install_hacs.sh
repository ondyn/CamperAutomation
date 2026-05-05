#!/usr/bin/env bash
set -euo pipefail

# Run from your laptop after Home Assistant Core is installed and SSH is reachable.
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/15_install_hacs.sh
# Or (auto-detect):
#   ./provisioning/ssh/15_install_hacs.sh

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

# Auto-detect PHONE_HOST if not set.
if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST..."
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb is not available for auto-detection." >&2
    exit 1
  fi
  PHONE_HOST="$(auto_detect_phone_host_adb)"
  if [ -z "${PHONE_HOST}" ]; then
    echo "ERROR: Could not auto-detect PHONE_HOST via ADB." >&2
    exit 1
  fi
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

# Auto-detect PHONE_USER if not set.
if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER=""
  if command -v adb >/dev/null 2>&1; then
    PHONE_USER="$(auto_detect_phone_user_adb || true)"
  fi
  if [ -n "${PHONE_USER}" ]; then
    echo "Detected PHONE_USER=${PHONE_USER} (from ADB package UID)"
  else
    echo "ERROR: Could not auto-detect PHONE_USER from ADB package metadata." >&2
    exit 1
  fi
fi

: "${PHONE_HOST:?Set PHONE_HOST}"
: "${PHONE_USER:?Set PHONE_USER}"

SSH_PORT="${SSH_PORT:-8022}"
SSH_BASE=(ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${PHONE_USER}@${PHONE_HOST}")

echo "Installing HACS on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."

"${SSH_BASE[@]}" 'bash -s' <<'REMOTE_INSTALL'
set -euo pipefail

ROOT_HA_CONFIG="$HOME/.suroot/.homeassistant"
USER_HA_CONFIG="$HOME/.homeassistant"

if [ -d "$ROOT_HA_CONFIG" ] && [ -w "$ROOT_HA_CONFIG" ]; then
  HASS_CONFIG_DIR="$ROOT_HA_CONFIG"
elif [ -d "$USER_HA_CONFIG" ] && [ -w "$USER_HA_CONFIG" ]; then
  HASS_CONFIG_DIR="$USER_HA_CONFIG"
else
  HASS_CONFIG_DIR="$USER_HA_CONFIG"
  mkdir -p "$HASS_CONFIG_DIR"
fi

echo "Using Home Assistant config: $HASS_CONFIG_DIR"

if ! command -v curl >/dev/null 2>&1; then
  echo "Installing curl in Termux..."
  pkg install -y curl >/dev/null
fi

if [ -d "$HASS_CONFIG_DIR/custom_components/hacs" ]; then
  echo "Existing HACS installation detected; reinstalling latest release."
fi

cd "$HASS_CONFIG_DIR"
curl -fsSL https://get.hacs.xyz | bash -

if [ ! -f "$HASS_CONFIG_DIR/custom_components/hacs/manifest.json" ]; then
  echo "ERROR: HACS install did not produce custom_components/hacs/manifest.json" >&2
  exit 1
fi

VENV_PY="$HOME/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
  echo "ERROR: Home Assistant venv python not found at $VENV_PY" >&2
  exit 1
fi

echo "Installing HACS Python requirements into Home Assistant venv..."
MANIFEST_PATH="$HASS_CONFIG_DIR/custom_components/hacs/manifest.json"
HACS_REQS="$(MANIFEST_PATH="$MANIFEST_PATH" "$VENV_PY" -c 'import json, os; data=json.load(open(os.environ["MANIFEST_PATH"], "r", encoding="utf-8")); print("\n".join(data.get("requirements", [])))')"
if [ -n "$HACS_REQS" ]; then
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    "$VENV_PY" -m pip install --disable-pip-version-check "$req"
  done <<EOF
$HACS_REQS
EOF
else
  echo "No extra HACS requirements declared in manifest."
fi

echo "HACS installed successfully in $HASS_CONFIG_DIR/custom_components/hacs"
echo "Restart Home Assistant to load the integration:"
echo "  /data/data/com.termux/files/home/scripts/hassctl.sh restart"
REMOTE_INSTALL

echo "Done."