#!/usr/bin/env bash
set -euo pipefail

# Deploy obd_monitor Home Assistant custom integration to the phone.
#
# Usage:
#   PHONE_HOST=192.168.1.224 PHONE_USER=u0_a270 ./provisioning/ssh/26_install_obd_monitor_integration.sh
# Or (auto-detect over ADB):
#   ./provisioning/ssh/26_install_obd_monitor_integration.sh
#
# Optional variables:
#   SSH_PORT=8022
#   SSH_IDENTITY=~/.ssh/camper_automation_rsa
#   SSH_PASSWORD=secret
#   RESTART_HA=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_COMPONENT_DIR="${ROOT_DIR}/hass-config/custom_components/obd_monitor"

SSH_PORT="${SSH_PORT:-8022}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"
RESTART_HA="${RESTART_HA:-1}"

# ── Preflight ──────────────────────────────────────────────────────────────

if [ ! -d "${LOCAL_COMPONENT_DIR}" ]; then
  echo "ERROR: local component directory missing: ${LOCAL_COMPONENT_DIR}" >&2
  exit 1
fi
if [ ! -f "${LOCAL_COMPONENT_DIR}/manifest.json" ]; then
  echo "ERROR: local manifest missing: ${LOCAL_COMPONENT_DIR}/manifest.json" >&2
  exit 1
fi

# ── Auto-detect helpers ────────────────────────────────────────────────────

auto_detect_phone_host_adb() {
  local host=""
  host="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell getprop dhcp.ap.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
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
  [ -n "${PHONE_HOST}" ] || { echo "ERROR: could not auto-detect PHONE_HOST" >&2; exit 1; }
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER="$(auto_detect_phone_user_adb || true)"
  [ -n "${PHONE_USER}" ] || { echo "ERROR: could not auto-detect PHONE_USER" >&2; exit 1; }
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
    echo "ERROR: sshpass is required for password-based SSH provisioning." >&2
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

# ── Resolve remote HA config directory ────────────────────────────────────

echo "Resolving active Home Assistant config directory..."
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

[ -n "${REMOTE_HASS_CONFIG_DIR}" ] || { echo "ERROR: could not determine remote HA config directory" >&2; exit 1; }
echo "Using remote Home Assistant config: ${REMOTE_HASS_CONFIG_DIR}"

# ── Backup + prepare remote directory ─────────────────────────────────────

echo "Preparing backup and target directories..."
"${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<REMOTE_PREP
set -euo pipefail
unset BASH_ENV ENV

TARGET_DIR="${REMOTE_HASS_CONFIG_DIR}/custom_components/obd_monitor"
BACKUP_DIR="${REMOTE_HASS_CONFIG_DIR}/.backup/custom_components/obd_monitor.\$(date +%Y%m%d-%H%M%S)"

mkdir -p "${REMOTE_HASS_CONFIG_DIR}/custom_components"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/.backup/custom_components"

if [ -d "\$TARGET_DIR" ]; then
  cp -a "\$TARGET_DIR" "\$BACKUP_DIR"
  echo "Backup created: \$BACKUP_DIR"
fi

rm -rf "\$TARGET_DIR"
mkdir -p "\$TARGET_DIR"
echo "Target directory ready: \$TARGET_DIR"
REMOTE_PREP

# ── Upload component ───────────────────────────────────────────────────────

echo "Uploading obd_monitor component..."
REMOTE_BUNDLE_TAR="\$HOME/.cache/provisioning/obd_monitor_bundle.tar"
"${SSH_BASE[@]}" 'mkdir -p "$HOME/.cache/provisioning"'
tar -C "${ROOT_DIR}/hass-config" -cf - custom_components/obd_monitor \
  | "${SSH_BASE[@]}" "cat > \"${REMOTE_BUNDLE_TAR}\""

"${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<REMOTE_EXTRACT
set -euo pipefail
unset BASH_ENV ENV

REMOTE_BUNDLE_TAR="\$HOME/.cache/provisioning/obd_monitor_bundle.tar"
TARGET_PARENT="${REMOTE_HASS_CONFIG_DIR}"

tar -xf "\$REMOTE_BUNDLE_TAR" -C "\$TARGET_PARENT"
rm -f "\$REMOTE_BUNDLE_TAR"

# Verify key files
[ -f "\$TARGET_PARENT/custom_components/obd_monitor/manifest.json" ] || { echo "ERROR: manifest.json missing after extract" >&2; exit 1; }
[ -f "\$TARGET_PARENT/custom_components/obd_monitor/__init__.py" ]   || { echo "ERROR: __init__.py missing after extract" >&2; exit 1; }
[ -f "\$TARGET_PARENT/custom_components/obd_monitor/sensor.py" ]     || { echo "ERROR: sensor.py missing after extract" >&2; exit 1; }
[ -f "\$TARGET_PARENT/custom_components/obd_monitor/button.py" ]     || { echo "ERROR: button.py missing after extract" >&2; exit 1; }

echo "obd_monitor component files:"
ls -la "\$TARGET_PARENT/custom_components/obd_monitor/"
REMOTE_EXTRACT

echo ""
echo "=== obd_monitor integration provisioned successfully ==="
echo "NEXT: Add 'OBD Monitor' integration via HA Settings → Integrations."
echo "      The obdmonitor Flutter app must be running on the phone first."

if [ "${RESTART_HA}" = "1" ]; then
  echo "Restarting Home Assistant..."
  PHONE_HOST="${PHONE_HOST}" PHONE_USER="${PHONE_USER}" SSH_PORT="${SSH_PORT}" \
    SSH_IDENTITY="${SSH_IDENTITY}" SSH_PASSWORD="${SSH_PASSWORD}" \
    bash "${ROOT_DIR}/provisioning/ssh/25_restart_homeassistant.sh"
fi
