from __future__ import annotations

from homeassistant.const import Platform

DOMAIN = "litimebattery"

PLATFORMS: list[Platform] = [
    Platform.SENSOR,
    Platform.BINARY_SENSOR,
]

CONF_SCAN_INTERVAL = "scan_interval"
DEFAULT_SCAN_INTERVAL = 10
MIN_SCAN_INTERVAL = 2
MAX_SCAN_INTERVAL = 300

BATTERY_API_URL = "http://127.0.0.1:8766/api/battery"
BATTERY_HEALTH_URL = "http://127.0.0.1:8766/health"