from __future__ import annotations

import voluptuous as vol

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
import homeassistant.helpers.config_validation as cv

from .const import ATTR_CAMERA_ID, ATTR_ENTRY_ID, DOMAIN, PLATFORMS, SERVICE_CAPTURE_PHOTO
from .hub import TermuxCameraPhotoHub


async def async_setup(hass: HomeAssistant, _config: dict) -> bool:
    hass.data.setdefault(DOMAIN, {})
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    hub = TermuxCameraPhotoHub(hass, entry)
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = hub
    await hub.async_setup()
    entry.async_on_unload(entry.add_update_listener(_async_update_entry))
    _async_register_services(hass)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    hass.data[DOMAIN].pop(entry.entry_id)
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def _async_update_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    hub: TermuxCameraPhotoHub = hass.data[DOMAIN][entry.entry_id]
    await hub.async_reload_from_entry(entry)


def _async_register_services(hass: HomeAssistant) -> None:
    if hass.services.has_service(DOMAIN, SERVICE_CAPTURE_PHOTO):
        return

    service_schema = vol.Schema(
        {
            vol.Optional(ATTR_ENTRY_ID): cv.string,
            vol.Optional(ATTR_CAMERA_ID): vol.Coerce(int),
        }
    )

    async def handle_capture_photo(call) -> None:
        entry_id = call.data.get(ATTR_ENTRY_ID)
        camera_id = call.data.get(ATTR_CAMERA_ID)
        for hub in _iter_target_hubs(hass, entry_id):
            await hub.async_capture_photo(camera_id=camera_id)

    hass.services.async_register(DOMAIN, SERVICE_CAPTURE_PHOTO, handle_capture_photo, schema=service_schema)


def _iter_target_hubs(hass: HomeAssistant, entry_id: str | None) -> list[TermuxCameraPhotoHub]:
    hubs: dict[str, TermuxCameraPhotoHub] = hass.data.get(DOMAIN, {})
    if entry_id:
        hub = hubs.get(entry_id)
        return [hub] if hub else []
    return list(hubs.values())