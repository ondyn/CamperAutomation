#!/usr/bin/env bash
set -euo pipefail

# Patch homeassistant/helpers/translation.py to resolve [%key:X::Y::Z%] refs
# at cache-build time using homeassistant/strings.json.
#
# Problem:
#   HA pip packages ship translation files (e.g. switch/translations/en.json,
#   sensor/translations/en.json) with unresolved source-format references like
#   "[%key:common::state::off%]" instead of "Off". HA release builds resolve
#   these at compile time, but plain pip installs (used on Android/Termux) do not.
#   As a result the frontend displays raw keys like "[%key:common::state::off%]"
#   instead of human-readable strings such as "Off".
#
# Fix:
#   Patch _build_category_cache in translation.py to call _resolve_key_refs()
#   after recursive_flatten(), which substitutes [%key:X::Y::Z%] values with
#   the corresponding resolved strings from homeassistant/strings.json.
#   strings.json is loaded at module import time (before the async event loop)
#   to avoid blocking-I/O-in-event-loop warnings.
#
# Must be re-applied after every `pip install --upgrade homeassistant`.
# provisioning/ssh/10_install_homeassistant_core.sh now applies this patch
# automatically on every (re)install, so this script is mainly a standalone
# repair tool for an already-running install (e.g. right after a manual
# `pip install --upgrade homeassistant` outside the provisioning flow).
#
# Usage:
#   ./provisioning/ssh/23_fix_ha_translation_keys.sh        # auto-detect via ADB
#   PHONE_HOST=192.168.x.x ./23_fix_ha_translation_keys.sh  # explicit host
#
# Optional env vars:
#   SKIP_RESTART=1   — skip HA restart after applying patch

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_SCRIPT="${ROOT_DIR}/provisioning/ssh/ha_translation_patch.py"

# ── Auto-detect PHONE_HOST ────────────────────────────────────────────────────
if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST via ADB..."
  PHONE_HOST="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [ -n "${PHONE_HOST}" ] || PHONE_HOST="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 | tr -d '\r' || true)"
  [ -n "${PHONE_HOST}" ] || PHONE_HOST="$(adb shell ip -4 addr show wlan1 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 | tr -d '\r' || true)"
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi
[ -n "${PHONE_HOST:-}" ] || { echo "ERROR: could not detect PHONE_HOST" >&2; exit 1; }

HA_VENV="/data/data/com.termux/files/home/.venv"
HA_TRANS="${HA_VENV}/lib/python3.13/site-packages/homeassistant/helpers/translation.py"
STAGE="/data/local/tmp/ha_translation_patched.py"

# ── Apply the shared patch script ─────────────────────────────────────────────
echo "Applying translation.py patch..."

# Stage the patch where the Termux app can read it, then run it as Termux.
# Android's root SELinux context cannot reliably access Termux private storage.
adb push "${PATCH_SCRIPT}" "${STAGE}" >/dev/null
adb shell "run-as com.termux /data/data/com.termux/files/usr/bin/sh -c 'backup_dir=/data/data/com.termux/files/home/.cache/provisioning; mkdir -p \"\$backup_dir\" && cp ${HA_TRANS} \"\$backup_dir/translation.py.$(date +%Y%m%d-%H%M%S).bak\" && /data/data/com.termux/files/home/.venv/bin/python ${STAGE} ${HA_TRANS}'"
adb shell "rm -f ${STAGE}"
echo "translation.py patched on device."

# ── Restart HA ────────────────────────────────────────────────────────────────
if [ "${SKIP_RESTART:-0}" = "1" ]; then
  echo "SKIP_RESTART=1 — skipping HA restart."
else
  echo "Restarting Home Assistant..."
  # TMPDIR must point inside Termux's writable tree so 'sh' can create heredoc
  # temp files (<<EOF blocks in hassctl.sh). Without it, adb shell uses the
  # system /data/local/tmp which is root-only, causing "Permission denied".
  TERMUX_HOME="/data/data/com.termux/files/home"
  TERMUX_BIN="/data/data/com.termux/files/usr/bin"
  TERMUX_TMP="/data/data/com.termux/files/usr/tmp"
  adb shell "run-as com.termux env TMPDIR=${TERMUX_TMP} HOME=${TERMUX_HOME} ${TERMUX_BIN}/sh ${TERMUX_HOME}/scripts/hassctl.sh restart" || true
  echo "HA restart triggered."
fi

echo ""
echo "=== Done ==="
echo "The [%key:common::state::off%] display issue should now be resolved."
echo "Re-run this script after every 'pip install --upgrade homeassistant'."
