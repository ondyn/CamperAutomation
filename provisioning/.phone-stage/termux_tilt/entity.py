from __future__ import annotations

from homeassistant.helpers.entity import Entity

from .hub import TermuxTiltHub


class TermuxTiltEntity(Entity):
    _attr_has_entity_name = True

    def __init__(self, hub: TermuxTiltHub) -> None:
        self.hub = hub

    @property
    def device_info(self):
        return self.hub.device_info

    @property
    def available(self) -> bool:
        return self.hub.command_available

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(self.hub.async_add_listener(self.async_write_ha_state))