#!/usr/bin/env bash
set -euo pipefail

# Install missing Python modules reported by recent Home Assistant startup logs.
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/16_install_ha_startup_requirements.sh
# Or (auto-detect):
#   ./provisioning/ssh/16_install_ha_startup_requirements.sh

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
  [ -n "${PHONE_HOST}" ] || { echo "ERROR: Could not auto-detect PHONE_HOST" >&2; exit 1; }
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER="$(auto_detect_phone_user_adb || true)"
  [ -n "${PHONE_USER}" ] || { echo "ERROR: Could not auto-detect PHONE_USER" >&2; exit 1; }
  echo "Detected PHONE_USER=${PHONE_USER}"
fi

SSH_PORT="${SSH_PORT:-8022}"
SSH_BASE=(ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new "${PHONE_USER}@${PHONE_HOST}")

echo "Installing startup-missing HA requirements on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."

"${SSH_BASE[@]}" 'bash -s' <<'REMOTE_INSTALL'
set -euo pipefail

VENV_PY="$HOME/.venv/bin/python"
RUN_LOG="$HOME/logs/hass-runner.log"

if [ ! -x "$VENV_PY" ]; then
  echo "ERROR: missing HA venv at $VENV_PY" >&2
  exit 1
fi

if [ ! -f "$RUN_LOG" ]; then
  echo "ERROR: missing HA runner log at $RUN_LOG" >&2
  exit 1
fi

# Capture missing module names from recent log history.
MISSING_MODULES="$($VENV_PY -c "import re, pathlib; p=pathlib.Path('$RUN_LOG'); lines=p.read_text(errors='ignore').splitlines(); s=0
for i,l in enumerate(lines):
  if 'Starting Home Assistant with config' in l:
    s=i
window='\n'.join(lines[s:])
mods=sorted(set(re.findall(r\"No module named '([^']+)'\", window)))
print('\\n'.join(mods))")"

if [ -z "$MISSING_MODULES" ]; then
  echo "No missing Python modules detected in hass-runner.log"
  exit 0
fi

echo "Missing modules detected:"
printf '%s\n' "$MISSING_MODULES"

to_pip_name() {
  case "$1" in
    gtts) echo "gTTS" ;;
    *) echo "$1" ;;
  esac
}

while IFS= read -r module; do
  [ -n "$module" ] || continue
  pkg="$(to_pip_name "$module")"
  echo "Installing Python package: $pkg"
  if ! "$VENV_PY" -m pip install --disable-pip-version-check "$pkg"; then
    echo "WARNING: could not install package '$pkg' for module '$module'" >&2
  fi
done <<EOF
$MISSING_MODULES
EOF

echo "Startup-missing requirements install complete."
REMOTE_INSTALL

echo "Done."