from __future__ import annotations

import voluptuous as vol

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
import homeassistant.helpers.config_validation as cv

from .const import (
    ATTR_ENTRY_ID,
    DOMAIN,
    PLATFORMS,
    SERVICE_CANCEL_CALIBRATION,
    SERVICE_CAPTURE_CALIBRATION_STEP,
    SERVICE_START_CALIBRATION,
    SERVICE_SAMPLE_ONCE,
    SERVICE_SET_ZERO,
    SERVICE_START_SAMPLING,
    SERVICE_STOP_SAMPLING,
)
from .hub import TermuxTiltHub


async def async_setup(hass: HomeAssistant, _config: dict) -> bool:
    hass.data.setdefault(DOMAIN, {})
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    hub = TermuxTiltHub(hass, entry)
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = hub
    await hub.async_setup()
    entry.async_on_unload(entry.add_update_listener(_async_update_entry))
    _async_register_services(hass)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    hub: TermuxTiltHub = hass.data[DOMAIN].pop(entry.entry_id)
    await hub.async_shutdown()
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)


async def _async_update_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    hub: TermuxTiltHub = hass.data[DOMAIN][entry.entry_id]
    await hub.async_reload_from_entry(entry)


def _async_register_services(hass: HomeAssistant) -> None:
    if hass.services.has_service(DOMAIN, SERVICE_SAMPLE_ONCE):
        return

    service_schema = vol.Schema({vol.Optional(ATTR_ENTRY_ID): cv.string})
    start_calibration_schema = vol.Schema(
        {
            vol.Optional(ATTR_ENTRY_ID): cv.string,
            vol.Optional("target_lift_mm"): vol.Coerce(float),
        }
    )

    async def handle_sample_once(call) -> None:
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_sample_once()

    async def handle_set_zero(call) -> None:
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_set_zero()

    async def handle_start_sampling(call) -> None:
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_set_manual_sampling_enabled(True)

    async def handle_stop_sampling(call) -> None:
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_set_manual_sampling_enabled(False)

    async def handle_start_calibration(call) -> None:
        target_lift_mm = call.data.get("target_lift_mm")
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_start_calibration(target_lift_mm=target_lift_mm)

    async def handle_capture_calibration_step(call) -> None:
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_capture_calibration_step()

    async def handle_cancel_calibration(call) -> None:
        for hub in _iter_target_hubs(hass, call.data.get(ATTR_ENTRY_ID)):
            await hub.async_cancel_calibration()

    hass.services.async_register(DOMAIN, SERVICE_SAMPLE_ONCE, handle_sample_once, schema=service_schema)
    hass.services.async_register(DOMAIN, SERVICE_SET_ZERO, handle_set_zero, schema=service_schema)
    hass.services.async_register(DOMAIN, SERVICE_START_SAMPLING, handle_start_sampling, schema=service_schema)
    hass.services.async_register(DOMAIN, SERVICE_STOP_SAMPLING, handle_stop_sampling, schema=service_schema)
    hass.services.async_register(
        DOMAIN,
        SERVICE_START_CALIBRATION,
        handle_start_calibration,
        schema=start_calibration_schema,
    )
    hass.services.async_register(
        DOMAIN,
        SERVICE_CAPTURE_CALIBRATION_STEP,
        handle_capture_calibration_step,
        schema=service_schema,
    )
    hass.services.async_register(DOMAIN, SERVICE_CANCEL_CALIBRATION, handle_cancel_calibration, schema=service_schema)


def _iter_target_hubs(hass: HomeAssistant, entry_id: str | None) -> list[TermuxTiltHub]:
    hubs: dict[str, TermuxTiltHub] = hass.data.get(DOMAIN, {})
    if entry_id:
        hub = hubs.get(entry_id)
        return [hub] if hub else []
    return list(hubs.values())