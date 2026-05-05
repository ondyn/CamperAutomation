#!/usr/bin/env bash
set -euo pipefail

# Diagnoses Home Assistant runtime health on phone after reboot.
#
# Run from laptop with phone connected via USB:
#   ./provisioning/adb/08_diagnose_hass.sh

adb wait-for-device

echo "=== Home Assistant Runtime Diagnostics ==="
echo ""

TERMUX_HOME="/data/data/com.termux/files/home"
HASS_SCRIPT="${TERMUX_HOME}/scripts/hass.sh"
RUN_LOG="${TERMUX_HOME}/logs/hass-runner.log"
BOOT_LOG="${TERMUX_HOME}/logs/bootstrap.log"
ROOT_HA_LOG="${TERMUX_HOME}/.suroot/.homeassistant/home-assistant.log"
USER_HA_LOG="${TERMUX_HOME}/.homeassistant/home-assistant.log"

run_termux() {
  local cmd="$1"
  local wrapped="export PREFIX=/data/data/com.termux/files/usr; export PATH=\$PREFIX/bin:\$PATH; ${cmd}"
  adb shell "run-as com.termux sh -lc $(printf '%q' "$wrapped")"
}

# --------------------------------------------------------------------------
# 1. Script and venv checks
# --------------------------------------------------------------------------
echo "--- 1. Launcher and venv checks ---"
run_termux "ls -l '${HASS_SCRIPT}' 2>/dev/null || echo '  FAIL: missing ${HASS_SCRIPT}'"
run_termux "if [ -x '${TERMUX_HOME}/.venv/bin/hass' ]; then echo '  PASS: hass binary exists'; else echo '  FAIL: missing ${TERMUX_HOME}/.venv/bin/hass'; fi"
echo ""

# --------------------------------------------------------------------------
# 2. Process checks
# --------------------------------------------------------------------------
echo "--- 2. Home Assistant process state ---"
HASS_PROC="$(run_termux "pgrep -a -f 'homeassistant|hass.*--config' | grep -v 'pgrep -a -f' || true" 2>/dev/null | tr -d '\r' || true)"
if [ -n "${HASS_PROC}" ]; then
  echo "  PASS: Home Assistant process found"
  echo "${HASS_PROC}" | sed 's/^/  /'
else
  echo "  FAIL: Home Assistant process not found"
fi

if run_termux "screen -ls 2>/dev/null | grep -q '[.]hass'" >/dev/null 2>&1; then
  echo "  INFO: screen session '.hass' exists"
  if [ -z "${HASS_PROC}" ]; then
    echo "  WARN: stale screen session detected (session exists but HA process is absent)"
  fi
else
  echo "  INFO: no '.hass' screen session present"
fi
echo ""

# --------------------------------------------------------------------------
# 3. Listener and local HTTP probe
# --------------------------------------------------------------------------
echo "--- 3. Listener and HTTP probe (:8123) ---"
LISTENER="$(adb shell "toybox netstat -tnl 2>/dev/null | grep ':8123' || true" | tr -d '\r' || true)"
if [ -n "${LISTENER}" ]; then
  echo "  PASS: listener on :8123 detected"
  echo "${LISTENER}" | sed 's/^/  /'
else
  echo "  WARN: no :8123 listener visible via ss"
fi

HTTP_CODE="$(run_termux "if command -v curl >/dev/null 2>&1; then code=\$(curl -sS -m 6 -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/); rc=\$?; if [ \$rc -eq 0 ]; then echo \"\$code\"; else echo ERR; fi; else echo NO_CURL; fi" 2>/dev/null | tr -d '\r' || true)"
case "${HTTP_CODE}" in
  200|401|403)
    echo "  PASS: HTTP probe returned ${HTTP_CODE}"
    ;;
  NO_CURL)
    echo "  WARN: curl is not installed in Termux; HTTP probe skipped"
    ;;
  ERR|"")
    echo "  FAIL: HTTP probe failed (connection error)"
    ;;
  *)
    echo "  WARN: HTTP probe returned unexpected code ${HTTP_CODE}"
    ;;
esac
echo ""

# --------------------------------------------------------------------------
# 4. Runtime logs
# --------------------------------------------------------------------------
echo "--- 4. hass-runner log tail ---"
run_termux "if [ -f '${RUN_LOG}' ]; then tail -n 80 '${RUN_LOG}'; else echo '  (log not found)'; fi"
echo ""

echo "--- 5. Home Assistant core log tail ---"
HAS_ROOT_LOG="$(run_termux "[ -f '${ROOT_HA_LOG}' ] && echo yes || echo no" | tr -d '\r')"
if [ "${HAS_ROOT_LOG}" = "yes" ]; then
  echo "  Source: ${ROOT_HA_LOG}"
  run_termux "tail -n 80 '${ROOT_HA_LOG}'"
else
  HAS_USER_LOG="$(run_termux "[ -f '${USER_HA_LOG}' ] && echo yes || echo no" | tr -d '\r')"
  if [ "${HAS_USER_LOG}" = "yes" ]; then
    echo "  Source: ${USER_HA_LOG}"
    run_termux "tail -n 80 '${USER_HA_LOG}'"
  else
    echo "  (log not found in either ${ROOT_HA_LOG} or ${USER_HA_LOG})"
  fi
fi
echo ""

# --------------------------------------------------------------------------
# 6. Bootstrap correlation
# --------------------------------------------------------------------------
echo "--- 6. bootstrap.log HA lines ---"
run_termux "if [ -f '${BOOT_LOG}' ]; then grep 'HA:' '${BOOT_LOG}' | tail -n 30; else echo '  (bootstrap.log not found)'; fi"
echo ""

echo "=== Done ==="
