#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
PHONE_HOST="${PHONE_HOST:-127.0.0.1}"
PHONE_USER="${PHONE_USER:-}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-${ROOT_DIR}/backup}"

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

if [ -z "${PHONE_USER}" ]; then
  PHONE_USER="$(auto_detect_phone_user_adb || true)"
fi

if [ -z "${PHONE_USER}" ]; then
  echo "ERROR: PHONE_USER is required (for example: u0_a123)." >&2
  exit 1
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

SSH_BASE=(ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new)
SCP_BASE=(scp -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new)

echo "Creating phone-side backup with ~/scripts/termux-backup.sh ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "mkdir -p '${REMOTE_ROOT}' && ~/scripts/termux-backup.sh '${REMOTE_STAGE_DIR}'"

echo "Packing backup into a single archive on phone ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "tar -C '${REMOTE_ROOT}' -czf '${REMOTE_BUNDLE}' '${STAMP}'"

echo "Downloading backup archive to local path ..."
"${SCP_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}:~/${REMOTE_BUNDLE}" "${LOCAL_BUNDLE}"

echo "Cleaning temporary backup directory on phone ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "rm -rf '${REMOTE_STAGE_DIR}' '${REMOTE_BUNDLE}'"

echo "Backup downloaded to ${LOCAL_BUNDLE}"
