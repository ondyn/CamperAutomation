from __future__ import annotations

from dataclasses import dataclass

from homeassistant.components.number import NumberEntity, NumberEntityDescription
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import UnitOfLength, UnitOfTime
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import (
    CONF_AXLE_TRACK_MM,
    CONF_UPDATE_INTERVAL_SECONDS,
    CONF_WHEELBASE_MM,
)
from .entity import TermuxTiltEntity
from .hub import TermuxTiltHub


@dataclass(frozen=True, kw_only=True)
class TermuxTiltNumberDescription(NumberEntityDescription):
    option_key: str
    getter: str


NUMBERS: tuple[TermuxTiltNumberDescription, ...] = (
    TermuxTiltNumberDescription(
        key="axle_track",
        name="Axle track",
        icon="mdi:arrow-left-right",
        native_min_value=1000,
        native_max_value=3000,
        native_step=10,
        native_unit_of_measurement=UnitOfLength.MILLIMETERS,
        option_key=CONF_AXLE_TRACK_MM,
        getter="axle_track_mm",
    ),
    TermuxTiltNumberDescription(
        key="wheelbase",
        name="Wheelbase",
        icon="mdi:car-estate",
        native_min_value=1500,
        native_max_value=8000,
        native_step=10,
        native_unit_of_measurement=UnitOfLength.MILLIMETERS,
        option_key=CONF_WHEELBASE_MM,
        getter="wheelbase_mm",
    ),
    TermuxTiltNumberDescription(
        key="update_interval",
        name="Update interval",
        icon="mdi:timer-cog",
        native_min_value=1,
        native_max_value=60,
        native_step=1,
        native_unit_of_measurement=UnitOfTime.SECONDS,
        option_key=CONF_UPDATE_INTERVAL_SECONDS,
        getter="update_interval_seconds",
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    hub: TermuxTiltHub = hass.data["termux_tilt"][entry.entry_id]
    async_add_entities(TermuxTiltNumber(hub, description) for description in NUMBERS)


class TermuxTiltNumber(TermuxTiltEntity, NumberEntity):
    entity_description: TermuxTiltNumberDescription

    def __init__(self, hub: TermuxTiltHub, description: TermuxTiltNumberDescription) -> None:
        super().__init__(hub)
        self.entity_description = description
        self._attr_unique_id = f"{hub.entry.entry_id}_{description.key}"

    @property
    def native_value(self) -> float:
        return float(getattr(self.hub, self.entity_description.getter))

    async def async_set_native_value(self, value: float) -> None:
        await self.hub.async_update_options({self.entity_description.option_key: float(value)})