#!/usr/bin/env bash
set -euo pipefail

# Xiaomi Mi 11 debloat script for a dedicated Home Assistant terminal.
# - Removes known MIUI/Google/Facebook/Telco bloat packages for user 0.
# - Also removes all third-party apps except an allowlist needed for this project.
#
# Usage:
#   bash provisioning/adb/06_remove_bloatware_mi11.sh
#   bash provisioning/adb/06_remove_bloatware_mi11.sh --dry-run

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help)
      cat <<'EOF'
Usage: 06_remove_bloatware_mi11.sh [--dry-run] [--help]

Options:
  --dry-run   Print planned removals without applying changes.
  --help      Show this message.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found" >&2
  exit 1
fi

adb wait-for-device

MODEL="$(adb shell getprop ro.product.model | tr -d '\r')"
MANUFACTURER="$(adb shell getprop ro.product.manufacturer | tr -d '\r')"

echo "Connected device: ${MANUFACTURER} ${MODEL}"
if [ "${MANUFACTURER}" != "Xiaomi" ]; then
  echo "WARNING: This script is tuned for Xiaomi devices; continuing anyway."
fi

TMP_LIST="$(mktemp)"
trap 'rm -f "${TMP_LIST}"' EXIT

# Explicit bloat list (seeded from user request + MI11 inventory discovery).
cat > "${TMP_LIST}" <<'EOF'
com.facebook.system
com.facebook.services
com.facebook.appmanager
com.facebook.katana
com.netflix.partner.activation
com.netflix.mediaclient
de.telekom.tsc
cz.tmobile.oneapp
com.miui.yellowpage
com.xiaomi.payment
com.xiaomi.midrop
com.google.android.feedback
com.google.android.gm
com.google.android.apps.maps
com.google.android.youtube
com.google.android.contacts
com.google.android.calendar
com.google.android.apps.subscriptions.red
com.mi.globalbrowser
com.mi.globalminusscreen
com.miui.msa.global
com.miui.analytics
com.tencent.soter.soterserver
com.miui.weather2
com.xiaomi.mipicks
com.miui.hybrid.accessory
com.miui.hybrid
com.xiaomi.glgm
com.xiaomi.joyose
com.mipay.wallet.in
com.android.providers.partnerbookmarks
com.google.android.googlequicksearchbox
com.miui.miwallpaper
com.miui.cloudbackup
com.miui.cloudservice
com.miui.cloudservice.sysbase
com.miui.micloudsync
cn.wps.xiaomi.abroad.lite
com.amazon.appmanager
com.amazon.mShop.android.shopping
com.duokan.phone.remotecontroller
com.google.android.apps.docs
com.google.android.apps.magazines
com.google.android.apps.photos
com.google.android.apps.podcasts
com.google.android.apps.tachyon
com.google.android.apps.walletnfcrel
com.google.android.apps.youtube.music
com.google.android.videos
com.google.ar.core
com.linkedin.android
com.mi.global.bbs
com.mi.global.shop
com.miui.android.fashiongallery
com.miui.mediaeditor
com.mi.healthglobal
com.android.thememanager
com.android.updater
com.miui.notes
com.miui.cleaner
com.miui.securitycenter
com.miui.player
com.miui.videoplayer
com.miui.compass
com.miui.screenrecorder
com.miui.touchassistant
com.xiaomi.scanner
com.mi.android.globalFileexplorer
EOF

# Remove all third-party packages except required apps.
KEEP_3P='^(com\.termux|com\.termux\.boot|io\.homeassistant\.companion\.android|com\.topjohnwu\.magisk)$'
adb shell pm list packages -3 | sed 's/^package://g' | tr -d '\r' | while IFS= read -r pkg; do
  [ -n "${pkg}" ] || continue
  if ! printf '%s\n' "${pkg}" | grep -Eq "${KEEP_3P}"; then
    printf '%s\n' "${pkg}" >> "${TMP_LIST}"
  fi
done

# De-duplicate and process.
sort -u "${TMP_LIST}" -o "${TMP_LIST}"

TOTAL=0
REMOVED=0
DISABLED=0
SKIPPED=0
FAILED=0

contains_pkg() {
  local pkg="$1"
  adb shell pm list packages < /dev/null | tr -d '\r' | grep -q "^package:${pkg}$"
}

remove_pkg() {
  local pkg="$1"
  TOTAL=$((TOTAL + 1))

  if ! contains_pkg "${pkg}"; then
    echo "[skip] ${pkg} (not present)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[plan] pm uninstall --user 0 ${pkg}"
    return 0
  fi

  local uninstall_out
  uninstall_out="$(adb shell pm uninstall --user 0 "${pkg}" < /dev/null 2>&1 | tr -d '\r' || true)"

  if printf '%s' "${uninstall_out}" | grep -q "Success"; then
    echo "[ok] removed ${pkg}"
    REMOVED=$((REMOVED + 1))
    return 0
  fi

  # Fallback for protected packages: disable for user 0.
  local disable_out
  disable_out="$(adb shell pm disable-user --user 0 "${pkg}" < /dev/null 2>&1 | tr -d '\r' || true)"
  if printf '%s' "${disable_out}" | grep -Eq "new state: disabled-user|already disabled|disabled"; then
    echo "[ok] disabled ${pkg}"
    DISABLED=$((DISABLED + 1))
    return 0
  fi

  echo "[fail] ${pkg}"
  echo "       uninstall: ${uninstall_out}"
  echo "       disable:   ${disable_out}"
  FAILED=$((FAILED + 1))
}

while IFS= read -r pkg; do
  [ -n "${pkg}" ] || continue
  remove_pkg "${pkg}"
done < "${TMP_LIST}"

echo
echo "Debloat summary:"
echo "  target packages: ${TOTAL}"
echo "  removed:         ${REMOVED}"
echo "  disabled:        ${DISABLED}"
echo "  skipped:         ${SKIPPED}"
echo "  failed:          ${FAILED}"

echo
echo "Note: com.android.internal.os.IDropBoxManagerService is not an uninstallable package name;"
echo "it is an Android framework service interface, so it is intentionally not processed here."

if [ "${FAILED}" -gt 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
  exit 2
fi
