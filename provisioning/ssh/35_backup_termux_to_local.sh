#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
PHONE_HOST="${PHONE_HOST:-}"
PHONE_USER="${PHONE_USER:-}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-${ROOT_DIR}/backup}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"

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
  pkg_uid="$(adb shell dumpsys package com.termux 2>/dev/null | tr -d '\r' | awk -F= '/userId=/{print $2; exit}')" || true
  if [[ -n "${pkg_uid:-}" && "${pkg_uid}" =~ ^[0-9]+$ && "${pkg_uid}" -ge 10000 ]]; then
    app_uid=$((pkg_uid - 10000))
    echo "u0_a${app_uid}"
    return 0
  fi
  return 1
}

if [ -z "${PHONE_HOST}" ]; then
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
    echo "  PHONE_HOST=<PHONE_IP> ./provisioning/ssh/35_backup_termux_to_local.sh" >&2
    exit 1
  fi
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER}" ]; then
  PHONE_USER="$(auto_detect_phone_user_adb || true)"
fi

if [ -z "${PHONE_USER}" ]; then
  echo "ERROR: PHONE_USER is required (for example: u0_a123)." >&2
  exit 1
fi

SSH_ID_ARGS=()
if [ -f "${SSH_IDENTITY}" ] && [ -z "${SSH_PASSWORD}" ]; then
  SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
fi

SSH_TRANSPORT=(ssh)
SCP_TRANSPORT=(scp)
SSH_AUTH_OPTS=()
if [ -n "${SSH_PASSWORD}" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required for password-based backup flow." >&2
    exit 1
  fi
  SSH_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" ssh)
  SCP_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" scp)
  SSH_AUTH_OPTS=(
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
  )
fi

if ! nc -z "${PHONE_HOST}" "${SSH_PORT}" >/dev/null 2>&1; then
  echo "ERROR: SSH is not reachable at ${PHONE_HOST}:${SSH_PORT}." >&2
  echo "If phone is USB-connected, run: adb forward tcp:${SSH_PORT} tcp:${SSH_PORT}" >&2
  exit 1
fi

mkdir -p "${LOCAL_BACKUP_DIR}"

STAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE_ROOT=".provisioning/backups"
REMOTE_STAGE_DIR="${REMOTE_ROOT}/${STAMP}"
REMOTE_BUNDLE="${REMOTE_ROOT}/${STAMP}.tar.gz"
LOCAL_BUNDLE="${LOCAL_BACKUP_DIR}/${STAMP}.tar.gz"

SSH_BASE=("${SSH_TRANSPORT[@]}" -F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new)
if [ ${#SSH_AUTH_OPTS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_AUTH_OPTS[@]}")
fi
if [ ${#SSH_ID_ARGS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_ID_ARGS[@]}")
fi

SCP_BASE=("${SCP_TRANSPORT[@]}" -F /dev/null -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new)
if [ ${#SSH_AUTH_OPTS[@]} -gt 0 ]; then
  SCP_BASE+=("${SSH_AUTH_OPTS[@]}")
fi
if [ ${#SSH_ID_ARGS[@]} -gt 0 ]; then
  SCP_BASE+=("${SSH_ID_ARGS[@]}")
fi

echo "Syncing latest backup helper scripts to phone ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "mkdir -p ~/scripts"
"${SCP_BASE[@]}" "${ROOT_DIR}/scripts/termux-backup.sh" "${PHONE_USER}@${PHONE_HOST}:~/scripts/termux-backup.sh"
"${SCP_BASE[@]}" "${ROOT_DIR}/scripts/termux-restore.sh" "${PHONE_USER}@${PHONE_HOST}:~/scripts/termux-restore.sh"
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "chmod 700 ~/scripts/termux-backup.sh ~/scripts/termux-restore.sh"

echo "Creating phone-side configuration backup with ~/scripts/termux-backup.sh ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "mkdir -p '${REMOTE_ROOT}' && ~/scripts/termux-backup.sh '${REMOTE_STAGE_DIR}'"

echo "Packing backup into a single archive on phone ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "tar -C '${REMOTE_ROOT}' -czf '${REMOTE_BUNDLE}' '${STAMP}'"

echo "Downloading backup archive to local path ..."
"${SCP_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}:~/${REMOTE_BUNDLE}" "${LOCAL_BUNDLE}"

echo "Cleaning temporary backup directory on phone ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "rm -rf '${REMOTE_STAGE_DIR}' '${REMOTE_BUNDLE}'"

echo "Backup downloaded to ${LOCAL_BUNDLE}"
