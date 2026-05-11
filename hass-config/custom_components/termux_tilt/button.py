from __future__ import annotations

from dataclasses import dataclass

from homeassistant.components.button import ButtonEntity, ButtonEntityDescription
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .entity import TermuxTiltEntity
from .hub import TermuxTiltHub


@dataclass(frozen=True, kw_only=True)
class TermuxTiltButtonDescription(ButtonEntityDescription):
    press_method: str


BUTTONS: tuple[TermuxTiltButtonDescription, ...] = (
    TermuxTiltButtonDescription(
        key="sample_once",
        name="Sample once",
        icon="mdi:radar",
        press_method="async_sample_once",
    ),
    TermuxTiltButtonDescription(
        key="set_zero",
        name="Set zero",
        icon="mdi:car-brake-alert",
        press_method="async_set_zero",
    ),
    TermuxTiltButtonDescription(
        key="reset_zero",
        name="Reset zero",
        icon="mdi:restore",
        press_method="async_reset_zero",
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    hub: TermuxTiltHub = hass.data["termux_tilt"][entry.entry_id]
    async_add_entities(TermuxTiltButton(hub, description) for description in BUTTONS)


class TermuxTiltButton(TermuxTiltEntity, ButtonEntity):
    entity_description: TermuxTiltButtonDescription

    def __init__(self, hub: TermuxTiltHub, description: TermuxTiltButtonDescription) -> None:
        super().__init__(hub)
        self.entity_description = description
        self._attr_unique_id = f"{hub.entry.entry_id}_{description.key}"

    async def async_press(self) -> None:
        await getattr(self.hub, self.entity_description.press_method)()