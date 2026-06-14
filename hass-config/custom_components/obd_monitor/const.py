from __future__ import annotations

from homeassistant.const import Platform

DOMAIN = "obd_monitor"

PLATFORMS: list[Platform] = [
    Platform.SENSOR,
    Platform.BINARY_SENSOR,
    Platform.BUTTON,
]

CONF_SCAN_INTERVAL = "scan_interval"
DEFAULT_SCAN_INTERVAL = 15   # seconds
MIN_SCAN_INTERVAL = 5
MAX_SCAN_INTERVAL = 120

# Flutter app REST endpoints (loopback – same Android device).
OBD_API_URL    = "http://127.0.0.1:8766/api/obd"
OBD_HEALTH_URL = "http://127.0.0.1:8766/health"
OBD_CMD_URL    = "http://127.0.0.1:8766/api/obd/command"
