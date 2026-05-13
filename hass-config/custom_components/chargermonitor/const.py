from __future__ import annotations

from homeassistant.const import Platform

DOMAIN = "chargermonitor"

PLATFORMS: list[Platform] = [
    Platform.SENSOR,
    Platform.BINARY_SENSOR,
]

CONF_SCAN_INTERVAL = "scan_interval"
DEFAULT_SCAN_INTERVAL = 60  # seconds
MIN_SCAN_INTERVAL = 10
MAX_SCAN_INTERVAL = 300

CHARGER_API_URL = "http://127.0.0.1:8765/api/charger"
CHARGER_HEALTH_URL = "http://127.0.0.1:8765/health"
