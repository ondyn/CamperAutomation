#!/system/bin/sh
# Magisk service.d script: start Wi-Fi hotspot (internet tethering) automatically after boot.
# Reads SSID and passphrase from the Android WifiConfigStoreSoftAp.xml so it stays in sync
# with whatever the user has configured in the system Settings.
#
# Verified working on Xiaomi Mi 11 (M2011K2G), Android 13 / MIUI, Magisk 30.7.
# cmd wifi start-softap requires: <ssid> <open|wpa2|wpa3|...> <passphrase>
# The tethering service automatically picks up the AP and enables internet forwarding.

LOG_TAG="camperautomation-hotspot"
SOFTAP_XML="/data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done
sleep 15

if [ ! -f "${SOFTAP_XML}" ]; then
  log -t "${LOG_TAG}" "SoftAP config not found: ${SOFTAP_XML}"
  exit 1
fi

# Parse SSID: stored as &quot;Mi 11&quot; in XML, strip &quot; entities to get plain name
SSID=$(grep 'name="WifiSsid"' "${SOFTAP_XML}" | sed 's/.*>\(.*\)<\/string>.*/\1/' | sed 's/&quot;//g')
# Parse passphrase
PASS=$(grep 'name="Passphrase"' "${SOFTAP_XML}" | sed 's/.*>\(.*\)<\/string>.*/\1/')
# Parse security type (0=open, 1=wpa2, 2=wpa3, 3=wpa3_transition)
SECTYPE=$(grep 'name="SecurityType"' "${SOFTAP_XML}" | sed 's/.*value="\([0-9]*\)".*/\1/')

case "${SECTYPE}" in
  0) SEC="open"  ;;
  1) SEC="wpa2"  ;;
  2) SEC="wpa3"  ;;
  3) SEC="wpa3_transition" ;;
  *) SEC="wpa2"  ;;
esac

log -t "${LOG_TAG}" "Starting hotspot SSID='${SSID}' sec=${SEC}"

if cmd wifi start-softap "${SSID}" "${SEC}" "${PASS}" >/dev/null 2>&1; then
  log -t "${LOG_TAG}" "Hotspot started successfully"
  exit 0
fi

# One retry after stopping any stale AP
cmd wifi stop-softap >/dev/null 2>&1 || true
sleep 3
if cmd wifi start-softap "${SSID}" "${SEC}" "${PASS}" >/dev/null 2>&1; then
  log -t "${LOG_TAG}" "Hotspot started on retry"
  exit 0
fi

log -t "${LOG_TAG}" "Hotspot autostart failed"
exit 1
