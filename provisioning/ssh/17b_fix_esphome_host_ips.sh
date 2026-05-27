#!/usr/bin/env bash
set -euo pipefail

# Fix ESPHome integration host IPs in Home Assistant's config storage.
#
# When Android hotspot assigns a different subnet, HA loses ESPHome devices
# because it stored stale IPs. This script patches .storage/core.config_entries
# directly on the phone to update ESPHome host entries to the known static IPs.
#
# ESP boards must already use manual_ip in their ESPHome config (done via code):
#   esphymer    → 10.129.28.200
#   hymertest   → 10.129.28.201
#
# Usage (phone connected via USB or reachable over Tailscale):
#   PHONE_HOST=<ip>  PHONE_USER=u0_aXXX ./provisioning/ssh/17b_fix_esphome_host_ips.sh
#
# Or auto-detect via ADB:
#   ./provisioning/ssh/17b_fix_esphome_host_ips.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"

# Known ESP name→IP mapping. Add new boards here as needed.
declare -A ESP_HOSTS=(
  ["esphymer"]="10.129.28.200"
  ["hymertest"]="10.129.28.201"
)

# ── Auto-detect helpers ───────────────────────────────────────────────────────

auto_detect_phone_host_adb() {
  local host=""
  host="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan1 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
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

# ── Resolve SSH connection parameters ────────────────────────────────────────

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

SSH_ID_ARGS=()
if [ -f "${SSH_IDENTITY}" ]; then
  SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
fi

ssh_cmd() {
  ssh -p "${SSH_PORT}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "${SSH_ID_ARGS[@]}" "${PHONE_USER}@${PHONE_HOST}" "$@"
}

CONFIG_ENTRIES="/data/data/com.termux/files/home/.homeassistant/.storage/core.config_entries"

echo "=== ESPHome host IP fixer ==="
echo "Target: ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}"
echo

# ── Verify file exists ────────────────────────────────────────────────────────
ssh_cmd "test -f '${CONFIG_ENTRIES}'" || {
  echo "ERROR: config_entries not found at ${CONFIG_ENTRIES}" >&2
  echo "Is Home Assistant installed and has it run at least once?" >&2
  exit 1
}

# ── Show current ESPHome entries ──────────────────────────────────────────────
echo "Current ESPHome entries in config_entries:"
ssh_cmd "python3 -c \"
import json, sys
data = json.load(open('${CONFIG_ENTRIES}'))
found = False
for entry in data.get('data', {}).get('entries', []):
    if entry.get('domain') == 'esphome':
        found = True
        print(f'  entry_id={entry[\\\"entry_id\\\"]} title={entry.get(\\\"title\\\",\\\"?\\\")} host={entry.get(\\\"data\\\",{}).get(\\\"host\\\",\\\"?\\\")}')
if not found:
    print('  (no ESPHome entries found)')
\""

echo

# ── Patch each known ESP device ───────────────────────────────────────────────
for esp_name in "${!ESP_HOSTS[@]}"; do
  target_ip="${ESP_HOSTS[$esp_name]}"
  echo "Patching '${esp_name}' → ${target_ip} ..."

  RESULT="$(ssh_cmd "python3 -c \"
import json, sys, re

path = '${CONFIG_ENTRIES}'
with open(path) as f:
    data = json.load(f)

entries = data.get('data', {}).get('entries', [])
changed = 0
for entry in entries:
    if entry.get('domain') != 'esphome':
        continue
    title = entry.get('title', '')
    host  = entry.get('data', {}).get('host', '')
    # Match by title containing the ESP name (case-insensitive)
    if re.search(r'${esp_name}', title, re.IGNORECASE) or re.search(r'${esp_name}', host, re.IGNORECASE):
        old_host = entry['data'].get('host', '')
        if old_host != '${target_ip}':
            entry['data']['host'] = '${target_ip}'
            changed += 1
            print(f'CHANGED: {title} {old_host} -> ${target_ip}')
        else:
            print(f'OK: {title} already at ${target_ip}')

if changed:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f'Wrote {changed} change(s) to config_entries')
else:
    print('No changes needed or no matching entry found')
\"")"

  echo "  ${RESULT}"
done

echo
echo "=== Restarting Home Assistant to pick up changes ==="
HASS_CTL="/data/data/com.termux/files/home/scripts/hassctl.sh"
ssh_cmd "sh '${HASS_CTL}' restart 2>/dev/null || echo 'hassctl not available — restart HA manually or run: killall python3 && sh ~/scripts/hass.sh &'"

echo
echo "=== Verification ==="
echo "After HA restarts, check ESPHome device status in HA."
echo "ESP connectivity test from phone:"
echo "  ssh ${PHONE_USER}@${PHONE_HOST} -p ${SSH_PORT} 'ping -c3 10.129.28.200 && ping -c3 10.129.28.201'"
echo
echo "To verify AP subnet is pinned:"
echo "  adb shell su -c 'ip -4 addr show wlan1'"
echo "  Expected: 10.129.28.1/24"
