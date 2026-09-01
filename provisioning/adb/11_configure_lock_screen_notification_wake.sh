#!/usr/bin/env bash
set -euo pipefail

# Xiaomi MIUI/HyperOS protects ambient-display settings from the standard ADB
# shell. Magisk can set the root-cause flag on supported builds; fall back to
# the vendor UI when its SELinux policy denies the write.

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found. Install Android platform-tools first." >&2
  exit 1
fi

adb wait-for-device

adb shell su -c 'settings put global ambient_enabled 0' >/dev/null 2>&1 || true

get_setting() {
  adb shell settings get "$1" "$2" 2>/dev/null | tr -d '\r'
}

ambient_enabled="$(get_setting global ambient_enabled)"
ambient_tilt_to_wake="$(get_setting global ambient_tilt_to_wake)"
ambient_touch_to_wake="$(get_setting global ambient_touch_to_wake)"
always_on_display="$(get_setting secure doze_always_on)"
double_tap_to_wake="$(get_setting secure double_tap_to_wake)"

echo "Lock-screen display settings:"
echo "  ambient_enabled=${ambient_enabled}"
echo "  ambient_tilt_to_wake=${ambient_tilt_to_wake}"
echo "  ambient_touch_to_wake=${ambient_touch_to_wake}"
echo "  doze_always_on=${always_on_display}"
echo "  double_tap_to_wake=${double_tap_to_wake}"

if [ "${ambient_enabled}" = "0" ] && [ "${always_on_display}" = "0" ]; then
  echo "✓ Ambient/AOD notification wake is disabled."
  exit 0
fi

echo
echo "ACTION REQUIRED: MIUI blocks this protected display policy from ADB."
echo "On the phone, open Ambient display / Always-on display and turn off"
echo "'When notifications arrive' (or disable Ambient display entirely)."
echo "Keep 'Double tap to wake' enabled if you want that wake method."

adb shell am start -a android.settings.DISPLAY_SETTINGS >/dev/null

exit 0