from __future__ import annotations

from dataclasses import dataclass

from homeassistant.components.sensor import SensorEntity, SensorEntityDescription, SensorStateClass
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import DEGREE, EntityCategory, UnitOfLength
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import (
    CORNER_FRONT_LEFT,
    CORNER_FRONT_RIGHT,
    CORNER_REAR_LEFT,
    CORNER_REAR_RIGHT,
)
from .entity import TermuxTiltEntity
from .hub import TermuxTiltHub


@dataclass(frozen=True, kw_only=True)
class TermuxTiltSensorDescription(SensorEntityDescription):
    value_key: str


SENSORS: tuple[TermuxTiltSensorDescription, ...] = (
    TermuxTiltSensorDescription(
        key="pitch",
        name="Pitch",
        icon="mdi:angle-acute",
        native_unit_of_measurement=DEGREE,
        state_class=SensorStateClass.MEASUREMENT,
        value_key="pitch_degrees",
    ),
    TermuxTiltSensorDescription(
        key="roll",
        name="Roll",
        icon="mdi:angle-right",
        native_unit_of_measurement=DEGREE,
        state_class=SensorStateClass.MEASUREMENT,
        value_key="roll_degrees",
    ),
    TermuxTiltSensorDescription(
        key="front_left_lift",
        name="Front left lift",
        icon="mdi:arrow-up-bold-box-outline",
        native_unit_of_measurement=UnitOfLength.MILLIMETERS,
        state_class=SensorStateClass.MEASUREMENT,
        value_key=CORNER_FRONT_LEFT,
    ),
    TermuxTiltSensorDescription(
        key="front_right_lift",
        name="Front right lift",
        icon="mdi:arrow-up-bold-box-outline",
        native_unit_of_measurement=UnitOfLength.MILLIMETERS,
        state_class=SensorStateClass.MEASUREMENT,
        value_key=CORNER_FRONT_RIGHT,
    ),
    TermuxTiltSensorDescription(
        key="rear_left_lift",
        name="Rear left lift",
        icon="mdi:arrow-up-bold-box-outline",
        native_unit_of_measurement=UnitOfLength.MILLIMETERS,
        state_class=SensorStateClass.MEASUREMENT,
        value_key=CORNER_REAR_LEFT,
    ),
    TermuxTiltSensorDescription(
        key="rear_right_lift",
        name="Rear right lift",
        icon="mdi:arrow-up-bold-box-outline",
        native_unit_of_measurement=UnitOfLength.MILLIMETERS,
        state_class=SensorStateClass.MEASUREMENT,
        value_key=CORNER_REAR_RIGHT,
    ),
    TermuxTiltSensorDescription(
        key="longitudinal_direction",
        name="Longitudinal direction",
        icon="mdi:arrow-up-down",
        value_key="longitudinal_direction",
    ),
    TermuxTiltSensorDescription(
        key="lateral_direction",
        name="Lateral direction",
        icon="mdi:arrow-left-right",
        value_key="lateral_direction",
    ),
    TermuxTiltSensorDescription(
        key="highest_corner",
        name="Highest corner",
        icon="mdi:car-lifted-pickup",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_key="highest_corner",
    ),
    TermuxTiltSensorDescription(
        key="lowest_corner",
        name="Lowest corner",
        icon="mdi:car-side",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_key="lowest_corner",
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    hub: TermuxTiltHub = hass.data["termux_tilt"][entry.entry_id]
    async_add_entities(TermuxTiltSensor(hub, description) for description in SENSORS)


class TermuxTiltSensor(TermuxTiltEntity, SensorEntity):
    entity_description: TermuxTiltSensorDescription

    def __init__(self, hub: TermuxTiltHub, description: TermuxTiltSensorDescription) -> None:
        super().__init__(hub)
        self.entity_description = description
        self._attr_unique_id = f"{hub.entry.entry_id}_{description.key}"

    @property
    def native_value(self):
        snapshot = self.hub.snapshot
        if self.entity_description.value_key in snapshot.wheel_lifts_mm:
            return snapshot.wheel_lifts_mm[self.entity_description.value_key]
        return getattr(snapshot, self.entity_description.value_key)

    @property
    def extra_state_attributes(self):
        return {
            **self.hub.extra_state_attributes,
            "accelerometer": self.hub.snapshot.accelerometer,
            "gyroscope": self.hub.snapshot.gyroscope,
            "raw_pitch_degrees": self.hub.snapshot.raw_pitch_degrees,
            "raw_roll_degrees": self.hub.snapshot.raw_roll_degrees,
        }