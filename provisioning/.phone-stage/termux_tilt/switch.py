from __future__ import annotations

from homeassistant.components.switch import SwitchEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import TermuxTiltEntity
from .hub import TermuxTiltHub


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    hub: TermuxTiltHub = hass.data["termux_tilt"][entry.entry_id]
    async_add_entities([TermuxTiltSamplingSwitch(hub)])


class TermuxTiltSamplingSwitch(TermuxTiltEntity, SwitchEntity):
    _attr_name = "Live sampling"
    _attr_icon = "mdi:motion-sensor"

    def __init__(self, hub: TermuxTiltHub) -> None:
        super().__init__(hub)
        self._attr_unique_id = f"{hub.entry.entry_id}_live_sampling"

    @property
    def is_on(self) -> bool:
        return self.hub.manual_sampling_enabled

    @property
    def extra_state_attributes(self):
        return self.hub.extra_state_attributes

    async def async_turn_on(self, **_kwargs) -> None:
        await self.hub.async_set_manual_sampling_enabled(True)

    async def async_turn_off(self, **_kwargs) -> None:
        await self.hub.async_set_manual_sampling_enabled(False)