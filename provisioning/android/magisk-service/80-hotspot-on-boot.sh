#!/system/bin/sh
# Magisk service.d script: start Wi-Fi hotspot (internet tethering) automatically after boot.
# Reads SSID and passphrase from the Android WifiConfigStoreSoftAp.xml so it stays in sync
# with whatever the user has configured in the system Settings.
#
# Verified working on Xiaomi Mi 11 (M2011K2G), Android 13 / MIUI, Magisk 30.7.
# cmd wifi start-softap requires: <ssid> <open|wpa2|wpa3|...> <passphrase>
# The tethering service automatically picks up the AP and enables internet forwarding.
set -eu

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
SSID="$(grep 'name="WifiSsid"' "${SOFTAP_XML}" | sed 's/.*>\(.*\)<\/string>.*/\1/' | sed 's/&quot;//g' || true)"
# Parse passphrase
PASS="$(grep 'name="Passphrase"' "${SOFTAP_XML}" | sed 's/.*>\(.*\)<\/string>.*/\1/' || true)"
# Parse security type (0=open, 1=wpa2, 2=wpa3, 3=wpa3_transition)
SECTYPE="$(grep 'name="SecurityType"' "${SOFTAP_XML}" | sed 's/.*value="\([0-9]*\)".*/\1/' || true)"

case "${SECTYPE}" in
  0) SEC="open"  ;;
  1) SEC="wpa2"  ;;
  2) SEC="wpa3"  ;;
  3) SEC="wpa3_transition" ;;
  *) SEC="wpa2"  ;;
esac

log -t "${LOG_TAG}" "Starting hotspot SSID='${SSID}' sec=${SEC}"

start_hotspot() {
  cmd wifi start-softap "${SSID}" "${SEC}" "${PASS}" >/dev/null 2>&1
}

if ! start_hotspot; then
  # One retry after stopping any stale AP
  cmd wifi stop-softap >/dev/null 2>&1 || true
  sleep 3
  if ! start_hotspot; then
    log -t "${LOG_TAG}" "Hotspot autostart failed"
    exit 1
  fi
  log -t "${LOG_TAG}" "Hotspot started on retry"
else
  log -t "${LOG_TAG}" "Hotspot started successfully"
fi

# ── Pin wlan1 to a fixed subnet so ESP static IPs stay reachable ─────────────
# Android MIUI may assign a different subnet (192.168.43.x, 192.168.1.x, …)
# on each boot. Forcing 10.129.28.1/24 on wlan1 makes the gateway address
# constant. ESP boards use static IPs in that /24 (no DHCP needed).
FIXED_AP_IP="10.129.28.1"
FIXED_AP_PREFIX="24"
AP_IFACE="wlan1"

# Wait up to 15 s for the AP interface to appear
i=0
while [ "$i" -lt 15 ]; do
  if ip link show "${AP_IFACE}" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

if ip link show "${AP_IFACE}" >/dev/null 2>&1; then
  CURRENT_IPS="$(ip -4 addr show "${AP_IFACE}" 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' ' || true)"
  # Check if our fixed IP is already one of the IPs on this interface
  if echo "${CURRENT_IPS}" | grep -qF "${FIXED_AP_IP}/"; then
    log -t "${LOG_TAG}" "AP interface already has ${FIXED_AP_IP}, no change"
  else
    log -t "${LOG_TAG}" "Adding fixed IP ${FIXED_AP_IP}/32 to ${AP_IFACE} (current: ${CURRENT_IPS})"
    # Add as a /32 host alias (NOT /24 subnet) without flushing the interface.
    # Using /32 avoids creating a competing subnet route that Android's tethering
    # daemon removes when it finalises hotspot configuration (5-10 min after boot).
    # The /32 host alias lets the phone respond to ARP for 10.129.28.1 so the ESP
    # (which uses 10.129.28.1 as its default gateway) can send replies back.
    ip addr add "${FIXED_AP_IP}/32" dev "${AP_IFACE}" 2>/dev/null && \
      log -t "${LOG_TAG}" "Fixed IP added: ${FIXED_AP_IP}/32" || \
      log -t "${LOG_TAG}" "WARNING: could not add fixed IP (check kernel/SELinux)"
  fi

  # ── Fix Android source-based routing so HA (running on loopback) can reach ESP ─
  # Android's routing rule priority 31000 sends all loopback-originated traffic via
  # wlan0 (home router), even when the destination is in the hotspot subnet.
  # Without this fix: `ip route get 10.129.28.x` returns wlan0, HA times out.
  # Fix: add a high-priority policy rule (1000) forcing 10.129.28.0/24 to lookup the
  # main table (table 254, numeric to avoid wlan1 name-resolution failures at boot).
  ESP_SUBNET="${FIXED_AP_IP%.*}.0/${FIXED_AP_PREFIX}"

  if ip rule show | grep -q "to ${ESP_SUBNET}"; then
    log -t "${LOG_TAG}" "Routing rule for ${ESP_SUBNET} already present"
  else
    # Add connected route to main table (254); may already exist as a kernel
    # connected route — that is fine (|| true swallows EEXIST).
    # Do NOT use src here: specifying src on a /32 alias causes RTNETLINK
    # "Invalid argument" on this Android build.
    ip route add "${ESP_SUBNET}" dev "${AP_IFACE}" table 254 2>/dev/null || true
    # Use numeric table ID 254 (main) — avoids wlan1 name lookup, which fails during
    # early boot before Android's NetD has registered the table name.
    if ip rule add to "${ESP_SUBNET}" table 254 priority 1000 2>/dev/null; then
      log -t "${LOG_TAG}" "Routing rule added: to ${ESP_SUBNET} via main (wlan1)"
    else
      log -t "${LOG_TAG}" "WARNING: could not add routing rule for ${ESP_SUBNET}"
    fi
  fi
else
  log -t "${LOG_TAG}" "WARNING: ${AP_IFACE} did not appear within 15 s after hotspot start"
fi

# ── Delayed re-apply after tethering daemon settles (~3-8 min after boot) ────
# Android's tethering daemon may reconfigure wlan1 after this script exits,
# removing the /32 alias and route.  Schedule a single background re-check
# at 5 min to restore them before Termux's watchdog takes over.
(
  sleep 300
  if ip link show "${AP_IFACE}" >/dev/null 2>&1; then
    if ! ip -4 addr show "${AP_IFACE}" 2>/dev/null | grep -q "${FIXED_AP_IP}/"; then
      ip addr add "${FIXED_AP_IP}/32" dev "${AP_IFACE}" 2>/dev/null && \
        log -t "${LOG_TAG}" "Delayed re-apply: added ${FIXED_AP_IP}/32 to ${AP_IFACE}" || true
      ip route add "${ESP_SUBNET}" dev "${AP_IFACE}" table 254 2>/dev/null || true
      log -t "${LOG_TAG}" "Delayed re-apply: refreshed ESP subnet routing after tethering daemon"
    else
      log -t "${LOG_TAG}" "Delayed re-apply: ${FIXED_AP_IP}/32 still present, no action needed"
    fi
  fi
) &

exit 0
