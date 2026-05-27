#!/usr/bin/env bash
set -euo pipefail

# Install / update a Home Assistant automation that reloads the ESPHome config
# entry when HymerTest (or EspHymer) stays unavailable after a hotspot reconnect.
#
# File manipulation is done entirely via ADB (pull → process locally → push back).
# Only Home Assistant restart is done over SSH.
#
# Usage (auto-detect via adb):
#   ./provisioning/ssh/22_install_esphome_reconnect_guard.sh
#
# Override if needed:
#   PHONE_HOST=10.129.28.1  PHONE_USER=u0_a270  SSH_PASSWORD=secret \
#   ./provisioning/ssh/22_install_esphome_reconnect_guard.sh

HASS_DIR="/data/data/com.termux/files/home/.homeassistant"
AUTOMATIONS_REMOTE="${HASS_DIR}/automations.yaml"
CONFIG_ENTRIES_REMOTE="${HASS_DIR}/.storage/core.config_entries"
AUTOMATIONS_TMP="/tmp/camper_automations.yaml"
CONFIG_ENTRIES_TMP="/tmp/camper_config_entries.json"
ENTITY_REGISTRY_TMP="/tmp/camper_entity_registry.json"
ENTITY_REGISTRY_REMOTE="${HASS_DIR}/.storage/core.entity_registry"
ADB_STAGE="/data/local/tmp/camper_automations.yaml"

# Guard unavailability timer: 30s is enough since ESP32-C3 boots and connects in ~12s
UNAVAILABLE_FOR="00:00:30"

# ── Auto-detect helpers (same pattern as all other provisioning scripts) ──────

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
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"

SSH_ID_ARGS=()
if [ -f "${SSH_IDENTITY}" ] && [ -z "${SSH_PASSWORD}" ]; then
  SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
fi

SSH_TRANSPORT=(ssh)
SSH_AUTH_OPTS=()
if [ -n "${SSH_PASSWORD}" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required for password-based SSH. Install with: brew install sshpass" >&2
    exit 1
  fi
  SSH_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" ssh)
  SSH_AUTH_OPTS=(
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
  )
fi

SSH_BASE=(
  "${SSH_TRANSPORT[@]}"
  -F /dev/null
  -p "${SSH_PORT}"
  -o ClearAllForwardings=yes
  -o ForwardAgent=no
  -o StrictHostKeyChecking=accept-new
)
[ ${#SSH_AUTH_OPTS[@]} -gt 0 ] && SSH_BASE+=("${SSH_AUTH_OPTS[@]}")
[ ${#SSH_ID_ARGS[@]} -gt 0 ]   && SSH_BASE+=("${SSH_ID_ARGS[@]}")
SSH_BASE+=("${PHONE_USER}@${PHONE_HOST}")

ssh_run() {
  "${SSH_BASE[@]}" "$@"
}

# ── Step 1: Pull files from device via ADB ─────────────────────────────────────

echo "Pulling files from device..."
adb shell su -c "cat '${CONFIG_ENTRIES_REMOTE}'"  > "${CONFIG_ENTRIES_TMP}"
adb shell su -c "cat '${ENTITY_REGISTRY_REMOTE}'" > "${ENTITY_REGISTRY_TMP}"
adb shell su -c "cat '${AUTOMATIONS_REMOTE}'"     > "${AUTOMATIONS_TMP}"

# ── Step 2: Extract entry_ids AND trigger entity IDs from local JSON ────────────

# Returns "<entry_id> <trigger_entity_id>" for a given ESPHome device name pattern.
extract_data() {
  local pattern="$1"
  python3 - "${CONFIG_ENTRIES_TMP}" "${ENTITY_REGISTRY_TMP}" "${pattern}" <<'PYEOF'
import json, sys, re
cfg_path, reg_path, pattern = sys.argv[1:]
cfg = json.load(open(cfg_path))
reg = json.load(open(reg_path))
entry_id = ""
for e in cfg["data"]["entries"]:
    if e.get("domain") == "esphome" and re.search(pattern, e.get("title",""), re.IGNORECASE):
        entry_id = e["entry_id"]
        break
trigger_entity = ""
for e in reg["data"]["entities"]:
    if e.get("config_entry_id") != entry_id or e.get("disabled_by") is not None:
        continue
    eid = e["entity_id"]
    if eid.startswith("switch."):
        trigger_entity = eid
        break
    if eid.startswith("sensor.") and not trigger_entity:
        trigger_entity = eid
print(entry_id, trigger_entity)
PYEOF
}

HT_DATA="$(extract_data 'hymertest')"
HYMERTEST_ENTRY_ID="$(echo "${HT_DATA}" | awk '{print $1}')"
HYMERTEST_TRIGGER="$(echo  "${HT_DATA}" | awk '{print $2}')"

EH_DATA="$(extract_data 'esphymer')"
ESPHYMER_ENTRY_ID="$(echo  "${EH_DATA}" | awk '{print $1}')"
ESPHYMER_TRIGGER="$(echo   "${EH_DATA}" | awk '{print $2}')"

[ -n "${HYMERTEST_ENTRY_ID}" ] && echo "HymerTest  entry_id=${HYMERTEST_ENTRY_ID}  trigger=${HYMERTEST_TRIGGER}" \
  || echo "WARN: HymerTest entry not found in config_entries"
[ -n "${ESPHYMER_ENTRY_ID}" ]  && echo "EspHymer   entry_id=${ESPHYMER_ENTRY_ID}   trigger=${ESPHYMER_TRIGGER}" \
  || echo "INFO: EspHymer entry not found (will skip)"

# ── Step 3: Inject / update automations locally ────────────────────────────────

inject_or_update_automation() {
  local automation_id="$1"
  local entity_id="$2"
  local entry_id="$3"
  local label="$4"

  if [ -z "${entry_id}" ]; then
    echo "Skipping automation for ${label}: no entry_id found."
    return
  fi

  if grep -q "id: ${automation_id}" "${AUTOMATIONS_TMP}"; then
    echo "Automation '${automation_id}' exists — updating entity_id, entry_id, for-timer..."
    python3 - "${AUTOMATIONS_TMP}" "${automation_id}" "${entity_id}" "${entry_id}" "${UNAVAILABLE_FOR}" <<'PYEOF'
import sys, re
path, auto_id, new_entity_id, new_entry_id, new_for = sys.argv[1:]
lines = open(path).readlines()
out = []
in_block = False
for line in lines:
    if re.match(r'^- id: ' + re.escape(auto_id) + r'\s*$', line):
        in_block = True
    elif re.match(r'^- id: ', line):
        in_block = False
    if in_block:
        if re.match(r'\s+entry_id:\s*', line):
            line = ' ' * (len(line)-len(line.lstrip())) + 'entry_id: ' + new_entry_id + '\n'
        elif re.match(r'\s+entity_id:\s*', line):
            line = ' ' * (len(line)-len(line.lstrip())) + 'entity_id: ' + new_entity_id + '\n'
        elif re.match(r'\s+for:\s*', line):
            line = ' ' * (len(line)-len(line.lstrip())) + 'for: "' + new_for + '"\n'
    out.append(line)
open(path, 'w').writelines(out)
print(f'  Updated: entity_id={new_entity_id}  entry_id={new_entry_id}  for={new_for}')
PYEOF
  else
    echo "Adding new automation '${automation_id}' for ${label}..."
    printf '\n- id: %s\n' "${automation_id}"                               >> "${AUTOMATIONS_TMP}"
    printf '  alias: ESPHome %s reconnect guard\n' "${label}"              >> "${AUTOMATIONS_TMP}"
    printf '  description: Reload %s entry when unavailable.\n' "${label}" >> "${AUTOMATIONS_TMP}"
    printf '  mode: single\n'                                               >> "${AUTOMATIONS_TMP}"
    printf '  trigger:\n'                                                   >> "${AUTOMATIONS_TMP}"
    printf '    - platform: state\n'                                        >> "${AUTOMATIONS_TMP}"
    printf '      entity_id: %s\n' "${entity_id}"                          >> "${AUTOMATIONS_TMP}"
    printf '      to: unavailable\n'                                        >> "${AUTOMATIONS_TMP}"
    printf '      for: "%s"\n' "${UNAVAILABLE_FOR}"                          >> "${AUTOMATIONS_TMP}"
    printf '  condition: []\n'                                              >> "${AUTOMATIONS_TMP}"
    printf '  action:\n'                                                    >> "${AUTOMATIONS_TMP}"
    printf '    - delay: "00:00:10"\n'                                      >> "${AUTOMATIONS_TMP}"
    printf '    - action: homeassistant.reload_config_entry\n'              >> "${AUTOMATIONS_TMP}"
    printf '      data:\n'                                                  >> "${AUTOMATIONS_TMP}"
    printf '        entry_id: %s\n' "${entry_id}"                          >> "${AUTOMATIONS_TMP}"
  fi
}

inject_or_update_automation \
  "esphome_hymertest_reconnect_guard" \
  "${HYMERTEST_TRIGGER}" \
  "${HYMERTEST_ENTRY_ID}" \
  "HymerTest"

inject_or_update_automation \
  "esphome_esphymer_reconnect_guard" \
  "${ESPHYMER_TRIGGER}" \
  "${ESPHYMER_ENTRY_ID}" \
  "EspHymer"

# ── Step 4: Push updated automations back via ADB ─────────────────────────────

echo "Pushing updated automations.yaml to device..."
adb push "${AUTOMATIONS_TMP}" "${ADB_STAGE}" >/dev/null
adb shell "run-as com.termux sh -c 'cat ${ADB_STAGE} > ${AUTOMATIONS_REMOTE}'"
adb shell "rm -f ${ADB_STAGE}"
echo "automations.yaml pushed."

# ── Step 5: Restart Home Assistant via SSH ─────────────────────────────────────

echo "Restarting Home Assistant on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."
ssh_run '/data/data/com.termux/files/home/scripts/hassctl.sh restart'

echo
echo "=== Done ==="
echo "Automations installed:"
[ -n "${HYMERTEST_ENTRY_ID}" ] && echo "  esphome_hymertest_reconnect_guard  trigger=${HYMERTEST_TRIGGER}  for=${UNAVAILABLE_FOR}"
[ -n "${ESPHYMER_ENTRY_ID}" ]  && echo "  esphome_esphymer_reconnect_guard   trigger=${ESPHYMER_TRIGGER}   for=${UNAVAILABLE_FOR}"
echo
echo "Verify:"
echo "  adb shell \"run-as com.termux grep -A5 'reconnect_guard' ${AUTOMATIONS_REMOTE}\""
