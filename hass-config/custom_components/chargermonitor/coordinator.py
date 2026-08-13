from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import CHARGER_API_URL, DOMAIN

_LOGGER = logging.getLogger(__name__)

_ALARM_FLAG_KEYS = (
    "over_temp",
    "battery_over_pressure",
    "pv_over_pressure",
    "battery_under_voltage",
)


def _normalize_alarm_flags(data: dict) -> dict:
    """Convert legacy healthy-state flags to true-on-alarm values."""
    if data.get("alarm_flags_active_high") is True:
        return data

    flags = data.get("flags")
    if not isinstance(flags, dict):
        return data

    normalized_flags = dict(flags)
    for key in _ALARM_FLAG_KEYS:
        value = normalized_flags.get(key)
        if isinstance(value, bool):
            normalized_flags[key] = not value

    normalized = dict(data)
    normalized["flags"] = normalized_flags
    normalized["alarm_flags_active_high"] = True
    return normalized


class ChargerDataCoordinator(DataUpdateCoordinator[dict]):
    """Coordinator that fetches charger state from the Flutter REST endpoint."""

    def __init__(self, hass: HomeAssistant, scan_interval_seconds: int) -> None:
        super().__init__(
            hass,
            _LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=scan_interval_seconds),
        )
        self._session = async_get_clientsession(hass)

    async def _async_update_data(self) -> dict:
        try:
            async with asyncio.timeout(5):
                resp = await self._session.get(CHARGER_API_URL)
                resp.raise_for_status()
                return _normalize_alarm_flags(await resp.json())
        except Exception as err:
            raise UpdateFailed(f"Charger API error: {err}") from err
