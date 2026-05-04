#!/system/bin/sh
# Magisk service.d script: try to start Wi-Fi hotspot automatically after boot.
# Tested approach for rooted devices; command availability varies by Android version/vendor ROM.

LOG_TAG="camperautomation-hotspot"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done
sleep 30

if cmd -l | grep -q '^wifi$'; then
  if cmd wifi start-softap >/dev/null 2>&1; then
    log -t "${LOG_TAG}" "Hotspot started with cmd wifi start-softap"
    exit 0
  fi
fi

if cmd -l | grep -q '^connectivity$'; then
  if cmd connectivity tether start >/dev/null 2>&1; then
    log -t "${LOG_TAG}" "Hotspot started with cmd connectivity tether start"
    exit 0
  fi
fi

log -t "${LOG_TAG}" "Hotspot autostart command failed; fallback automation app may be required"
exit 1
