#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_SCRIPT="${ROOT_DIR}/provisioning/termux/bootstrap_termux.sh"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found" >&2
  exit 1
fi

if [ ! -f "${LOCAL_SCRIPT}" ]; then
  echo "ERROR: missing local bootstrap script: ${LOCAL_SCRIPT}" >&2
  exit 1
fi

adb wait-for-device

echo "Writing bootstrap script into Termux home (preferred path)..."
if adb shell "run-as com.termux sh -c 'cat > /data/data/com.termux/files/home/bootstrap_termux.sh && chmod 700 /data/data/com.termux/files/home/bootstrap_termux.sh'" < "${LOCAL_SCRIPT}"; then
  echo "✓ Wrote /data/data/com.termux/files/home/bootstrap_termux.sh"
  adb shell "run-as com.termux ls -l /data/data/com.termux/files/home/bootstrap_termux.sh" | tr -d '\r'
else
  echo "WARNING: Could not write directly into Termux home via run-as."
  echo "         Falling back to shared storage paths only."
fi

# Best-effort permission grant for shared storage path (older Android behavior).
adb shell "pm grant com.termux android.permission.READ_EXTERNAL_STORAGE" >/dev/null 2>&1 || true
adb shell "pm grant com.termux android.permission.WRITE_EXTERNAL_STORAGE" >/dev/null 2>&1 || true

# Ensure both common download directories exist and copy fallback files.
adb shell "mkdir -p /sdcard/Download /sdcard/Downloads" >/dev/null

echo "Pushing fallback copies to shared storage..."
adb push "${LOCAL_SCRIPT}" "/sdcard/Download/bootstrap_termux.sh" >/dev/null
adb push "${LOCAL_SCRIPT}" "/sdcard/Downloads/bootstrap_termux.sh" >/dev/null || true
adb shell "chmod 644 /sdcard/Download/bootstrap_termux.sh /sdcard/Downloads/bootstrap_termux.sh" >/dev/null 2>&1 || true

echo "Verifying pushed files..."
adb shell "ls -l /sdcard/Download/bootstrap_termux.sh" | tr -d '\r'
adb shell "ls -l /sdcard/Downloads/bootstrap_termux.sh" | tr -d '\r' || true
echo "Version marker from Termux-home copy:"
adb shell "run-as com.termux sh -lc 'grep -n BOOTSTRAP_VERSION /data/data/com.termux/files/home/bootstrap_termux.sh | head -n1'" | tr -d '\r' || true

cat <<EOF
Bootstrap script has been delivered.

In Termux, run:
  bash ~/bootstrap_termux.sh

Alternate explicit path:
  bash /data/data/com.termux/files/home/bootstrap_termux.sh

Note: /sdcard paths may be inaccessible until storage permissions are granted in Termux.
EOF
