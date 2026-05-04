#!/usr/bin/env bash
set -euo pipefail

# Detect phone connectivity details (PHONE_HOST and PHONE_USER).
# Usage:
#   source ./provisioning/adb/detect_phone_info.sh
#   echo "Host: ${PHONE_HOST}, User: ${PHONE_USER}"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found" >&2
  return 1
fi

# Try to get PHONE_HOST from ADB connection
auto_detect_phone_host() {
  adb wait-for-device >/dev/null 2>&1 || {
    echo "ERROR: Phone not connected via ADB" >&2
    return 1
  }
  
  # Try DHCP IP first (most reliable on hotspot)
  local ip
  ip=$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
  
  if [ -z "${ip}" ]; then
    # Fallback to wlan0 inet addr
    ip=$(adb shell ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | tr -d '\r')
  fi
  
  if [ -z "${ip}" ]; then
    echo "ERROR: Could not detect phone IP address" >&2
    return 1
  fi
  
  echo "${ip}"
}

# Try to get PHONE_USER from Termux (requires SSH to already be up or adb shell)
auto_detect_phone_user() {
  local host="$1"
  local port="${2:-8022}"
  
  # Try to get via direct adb shell first (faster, works while bootstrapping)
  local user
  user=$(adb shell 'getprop ro.build.user' 2>/dev/null | tr -d '\r')
  
  if [ -z "${user}" ]; then
    # Fallback: ssh attempt to get whoami
    if ssh -p "${port}" -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new "u0_a231@${host}" whoami >/dev/null 2>&1; then
      user=$(ssh -p "${port}" -o ConnectTimeout=2 "u0_a231@${host}" whoami 2>/dev/null | tr -d '\r')
    fi
  fi
  
  if [ -z "${user}" ]; then
    # Last resort: check common Termux user patterns by iterating
    for candidate_uid in a231 a232 a233 a234 a235 a236; do
      if ssh -p "${port}" -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new "u0_${candidate_uid}@${host}" echo OK >/dev/null 2>&1; then
        user="u0_${candidate_uid}"
        break
      fi
    done
  fi
  
  if [ -z "${user}" ]; then
    echo "INFO: Could not auto-detect Termux user; you may need to specify PHONE_USER manually" >&2
    return 1
  fi
  
  echo "${user}"
}

# Export detected values (if not already set)
PHONE_HOST="${PHONE_HOST:-}"
PHONE_USER="${PHONE_USER:-}"

if [ -z "${PHONE_HOST}" ]; then
  PHONE_HOST=$(auto_detect_phone_host)
  export PHONE_HOST
fi

echo "Detected PHONE_HOST: ${PHONE_HOST}"
