#!/usr/bin/env bash
set -euo pipefail

# Full Termux snapshot backup over ADB (requires root via Magisk).
# This captures everything under /data/data/com.termux as a point-in-time archive.
# Usage:
#   ./provisioning/adb/09_backup_termux_full_adb.sh
#   OUTPUT_DIR=./backup ./provisioning/adb/09_backup_termux_full_adb.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/backup/full-termux}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="${OUTPUT_DIR}/termux-full-snapshot-${STAMP}.tar.gz"

mkdir -p "${OUTPUT_DIR}"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found. Install Android platform-tools first." >&2
  exit 1
fi

adb start-server >/dev/null
adb wait-for-device

if ! adb shell su -c 'true' >/dev/null 2>&1; then
  echo "ERROR: Root access via 'su' is required for full snapshot backup." >&2
  echo "Make sure Magisk is installed and ADB shell is granted root permissions." >&2
  exit 1
fi

echo "Creating full Termux snapshot via ADB..."
# Use toybox tar from root shell and stream archive directly to local file.
adb exec-out su -c 'tar -C /data/data -czf - com.termux' > "${ARCHIVE_PATH}"

if [ ! -s "${ARCHIVE_PATH}" ]; then
  echo "ERROR: Snapshot archive is empty: ${ARCHIVE_PATH}" >&2
  exit 1
fi

echo "Full snapshot saved to ${ARCHIVE_PATH}"
echo "Restore (manual): extract archive as root to /data/data on target device."
