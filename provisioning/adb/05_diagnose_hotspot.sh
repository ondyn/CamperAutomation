#!/usr/bin/env bash
set -euo pipefail

# Hotspot diagnostics: detect which command works on this Xiaomi ROM.
# Usage:
#   ./provisioning/adb/05_diagnose_hotspot.sh
#
# This probes all known hotspot control methods on the connected device.
# Useful for determining fallback strategy if Magisk service script doesn't work.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${ROOT_DIR}/provisioning/logs"
mkdir -p "${LOG_DIR}"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found" >&2
  exit 1
fi

adb wait-for-device

DEVICE_INFO="${ROOT_DIR}/provisioning/logs/hotspot-diagnostic-$(date +%Y%m%d-%H%M%S).log"

{
  echo "=== Hotspot Command Diagnostics ==="
  echo "Device: $(adb shell getprop ro.product.model | tr -d '\r')"
  echo "Brand: $(adb shell getprop ro.product.manufacturer | tr -d '\r')"
  echo "Android: $(adb shell getprop ro.build.version.release | tr -d '\r')"
  echo "Timestamp: $(date)"
  echo
  
  # Check if root is available
  if ! adb shell su -v >/dev/null 2>&1; then
    echo "ERROR: Magisk/su not available. Root may not be installed."
    exit 1
  fi
  
  ROOT_CHECK="$(adb shell su -v | tr -d '\r')"
  echo "Root/Magisk: ${ROOT_CHECK}"
  echo
  
  # Test each hotspot command in order
  commands=(
    "cmd wifi start-softap"
    "cmd connectivity tether start"
    "svc wifi enable && sleep 2 && settings put global wifi_on 1"
    "am broadcast -a android.intent.action.TETHER_STATE_CHANGED --ez wifiTetherRequested true"
  )
  
  for i in "${!commands[@]}"; do
    idx=$((i + 1))
    cmd="${commands[$i]}"
    echo "Test $idx: $cmd"
    
    if adb shell su -c "$cmd" >/dev/null 2>&1; then
      echo "  Result: SUCCESS ✓"
      echo "  → This command works on this device."
    else
      echo "  Result: FAILED (command not available or returned error)"
    fi
    echo
  done
  
  # Check if hotspot is currently on
  echo "Current hotspot status:"
  if adb shell cmd connectivity tether is-tethering 2>/dev/null | grep -q "true"; then
    echo "  Hotspot: ON"
  else
    echo "  Hotspot: OFF or status unavailable"
  fi
  echo
  
  echo "=== Recommendations ==="
  echo "1. Review results above to see which command(s) work on your device."
  echo "2. Update provisioning/android/magisk-service/80-hotspot-on-boot.sh if needed."
  echo "3. Or: Install Automate APK and keep it as fallback."
  
} | tee "${DEVICE_INFO}"

echo "Diagnostic complete. Report saved to: ${DEVICE_INFO}"
