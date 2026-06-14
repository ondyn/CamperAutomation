from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.sensor import (
    SensorDeviceClass,
    SensorEntity,
    SensorEntityDescription,
    SensorStateClass,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import (
    UnitOfSpeed,
    UnitOfTemperature,
    UnitOfTime,
)
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import OBDDataCoordinator

# ── Helpers ───────────────────────────────────────────────────────────────

def _data(d: dict, key: str) -> Any:
    """Return value from coordinator data['data'], or None if not connected."""
    data_block = d.get("data")
    if data_block is None:
        return None
    return data_block.get(key)


# ── Entity description ────────────────────────────────────────────────────

@dataclass(frozen=True, kw_only=True)
class OBDSensorDescription(SensorEntityDescription):
    value_fn: Callable[[dict], Any] = lambda _: None


# ── Sensor definitions ────────────────────────────────────────────────────

SENSORS: tuple[OBDSensorDescription, ...] = (
    OBDSensorDescription(
        key="engine_rpm",
        name="Engine RPM",
        icon="mdi:engine",
        native_unit_of_measurement="rpm",
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=0,
        value_fn=lambda d: _data(d, "engine_rpm"),
    ),
    OBDSensorDescription(
        key="vehicle_speed",
        name="Vehicle Speed",
        icon="mdi:speedometer",
        native_unit_of_measurement=UnitOfSpeed.KILOMETERS_PER_HOUR,
        device_class=SensorDeviceClass.SPEED,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=0,
        value_fn=lambda d: _data(d, "vehicle_speed_kmh"),
    ),
    OBDSensorDescription(
        key="coolant_temp",
        name="Coolant Temperature",
        icon="mdi:thermometer-water",
        native_unit_of_measurement=UnitOfTemperature.CELSIUS,
        device_class=SensorDeviceClass.TEMPERATURE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "coolant_temp_c"),
    ),
    OBDSensorDescription(
        key="oil_temp",
        name="Oil Temperature",
        icon="mdi:oil-temperature",
        native_unit_of_measurement=UnitOfTemperature.CELSIUS,
        device_class=SensorDeviceClass.TEMPERATURE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "oil_temp_c"),
    ),
    OBDSensorDescription(
        key="intake_air_temp",
        name="Intake Air Temperature",
        icon="mdi:thermometer",
        native_unit_of_measurement=UnitOfTemperature.CELSIUS,
        device_class=SensorDeviceClass.TEMPERATURE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "intake_air_temp_c"),
    ),
    OBDSensorDescription(
        key="fuel_level",
        name="Fuel Level",
        icon="mdi:fuel",
        native_unit_of_measurement="%",
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "fuel_level_pct"),
    ),
    OBDSensorDescription(
        key="throttle_pos",
        name="Throttle Position",
        icon="mdi:car-turbocharger",
        native_unit_of_measurement="%",
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "throttle_pos_pct"),
    ),
    OBDSensorDescription(
        key="maf_g_s",
        name="MAF Air Flow",
        icon="mdi:air-filter",
        native_unit_of_measurement="g/s",
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=2,
        value_fn=lambda d: _data(d, "maf_g_s"),
    ),
    OBDSensorDescription(
        key="run_time",
        name="Engine Run Time",
        icon="mdi:timer-outline",
        native_unit_of_measurement=UnitOfTime.SECONDS,
        device_class=SensorDeviceClass.DURATION,
        state_class=SensorStateClass.TOTAL_INCREASING,
        value_fn=lambda d: _data(d, "run_time_s"),
    ),
    OBDSensorDescription(
        key="dtc_count",
        name="DTC Count",
        icon="mdi:alert-circle-outline",
        native_unit_of_measurement=None,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: _data(d, "dtc_count"),
    ),
    OBDSensorDescription(
        key="dtcs",
        name="Active DTCs",
        icon="mdi:car-wrench",
        native_unit_of_measurement=None,
        value_fn=lambda d: ", ".join(_data(d, "dtcs") or []) or "none",
    ),
)

# ── Platform setup ────────────────────────────────────────────────────────

async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: OBDDataCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        OBDSensor(coordinator, entry, desc) for desc in SENSORS
    )


# ── Entity class ──────────────────────────────────────────────────────────

class OBDSensor(CoordinatorEntity[OBDDataCoordinator], SensorEntity):
    """A single OBD-II numeric sensor."""

    entity_description: OBDSensorDescription
    _attr_has_entity_name = True

    def __init__(
        self,
        coordinator: OBDDataCoordinator,
        entry: ConfigEntry,
        description: OBDSensorDescription,
    ) -> None:
        super().__init__(coordinator)
        self.entity_description = description
        self._attr_unique_id = f"{entry.entry_id}_{description.key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name="OBD Monitor",
            manufacturer="ELM327",
            model="Fiat Ducato 290",
        )

    @property
    def native_value(self):
        return self.entity_description.value_fn(self.coordinator.data)
