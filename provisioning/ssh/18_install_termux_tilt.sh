#!/usr/bin/env bash
set -euo pipefail

# Deploy local termux_tilt custom component into the active Home Assistant config on phone.
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/18_install_termux_tilt.sh
# Or (auto-detect over ADB):
#   ./provisioning/ssh/18_install_termux_tilt.sh
#
# Optional variables:
#   SSH_PORT=8022
#   SSH_IDENTITY=~/.ssh/camper_automation_rsa
#   SSH_PASSWORD=secret
#   RESTART_HA=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_COMPONENT_DIR="${ROOT_DIR}/hass-config/custom_components/termux_tilt"
LOCAL_CARD_FILE="${ROOT_DIR}/hass-config/www/termux-tilt-card.js"
LOCAL_IMAGE_FILE="${ROOT_DIR}/hass-config/www/van-top.png"
SSH_PORT="${SSH_PORT:-8022}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"
RESTART_HA="${RESTART_HA:-1}"

if [ ! -d "${LOCAL_COMPONENT_DIR}" ]; then
  echo "ERROR: local component directory is missing: ${LOCAL_COMPONENT_DIR}" >&2
  exit 1
fi

if [ ! -f "${LOCAL_COMPONENT_DIR}/manifest.json" ]; then
  echo "ERROR: local manifest missing: ${LOCAL_COMPONENT_DIR}/manifest.json" >&2
  exit 1
fi

if [ ! -f "${LOCAL_CARD_FILE}" ]; then
  echo "ERROR: local Lovelace card file is missing: ${LOCAL_CARD_FILE}" >&2
  exit 1
fi

if [ ! -f "${LOCAL_IMAGE_FILE}" ]; then
  echo "ERROR: local van image file is missing: ${LOCAL_IMAGE_FILE}" >&2
  exit 1
fi

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

SSH_ID_ARGS=()
if [ -f "${SSH_IDENTITY}" ] && [ -z "${SSH_PASSWORD}" ]; then
  SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
fi

SSH_TRANSPORT=(ssh)
SSH_AUTH_OPTS=()
if [ -n "${SSH_PASSWORD}" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required for password-based provisioning SSH flow." >&2
    exit 1
  fi
  SSH_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" ssh)
  SSH_AUTH_OPTS=(
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
  )
fi

SSH_BASE=("${SSH_TRANSPORT[@]}" -F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new)
if [ ${#SSH_AUTH_OPTS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_AUTH_OPTS[@]}")
fi
if [ ${#SSH_ID_ARGS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_ID_ARGS[@]}")
fi
SSH_BASE+=("${PHONE_USER}@${PHONE_HOST}")

echo "Resolving active Home Assistant config directory on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."
REMOTE_HASS_CONFIG_DIR="$("${SSH_BASE[@]}" 'env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s' <<'REMOTE_DETECT'
set -euo pipefail
unset BASH_ENV ENV

ROOT_HA_CONFIG="$HOME/.suroot/.homeassistant"
USER_HA_CONFIG="$HOME/.homeassistant"

if [ -f "$ROOT_HA_CONFIG/configuration.yaml" ] && [ -w "$ROOT_HA_CONFIG" ]; then
  echo "$ROOT_HA_CONFIG"
elif [ -f "$USER_HA_CONFIG/configuration.yaml" ] && [ -w "$USER_HA_CONFIG" ]; then
  echo "$USER_HA_CONFIG"
elif [ -d "$ROOT_HA_CONFIG" ] && [ -w "$ROOT_HA_CONFIG" ]; then
  echo "$ROOT_HA_CONFIG"
else
  mkdir -p "$USER_HA_CONFIG"
  echo "$USER_HA_CONFIG"
fi
REMOTE_DETECT
)"

if [ -z "${REMOTE_HASS_CONFIG_DIR}" ]; then
  echo "ERROR: could not determine remote HA config directory" >&2
  exit 1
fi

echo "Using remote Home Assistant config: ${REMOTE_HASS_CONFIG_DIR}"

echo "Creating backup and preparing target directory..."
"${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<REMOTE_PREP
set -euo pipefail
unset BASH_ENV ENV
TARGET_DIR="${REMOTE_HASS_CONFIG_DIR}/custom_components/termux_tilt"
BACKUP_DIR="${REMOTE_HASS_CONFIG_DIR}/.backup/custom_components/termux_tilt.\$(date +%Y%m%d-%H%M%S)"
CARD_TARGET="${REMOTE_HASS_CONFIG_DIR}/www/termux-tilt-card.js"
CARD_BACKUP="${REMOTE_HASS_CONFIG_DIR}/.backup/www/termux-tilt-card.js.\$(date +%Y%m%d-%H%M%S)"
IMAGE_TARGET="${REMOTE_HASS_CONFIG_DIR}/www/van-top.png"
IMAGE_BACKUP="${REMOTE_HASS_CONFIG_DIR}/.backup/www/van-top.png.\$(date +%Y%m%d-%H%M%S)"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/custom_components"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/.backup/custom_components"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/www"
mkdir -p "${REMOTE_HASS_CONFIG_DIR}/.backup/www"
find "${REMOTE_HASS_CONFIG_DIR}/custom_components" -maxdepth 1 -type d -name 'termux_tilt.bak*' -exec rm -rf {} +
if [ -d "\$TARGET_DIR" ]; then
  cp -a "\$TARGET_DIR" "\$BACKUP_DIR"
  echo "Backup created: \$BACKUP_DIR"
fi
if [ -f "\$CARD_TARGET" ]; then
  cp -a "\$CARD_TARGET" "\$CARD_BACKUP"
  echo "Card backup created: \$CARD_BACKUP"
fi
if [ -f "\$IMAGE_TARGET" ]; then
  cp -a "\$IMAGE_TARGET" "\$IMAGE_BACKUP"
  echo "Image backup created: \$IMAGE_BACKUP"
fi
rm -rf "\$TARGET_DIR"
mkdir -p "\$TARGET_DIR"
REMOTE_PREP

echo "Uploading component, card, and image files..."
REMOTE_COMPONENT_TAR="\$HOME/.cache/provisioning/termux_tilt_bundle.tar"
"${SSH_BASE[@]}" 'mkdir -p "$HOME/.cache/provisioning"'
tar -C "${ROOT_DIR}/hass-config" -cf - custom_components/termux_tilt www/termux-tilt-card.js www/van-top.png | "${SSH_BASE[@]}" "cat > \"${REMOTE_COMPONENT_TAR}\""
"${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<REMOTE_EXTRACT
set -euo pipefail
unset BASH_ENV ENV
TARGET_PARENT="${REMOTE_HASS_CONFIG_DIR}"
REMOTE_COMPONENT_TAR="\$HOME/.cache/provisioning/termux_tilt_bundle.tar"
tar -xf "\$REMOTE_COMPONENT_TAR" -C "\$TARGET_PARENT"
rm -f "\$REMOTE_COMPONENT_TAR"
[ -f "\$TARGET_PARENT/custom_components/termux_tilt/manifest.json" ]
[ -f "\$TARGET_PARENT/www/termux-tilt-card.js" ]
[ -f "\$TARGET_PARENT/www/van-top.png" ]
REMOTE_EXTRACT

echo "Registering Lovelace resource /local/termux-tilt-card.js (overwrite in place)..."
"${SSH_BASE[@]}" "REMOTE_HASS_CONFIG_DIR='${REMOTE_HASS_CONFIG_DIR}' env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<'REMOTE_RESOURCE'
set -euo pipefail
unset BASH_ENV ENV

RESOURCE_FILE="${REMOTE_HASS_CONFIG_DIR}/.storage/lovelace_resources"
if [ ! -f "$RESOURCE_FILE" ]; then
  echo "NOTE: $RESOURCE_FILE not found yet; add resource manually after first dashboard load: /local/termux-tilt-card.js"
  exit 0
fi

PYTHON_BIN="$HOME/.venv/bin/python"
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="python"
fi

"$PYTHON_BIN" - "$RESOURCE_FILE" <<'PY'
import json
import shutil
import sys
import uuid
from datetime import datetime, timezone

resource_file = sys.argv[1]
resource_url = "/local/termux-tilt-card.js"

with open(resource_file, "r", encoding="utf-8") as f:
  payload = json.load(f)

data = payload.get("data")
if isinstance(data, dict):
  resources = data.get("items")
  if not isinstance(resources, list):
    resources = data.get("resources")
else:
  resources = data

if not isinstance(resources, list):
  print("WARNING: Unsupported lovelace_resources structure; register /local/termux-tilt-card.js manually")
  sys.exit(0)

backup = f"{resource_file}.bak.{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(resource_file, backup)

for item in resources:
  if isinstance(item, dict) and not isinstance(item.get("id"), str):
    item["id"] = str(uuid.uuid4())

matching_indices = [
  idx for idx, item in enumerate(resources)
  if isinstance(item, dict) and str(item.get("url", "")).split("?", 1)[0] == resource_url
]

resource_entry = {
  "id": str(uuid.uuid4()),
  "res_type": "module",
  "type": "module",
  "url": resource_url,
}

if matching_indices:
  primary_index = matching_indices[0]
  resources[primary_index].update(resource_entry)
  for duplicate_index in reversed(matching_indices[1:]):
    resources.pop(duplicate_index)
  print(f"Updated Lovelace resource: {resource_url}")
  if len(matching_indices) > 1:
    print(f"Removed duplicate entries: {len(matching_indices) - 1}")
else:
  resources.append(resource_entry)
  print(f"Registered Lovelace resource: {resource_url}")

if isinstance(data, dict):
  if isinstance(data.get("items"), list):
    data["items"] = resources
  elif isinstance(data.get("resources"), list):
    data["resources"] = resources
else:
  payload["data"] = resources

with open(resource_file, "w", encoding="utf-8") as f:
  json.dump(payload, f, ensure_ascii=True, separators=(",", ":"))

print(f"Backup created: {backup}")
PY
REMOTE_RESOURCE

echo "Installing integration Python requirements (if declared in manifest)..."
"${SSH_BASE[@]}" "REMOTE_HASS_CONFIG_DIR='${REMOTE_HASS_CONFIG_DIR}' env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -s" <<'REMOTE_REQS'
set -euo pipefail
unset BASH_ENV ENV
VENV_PY="$HOME/.venv/bin/python"
MANIFEST_PATH="${REMOTE_HASS_CONFIG_DIR}/custom_components/termux_tilt/manifest.json"
if [ ! -x "$VENV_PY" ]; then
  echo "WARNING: HA venv python not found at $VENV_PY; skipping requirement install." >&2
  exit 0
fi
REQS="$($VENV_PY -c 'import json, sys; data=json.load(open(sys.argv[1], "r", encoding="utf-8")); print("\n".join(data.get("requirements", [])))' "$MANIFEST_PATH")"
if [ -n "$REQS" ]; then
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    "$VENV_PY" -m pip install --disable-pip-version-check "$req"
  done <<EOF
$REQS
EOF
else
  echo "No requirements declared in termux_tilt manifest."
fi
REMOTE_REQS

if [ "${RESTART_HA}" = "1" ]; then
  echo "Restarting Home Assistant..."
  "${SSH_BASE[@]}" "env -u BASH_ENV -u ENV /data/data/com.termux/files/usr/bin/bash -lc '\$HOME/scripts/hassctl.sh restart && \$HOME/scripts/hassctl.sh status'"
else
  echo "Skipping Home Assistant restart because RESTART_HA=${RESTART_HA}"
fi

echo "termux_tilt deployment finished successfully."
echo "Next: Home Assistant UI -> Settings -> Devices & Services -> Add Integration -> Termux Tilt Meter"
echo "Add card type custom:termux-tilt-card and map its entity IDs in dashboard YAML/editor."
