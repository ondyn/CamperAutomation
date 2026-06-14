from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .const import DOMAIN, OBD_API_URL

_LOGGER = logging.getLogger(__name__)


class OBDDataCoordinator(DataUpdateCoordinator[dict]):
    """Coordinator that fetches OBD state from the obdmonitor Flutter REST endpoint."""

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
                resp = await self._session.get(OBD_API_URL)
                resp.raise_for_status()
                return await resp.json()
        except Exception as err:
            raise UpdateFailed(f"OBD API error: {err}") from err
