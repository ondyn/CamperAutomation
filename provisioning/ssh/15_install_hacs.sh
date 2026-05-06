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
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"
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

echo "Installing HACS on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."

"${SSH_BASE[@]}" 'env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s' <<'REMOTE_INSTALL'
set -euo pipefail

# Guard against host/ssh exported shell env causing bash startup failures.
unset BASH_ENV ENV
PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:/system/bin"
SHELL="${PREFIX}/bin/bash"
export PREFIX PATH SHELL

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
  if command -v apt >/dev/null 2>&1; then
    apt install -y curl
  elif command -v pkg >/dev/null 2>&1; then
    pkg install -y curl
  else
    echo "ERROR: Neither apt nor pkg is available to install curl." >&2
    exit 1
  fi
fi

if [ -d "$HASS_CONFIG_DIR/custom_components/hacs" ]; then
  echo "Existing HACS installation detected; reinstalling latest release."
fi

# HACS installer requires a configuration.yaml to recognise this as an HA config dir
if [ ! -f "$HASS_CONFIG_DIR/configuration.yaml" ]; then
  echo "Creating stub configuration.yaml so HACS installer can detect the config dir..."
  echo "# Home Assistant configuration" > "$HASS_CONFIG_DIR/configuration.yaml"
fi

# HACS installer detects HA config dir via .HA_VERSION file
if [ ! -f "$HASS_CONFIG_DIR/.HA_VERSION" ]; then
  echo "Creating .HA_VERSION marker so HACS installer can detect the config dir..."
  # Get installed HA version from venv
  HA_VER=$("$HOME/.venv/bin/python" -c 'import homeassistant.const as c; print(c.__version__)' 2>/dev/null || echo "2026.2.3")
  echo "$HA_VER" > "$HASS_CONFIG_DIR/.HA_VERSION"
fi

VENV_PY="$HOME/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
  echo "ERROR: Home Assistant venv python not found at $VENV_PY" >&2
  exit 1
fi

cd "$HASS_CONFIG_DIR"

TMP_DIR="$(mktemp -d)"
cleanup_tmp() {
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

echo "Downloading latest HACS release archive..."
curl -fsSL -o "$TMP_DIR/hacs.zip" "https://github.com/hacs/integration/releases/latest/download/hacs.zip"

echo "Installing HACS files into custom_components/hacs..."
mkdir -p "$HASS_CONFIG_DIR/custom_components/hacs"
if command -v unzip >/dev/null 2>&1; then
  unzip -oq "$TMP_DIR/hacs.zip" -d "$HASS_CONFIG_DIR/custom_components/hacs"
else
  "$VENV_PY" - "$TMP_DIR/hacs.zip" "$HASS_CONFIG_DIR/custom_components/hacs" <<'PY'
import sys
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1])
target_dir = Path(sys.argv[2])
target_dir.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(zip_path) as zf:
    zf.extractall(target_dir)
PY
fi

if [ ! -f "$HASS_CONFIG_DIR/custom_components/hacs/manifest.json" ]; then
  echo "ERROR: HACS install did not produce custom_components/hacs/manifest.json" >&2
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