"""Android/Termux stub for the Home Assistant bluetooth integration.

The built-in bluetooth integration calls bluetooth_adapters which attempts
to open a DBus system bus (BusType.SYSTEM). On Android/Termux there is no
system DBus, causing a TypeError in Python 3.13 that prevents the domain
from being marked as set-up and blocks ESPHome (which has bluetooth as a
hard dependency in its manifest).

This stub makes the bluetooth domain register as successfully set up without
touching DBus or importing bluetooth_adapters at all.

On HA 2026.x, ESPHome's on_connect callback calls bluetooth.async_remove_scanner()
(and potentially other BT API functions) on every device connection, even for
non-BT devices, to clean up stale scanner registrations.  Without a
BluetoothManager registered in habluetooth.central_manager this raises:
  RuntimeError: BluetoothManager has not been set
…which crashes the ESPHome connection task and keeps devices stuck as unavailable.

Fix: register a duck-typed no-op stub manager directly with
habluetooth.central_manager.set_manager() — this avoids importing the full
homeassistant.components.bluetooth module (which triggers USB/inotify imports
causing blocking-call warnings on Android/Termux).
"""
from __future__ import annotations

import logging

from homeassistant.core import HomeAssistant

_LOGGER = logging.getLogger(__name__)


class _NoOpBluetoothManager:
    """Duck-typed stub that satisfies habluetooth.central_manager.get_manager().

    Implements the methods ESPHome (and other HA integrations) call on
    connect/disconnect when no real Bluetooth hardware is available.
    Any un-listed attribute access returns a no-op callable so future
    HA versions that call additional BT API methods don't crash either.
    """

    # ESPHome manager.py calls this on every connect to deregister stale scanners.
    def async_remove_scanner(self, source: str) -> None:  # noqa: D102
        pass

    # ESPHome BT proxy calls this when advertising BT capability.
    def async_register_scanner(self, *args, **kwargs):  # noqa: D102
        return None

    # Catch-all: any other method → silent no-op.
    def __getattr__(self, name: str):  # noqa: D105
        return lambda *a, **kw: None


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    """Register a no-op BluetoothManager — DBus/Bluetooth unavailable on Android/Termux."""
    try:
        from habluetooth.central_manager import set_manager

        set_manager(_NoOpBluetoothManager())  # type: ignore[arg-type]
        _LOGGER.debug("bluetooth stub: registered no-op BluetoothManager via habluetooth")
    except Exception as exc:  # noqa: BLE001 — best-effort, never block HA startup
        _LOGGER.warning("bluetooth stub: failed to register stub manager: %s", exc)

    return True
