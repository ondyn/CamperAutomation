#!/usr/bin/env bash
set -euo pipefail

# Run from your laptop after Termux SSH is reachable.
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/10_install_homeassistant_core.sh
# Or (auto-detect):
#   ./provisioning/ssh/10_install_homeassistant_core.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"

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

ensure_sshd_reachable() {
  # Fast path: port already open.
  if nc -z "${PHONE_HOST}" "${SSH_PORT}" >/dev/null 2>&1; then
    return 0
  fi

  # Try ADB-assisted start of sshd in Termux context.
  if command -v adb >/dev/null 2>&1; then
    if ! adb shell "run-as com.termux test -x /data/data/com.termux/files/usr/bin/sshd" >/dev/null 2>&1; then
      echo "ERROR: Termux openssh is not installed (sshd binary missing)." >&2
      echo "Run in Termux first:" >&2
      echo "  bash ~/bootstrap_termux.sh" >&2
      echo "Then rerun this installer." >&2
      return 1
    fi

    adb shell "run-as com.termux sh -lc 'export PREFIX=/data/data/com.termux/files/usr; export PATH=\$PREFIX/bin:\$PATH; sshd'" >/dev/null 2>&1 || true
    sleep 1

    if nc -z "${PHONE_HOST}" "${SSH_PORT}" >/dev/null 2>&1; then
      echo "Started sshd via ADB and confirmed ${PHONE_HOST}:${SSH_PORT} is reachable."
      return 0
    fi
  fi

  echo "ERROR: SSH is not reachable at ${PHONE_HOST}:${SSH_PORT}." >&2
  echo "On phone, open Termux and run:" >&2
  echo "  bash ~/bootstrap_termux.sh" >&2
  echo "  sshd" >&2
  echo "Then retry this script." >&2
  return 1
}

# Auto-detect PHONE_HOST if not set
if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST..."
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb is not available for auto-detection." >&2
    echo "Set PHONE_HOST manually, e.g. PHONE_HOST=192.168.1.224" >&2
    exit 1
  fi
  PHONE_HOST="$(auto_detect_phone_host_adb)"
  if [ -z "${PHONE_HOST}" ]; then
    echo "ERROR: Could not auto-detect PHONE_HOST via ADB." >&2
    echo "Checks to run:" >&2
    echo "  adb devices" >&2
    echo "  adb shell ip -4 addr show wlan0" >&2
    echo "Then run with manual host:" >&2
    echo "  PHONE_HOST=<PHONE_IP> ./provisioning/ssh/10_install_homeassistant_core.sh" >&2
    exit 1
  fi
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

# Auto-detect PHONE_USER if not set (try common Termux user patterns)
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
    echo "Ensure Termux app is installed, then retry or set manually:" >&2
    echo "  PHONE_USER=u0_aNNN ./provisioning/ssh/10_install_homeassistant_core.sh" >&2
    exit 1
  fi
fi

: "${PHONE_HOST?Set PHONE_HOST to phone IP/hostname}"
: "${PHONE_USER?Set PHONE_USER to Termux username, e.g. u0_a123}"

HA_REPO_URL="${HA_REPO_URL:-https://github.com/ondyn/hass-core.git}"
HA_REPO_BRANCH="${HA_REPO_BRANCH:-without-uv}"

ensure_sshd_reachable

SSH_OPTS=(
  -p "${SSH_PORT}"
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="/tmp/cm-%C"
)
SCP_OPTS=(
  -P "${SSH_PORT}"
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="/tmp/cm-%C"
)

cleanup_ssh_mux() {
  ssh "${SSH_OPTS[@]}" -O exit "${PHONE_USER}@${PHONE_HOST}" >/dev/null 2>&1 || true
}
trap cleanup_ssh_mux EXIT

echo "Establishing SSH session (password should be requested once)..."
ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'true'

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'mkdir -p ~/scripts ~/logs ~/.termux/boot'
scp "${SCP_OPTS[@]}" "${ROOT_DIR}/boot/00-bootstrap" "${PHONE_USER}@${PHONE_HOST}:~/.termux/boot/00-bootstrap"
scp "${SCP_OPTS[@]}" "${ROOT_DIR}/scripts/bootstrap_services.sh" "${PHONE_USER}@${PHONE_HOST}:~/scripts/bootstrap_services.sh"
scp "${SCP_OPTS[@]}" "${ROOT_DIR}/scripts/hass.sh" "${PHONE_USER}@${PHONE_HOST}:~/scripts/hass.sh"

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'chmod 700 ~/.termux/boot/00-bootstrap ~/scripts/bootstrap_services.sh ~/scripts/hass.sh'

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" "bash -lc '
set -euo pipefail
cd ~
python3 -m venv .venv
source .venv/bin/activate
if [ ! -d hass-core ]; then
  git clone -b ${HA_REPO_BRANCH} --single-branch ${HA_REPO_URL} hass-core
fi
cd hass-core
python -m script.translations develop --all
pip install --upgrade pip wheel setuptools
pip install .
'"

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'bash -lc "source ~/.venv/bin/activate && nohup sshd >/dev/null 2>&1 || true"'

cat <<EOF
Remote install finished.

Validate on phone (over SSH):
  screen -dmS hass sh ~/scripts/hass.sh
  screen -ls
  tail -n 80 ~/.suroot/.homeassistant/home-assistant.log
EOF
