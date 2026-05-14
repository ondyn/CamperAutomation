from __future__ import annotations

from homeassistant.components.button import ButtonEntity
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
    async_add_entities([TermuxCameraTakePhotoButton(hub)])


class TermuxCameraTakePhotoButton(TermuxCameraPhotoEntity, ButtonEntity):
    _attr_name = "Take picture"
    _attr_icon = "mdi:camera"

    def __init__(self, hub: TermuxCameraPhotoHub) -> None:
        super().__init__(hub)
        self._attr_unique_id = f"{hub.entry.entry_id}_take_picture"

    async def async_press(self) -> None:
        await self.hub.async_capture_photo()