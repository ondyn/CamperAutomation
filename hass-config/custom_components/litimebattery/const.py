from __future__ import annotations

from homeassistant.const import Platform

DOMAIN = "litimebattery"

PLATFORMS: list[Platform] = [
    Platform.SENSOR,
    Platform.BINARY_SENSOR,
    Platform.SWITCH,
    Platform.BUTTON,
]

CONF_SCAN_INTERVAL = "scan_interval"
DEFAULT_SCAN_INTERVAL = 2
MIN_SCAN_INTERVAL = 2
MAX_SCAN_INTERVAL = 300

BATTERY_API_URL = "http://127.0.0.1:8766/api/battery"
BATTERY_HEALTH_URL = "http://127.0.0.1:8766/health"
BATTERY_DISCHARGE_URL = f"{BATTERY_API_URL}/discharge"
BATTERY_POWER_OFF_URL = f"{BATTERY_API_URL}/power-off"