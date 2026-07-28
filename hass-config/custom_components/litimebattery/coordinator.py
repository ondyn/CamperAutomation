from __future__ import annotations

import asyncio
import logging
from datetime import timedelta
from typing import Any

from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import (
    BATTERY_API_URL,
    BATTERY_DISCHARGE_URL,
    BATTERY_POWER_OFF_URL,
    DOMAIN,
)

_LOGGER = logging.getLogger(__name__)


class LiTimeBatteryDataCoordinator(DataUpdateCoordinator[dict[str, Any]]):
    """Fetch LiTime battery state from the Flutter REST endpoint."""

    def __init__(self, hass: HomeAssistant, scan_interval_seconds: int) -> None:
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=scan_interval_seconds),
        )
        self._session = async_get_clientsession(hass)

    async def _async_update_data(self) -> dict[str, Any]:
        try:
            async with asyncio.timeout(5):
                response = await self._session.get(BATTERY_API_URL)
                response.raise_for_status()
                payload = await response.json()
                if not isinstance(payload, dict):
                    raise ValueError("Battery API response is not an object")
                return payload
        except Exception as err:
            raise UpdateFailed(f"LiTime Battery API error: {err}") from err

    async def async_set_discharge_enabled(self, enabled: bool) -> None:
        """Set the battery discharge MOS state."""
        await self._async_post(BATTERY_DISCHARGE_URL, {"enabled": enabled})
        await self.async_request_refresh()

    async def async_power_off(self) -> None:
        """Power off the battery."""
        await self._async_post(BATTERY_POWER_OFF_URL, {"confirm": True})

    async def _async_post(self, url: str, payload: dict[str, Any]) -> None:
        try:
            async with asyncio.timeout(5):
                response = await self._session.post(url, json=payload)
                response.raise_for_status()
        except Exception as err:
            raise UpdateFailed(f"LiTime Battery control error: {err}") from err