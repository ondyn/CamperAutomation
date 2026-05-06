#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
PHONE_HOST="${PHONE_HOST:-127.0.0.1}"
PHONE_USER="${PHONE_USER:-}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-${ROOT_DIR}/backup}"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <local-backup-archive.tar.gz>" >&2
  echo "Example: $0 ${LOCAL_BACKUP_DIR}/20260506-201500.tar.gz" >&2
  exit 1
fi

LOCAL_ARCHIVE="$1"
if [ ! -f "${LOCAL_ARCHIVE}" ]; then
  echo "ERROR: Local backup archive not found: ${LOCAL_ARCHIVE}" >&2
  exit 1
fi

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

STAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE_ROOT=".provisioning/restore"
REMOTE_ARCHIVE="${REMOTE_ROOT}/incoming-${STAMP}.tar.gz"
REMOTE_EXTRACT="${REMOTE_ROOT}/extract-${STAMP}"

SSH_BASE=(ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new)
SCP_BASE=(scp -P "${SSH_PORT}" -o StrictHostKeyChecking=accept-new)

echo "Uploading local backup archive to phone ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "mkdir -p '${REMOTE_ROOT}'"
"${SCP_BASE[@]}" "${LOCAL_ARCHIVE}" "${PHONE_USER}@${PHONE_HOST}:~/${REMOTE_ARCHIVE}"

echo "Extracting backup and applying restore in Termux ..."
"${SSH_BASE[@]}" "${PHONE_USER}@${PHONE_HOST}" "REMOTE_ARCHIVE='${REMOTE_ARCHIVE}' REMOTE_EXTRACT='${REMOTE_EXTRACT}' bash -s" <<'REMOTE_RESTORE'
set -euo pipefail

mkdir -p "${REMOTE_EXTRACT}"
tar -C "${REMOTE_EXTRACT}" -xzf "${REMOTE_ARCHIVE}"
RESTORE_DIR="$(find "${REMOTE_EXTRACT}" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"

if [ -z "${RESTORE_DIR}" ]; then
  echo "ERROR: Could not detect extracted backup directory." >&2
  exit 1
fi

~/scripts/termux-restore.sh "${RESTORE_DIR}"
rm -rf "${REMOTE_ARCHIVE}" "${REMOTE_EXTRACT}"
REMOTE_RESTORE

echo "Restore completed from local archive ${LOCAL_ARCHIVE}"
