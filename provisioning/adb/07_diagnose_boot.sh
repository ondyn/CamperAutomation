#!/usr/bin/env bash
set -euo pipefail

# Diagnoses Termux:Boot startup health after a device reboot.
#
# Run from laptop with phone connected via USB:
#   ./provisioning/adb/06_diagnose_boot.sh
#
# Checks performed:
#   1. APK signing key parity (Termux vs Termux:Boot must match)
#   2. Boot script presence and permissions in ~/.termux/boot/
#   3. RECEIVE_BOOT_COMPLETED permission granted to Termux:Boot
#   4. Battery optimization / doze whitelist
#   5. logcat evidence of last boot run
#   6. Current service state (tailscaled, sshd, hass screen)
#   7. bootstrap.log from last run

adb wait-for-device

echo "=== Termux:Boot Boot Diagnostics ==="
echo ""

# --------------------------------------------------------------------------
# 1. Signing key parity
# --------------------------------------------------------------------------
echo "--- 1. Signing key parity ---"
SIG_TERMUX=$(adb shell dumpsys package com.termux 2>/dev/null \
  | grep 'signatures=' | grep -oE '[a-f0-9]{8}' | head -1 || echo "MISSING")
SIG_BOOT=$(adb shell dumpsys package com.termux.boot 2>/dev/null \
  | grep 'signatures=' | grep -oE '[a-f0-9]{8}' | head -1 || echo "MISSING")

echo "  com.termux         signature: ${SIG_TERMUX}"
echo "  com.termux.boot    signature: ${SIG_BOOT}"

if [ "${SIG_TERMUX}" = "${SIG_BOOT}" ] && [ "${SIG_TERMUX}" != "MISSING" ]; then
  echo "  PASS: signatures match (${SIG_TERMUX})"
else
  echo "  FAIL: signature mismatch or package missing"
  echo "        Both Termux and Termux:Boot must be installed from the SAME source"
  echo "        (either both from GitHub releases OR both from F-Droid, not mixed)."
fi
echo ""

# --------------------------------------------------------------------------
# 2. Boot script existence and permissions
# --------------------------------------------------------------------------
echo "--- 2. Boot scripts in ~/.termux/boot/ ---"
adb shell "run-as com.termux ls -la /data/data/com.termux/files/home/.termux/boot/ 2>/dev/null \
  || echo '  FAIL: cannot list boot dir (Termux not installed or not granted run-as)'"
echo ""

# --------------------------------------------------------------------------
# 3. RECEIVE_BOOT_COMPLETED permission
# --------------------------------------------------------------------------
echo "--- 3. RECEIVE_BOOT_COMPLETED permission ---"
BOOT_PERM=$(adb shell dumpsys package com.termux.boot 2>/dev/null \
  | grep 'RECEIVE_BOOT_COMPLETED' | grep 'granted=' | tail -1 | tr -d ' \r')
echo "  ${BOOT_PERM:-NOT_FOUND}"
if [[ "${BOOT_PERM}" == *"granted=true"* ]]; then
  echo "  PASS"
else
  echo "  WARN: permission not granted — Termux:Boot will not start on boot"
  echo "        Fix: grant via ADB: adb shell pm grant com.termux.boot android.permission.RECEIVE_BOOT_COMPLETED"
fi
echo ""

# --------------------------------------------------------------------------
# 4. Battery optimization / doze whitelist
# --------------------------------------------------------------------------
echo "--- 4. Battery optimization whitelist ---"
WHITELIST_RAW="$(adb shell dumpsys deviceidle whitelist 2>/dev/null | tr -d '\r')"
for pkg in com.termux com.termux.boot; do
  WHITELISTED=$(printf '%s\n' "${WHITELIST_RAW}" | grep -E "(^|[[:space:],])${pkg}($|[[:space:],])" | head -1 || true)
  if [ -n "${WHITELISTED}" ]; then
    echo "  PASS: ${pkg} is whitelisted (${WHITELISTED})"
  else
    echo "  WARN: ${pkg} NOT in doze whitelist"
    echo "        On MIUI: Settings > Apps > Manage apps > ${pkg} > Battery saver > No restrictions"
    echo "        Via ADB: adb shell cmd deviceidle whitelist +${pkg}"
  fi
done
echo ""

# --------------------------------------------------------------------------
# 5. logcat evidence of last Termux:Boot run
# --------------------------------------------------------------------------
echo "--- 5. logcat — last Termux:Boot activity ---"
AUTO_START_BLOCKED=$(adb shell logcat -d 2>/dev/null \
  | grep -iE 'Unable to launch app com\.termux\.boot.*auto start' \
  | tail -1 | tr -d '\r' || true)

if [ -n "${AUTO_START_BLOCKED}" ]; then
  echo "  FAIL: MIUI blocked Termux:Boot auto-start at boot"
  echo "  ${AUTO_START_BLOCKED}"
  echo "  Fix on phone: Security app -> Permissions -> Autostart -> enable Termux and Termux:Boot"
  echo "  Then reboot and rerun this diagnostic."
  echo ""
fi

LOGCAT_LINES=$(adb shell logcat -d 2>/dev/null \
  | grep -c 'app=com.termux.boot' 2>/dev/null || echo 0)
echo "  Lines with app=com.termux.boot in current logcat: ${LOGCAT_LINES}"
if [ "${LOGCAT_LINES}" -gt 0 ]; then
  echo "  PASS: Termux:Boot was invoked this boot session"
else
  echo "  WARN: No Termux:Boot activity in logcat."
  echo "        Possible causes:"
  echo "          - Termux:Boot was never launched manually (launch it once after install)"
  echo "          - MIUI auto-start is blocked (enable in Security app)"
  echo "          - Boot receiver disabled by Android package manager"
fi
echo ""

# --------------------------------------------------------------------------
# 6. Current service state
# --------------------------------------------------------------------------
echo "--- 6. Current service state ---"
SSHD_PID=$(adb shell pgrep -x sshd 2>/dev/null | head -1 | tr -d '\r' || true)
TAILSCALED_PID=$(adb shell pgrep -x tailscaled 2>/dev/null | head -1 | tr -d '\r' || true)
# screen sessions are not visible to run-as; check for the hass python process instead
HASS_PID=$(adb shell pgrep -f 'hass.*--config' 2>/dev/null | head -1 | tr -d '\r' || true)

echo "  sshd:       ${SSHD_PID:-(not running)}"
echo "  tailscaled: ${TAILSCALED_PID:-(not running)}"
echo "  hass:       ${HASS_PID:-(not running)}"
echo ""

# --------------------------------------------------------------------------
# 7. bootstrap.log
# --------------------------------------------------------------------------
echo "--- 7. Last bootstrap.log (tail) ---"
adb shell "run-as com.termux cat /data/data/com.termux/files/home/logs/bootstrap.log 2>/dev/null \
  | tail -30 || echo '  (log not found)'"
echo ""

# --------------------------------------------------------------------------
# Self-fix hints
# --------------------------------------------------------------------------
echo "=== Fix commands (if needed) ==="
echo ""
echo "Force-launch Termux:Boot activity once (required after fresh install):"
echo "  adb shell am start -n com.termux.boot/.BootActivity"
echo ""
echo "Exempt Termux + Termux:Boot from MIUI battery optimization:"
echo "  adb shell cmd deviceidle whitelist +com.termux"
echo "  adb shell cmd deviceidle whitelist +com.termux.boot"
echo ""
echo "Start SSH now via ADB (if sshd is not running):"
echo "  adb shell run-as com.termux sh -lc 'export PREFIX=/data/data/com.termux/files/usr; export PATH=\$PREFIX/bin:\$PATH; sshd'"
echo ""
echo "Run bootstrap script manually via ADB (simulates Termux:Boot):"
echo "  adb shell run-as com.termux sh /data/data/com.termux/files/home/scripts/bootstrap_services.sh"
echo ""
echo "=== Done ==="
