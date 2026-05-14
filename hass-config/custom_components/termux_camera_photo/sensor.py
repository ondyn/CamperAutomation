from __future__ import annotations

from homeassistant.components.sensor import SensorEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import TermuxCameraPhotoEntity
from .hub import TermuxCameraPhotoHub


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    hub: TermuxCameraPhotoHub = hass.data["termux_camera_photo"][entry.entry_id]
    async_add_entities([TermuxCameraPhotoCountSensor(hub)])


class TermuxCameraPhotoCountSensor(TermuxCameraPhotoEntity, SensorEntity):
    _attr_name = "Photos stored"
    _attr_icon = "mdi:image-multiple"
    _attr_state_class = None

    def __init__(self, hub: TermuxCameraPhotoHub) -> None:
        super().__init__(hub)
        self._attr_unique_id = f"{hub.entry.entry_id}_photos_stored"

    @property
    def native_value(self) -> int:
        return len(self.hub.recent_photos)

    @property
    def extra_state_attributes(self):
        return self.hub.extra_state_attributes