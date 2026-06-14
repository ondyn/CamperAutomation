from __future__ import annotations

import asyncio
import logging

from homeassistant.components.button import ButtonEntity, ButtonEntityDescription
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import DOMAIN, OBD_CMD_URL

_LOGGER = logging.getLogger(__name__)

# ── Platform setup ────────────────────────────────────────────────────────

async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    async_add_entities([ClearDTCsButton(hass, entry)])


# ── Button entity ─────────────────────────────────────────────────────────

class ClearDTCsButton(ButtonEntity):
    """Button that sends a 'clear_dtcs' command to the Flutter app."""

    _attr_has_entity_name = True

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self._hass = hass
        self._entry = entry
        self._attr_unique_id = f"{entry.entry_id}_clear_dtcs"
        self._attr_name = "Clear DTCs"
        self._attr_icon = "mdi:delete-sweep"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name="OBD Monitor",
            manufacturer="ELM327",
            model="Fiat Ducato 290",
        )

    async def async_press(self) -> None:
        """Send clear_dtcs command to the Flutter REST server."""
        session = async_get_clientsession(self._hass)
        try:
            async with asyncio.timeout(5):
                resp = await session.post(
                    OBD_CMD_URL,
                    json={"command": "clear_dtcs"},
                )
                resp.raise_for_status()
                _LOGGER.info("OBD DTCs cleared successfully")
        except Exception as err:
            _LOGGER.error("Failed to clear DTCs: %s", err)
