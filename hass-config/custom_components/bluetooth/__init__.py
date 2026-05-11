"""Android/Termux stub for the Home Assistant bluetooth integration.

The built-in bluetooth integration calls bluetooth_adapters which attempts
to open a DBus system bus (BusType.SYSTEM). On Android/Termux there is no
system DBus, causing a TypeError in Python 3.13 that prevents the domain
from being marked as set-up and blocks ESPHome (which has bluetooth as a
hard dependency in its manifest).

This stub makes the bluetooth domain register as successfully set up without
touching DBus or importing bluetooth_adapters at all. The HA bluetooth API
functions in homeassistant.components.bluetooth are still importable (from
the built-in module on PYTHONPATH) and will gracefully return empty/zero
values when no adapters are registered.
"""
from __future__ import annotations

from homeassistant.core import HomeAssistant


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    """No-op setup — DBus/Bluetooth unavailable on Android/Termux."""
    return True
