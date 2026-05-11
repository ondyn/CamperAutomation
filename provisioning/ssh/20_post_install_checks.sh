#!/usr/bin/env bash
set -euo pipefail

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

# Auto-detect PHONE_HOST if not set
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

# Auto-detect PHONE_USER if not set
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

"${SSH_BASE[@]}" 'bash -lc "
set -e
printf \"== versions ==\\n\"
python3 --version || true
uv --version || true
printf "== android api level for builds ==\\n"
python3 - <<'PYEOF'
import sysconfig
print(f"sysconfig ANDROID_API_LEVEL={sysconfig.get_config_var('ANDROID_API_LEVEL')}")
PYEOF
echo "getprop ro.build.version.sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo unknown)"
if grep -q 'ANDROID_API_LEVEL' "$HOME/scripts/hass.sh" 2>/dev/null; then
  echo "hass.sh: exports ANDROID_API_LEVEL (OK)"
else
  echo "hass.sh: missing ANDROID_API_LEVEL export (FAIL)"
fi
ACTIVE_HA_CONFIG_DIR=""
if [ -f "$HOME/.suroot/.homeassistant/configuration.yaml" ] && [ -w "$HOME/.suroot/.homeassistant" ]; then
  ACTIVE_HA_CONFIG_DIR="$HOME/.suroot/.homeassistant"
elif [ -f "$HOME/.homeassistant/configuration.yaml" ] && [ -w "$HOME/.homeassistant" ]; then
  ACTIVE_HA_CONFIG_DIR="$HOME/.homeassistant"
fi
if [ -n "$ACTIVE_HA_CONFIG_DIR" ] && grep -q '^mobile_app:' "$ACTIVE_HA_CONFIG_DIR/configuration.yaml" 2>/dev/null; then
  echo "ha config: mobile_app enabled in ${ACTIVE_HA_CONFIG_DIR}/configuration.yaml"
else
  echo "ha config: mobile_app missing from active configuration.yaml"
fi
printf \"== services ==\\n\"
pgrep -fa tailscaled || true
pgrep -x sshd || true
pgrep -fa \"hass|homeassistant\" || true
screen -ls || true
printf \"== bootstrap log tail (~/logs/bootstrap.log) ==\\n\"
[ -f ~/logs/bootstrap.log ] && tail -n 80 ~/logs/bootstrap.log || echo \"(not found)\"
printf \"== hass runner log tail (~/logs/hass-runner.log) ==\\n\"
[ -f ~/logs/hass-runner.log ] && tail -n 80 ~/logs/hass-runner.log || echo \"(not found)\"
printf \"== HA core log tail (~/.suroot/.homeassistant/home-assistant.log) ==\\n\"
[ -f ~/.suroot/.homeassistant/home-assistant.log ] && tail -n 80 ~/.suroot/.homeassistant/home-assistant.log || echo \"(not found)\"
printf \"== HA core log tail (~/.homeassistant/home-assistant.log) ==\\n\"
[ -f ~/.homeassistant/home-assistant.log ] && tail -n 80 ~/.homeassistant/home-assistant.log || echo \"(not found)\"
"'
