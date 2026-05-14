from __future__ import annotations

from homeassistant.components.camera import Camera
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
    async_add_entities([TermuxCameraLatestPhoto(hub)])


class TermuxCameraLatestPhoto(TermuxCameraPhotoEntity, Camera):
    _attr_name = "Latest picture"

    def __init__(self, hub: TermuxCameraPhotoHub) -> None:
        Camera.__init__(self)
        super().__init__(hub)
        self._attr_unique_id = f"{hub.entry.entry_id}_latest_picture"

    async def async_camera_image(self, width: int | None = None, height: int | None = None) -> bytes | None:
        del width, height
        return await self.hub.async_get_latest_image_bytes()

    @property
    def extra_state_attributes(self):
        return self.hub.extra_state_attributes