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
    EntityCategory,
    UnitOfElectricCurrent,
    UnitOfElectricPotential,
    UnitOfEnergy,
    UnitOfPower,
)
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import ChargerDataCoordinator


def _data(d: dict, key: str) -> Any:
    """Return value from coordinator data['data'], or None if disconnected."""
    data_block = d.get("data")
    if data_block is None:
        return None
    return data_block.get(key)


@dataclass(frozen=True, kw_only=True)
class ChargerSensorDescription(SensorEntityDescription):
    value_fn: Callable[[dict], Any] = lambda _: None


SENSORS: tuple[ChargerSensorDescription, ...] = (
    # --- Battery ---
    ChargerSensorDescription(
        key="battery_voltage",
        name="Battery Voltage",
        icon="mdi:battery",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=2,
        value_fn=lambda d: _data(d, "battery_voltage_v"),
    ),
    ChargerSensorDescription(
        key="battery_current",
        name="Battery Current",
        icon="mdi:current-dc",
        native_unit_of_measurement=UnitOfElectricCurrent.AMPERE,
        device_class=SensorDeviceClass.CURRENT,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "battery_current_a"),
    ),
    # --- Assistant battery ---
    ChargerSensorDescription(
        key="assistant_battery_voltage",
        name="Assistant Battery Voltage",
        icon="mdi:battery-outline",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=2,
        value_fn=lambda d: _data(d, "assistant_battery_voltage_v"),
    ),
    ChargerSensorDescription(
        key="assistant_battery_current",
        name="Assistant Battery Current",
        icon="mdi:current-dc",
        native_unit_of_measurement=UnitOfElectricCurrent.AMPERE,
        device_class=SensorDeviceClass.CURRENT,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "assistant_battery_current_a"),
    ),
    # --- Solar panel ---
    ChargerSensorDescription(
        key="solar_panel_voltage",
        name="Solar Panel Voltage",
        icon="mdi:solar-panel",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "solar_panel_voltage_v"),
    ),
    ChargerSensorDescription(
        key="solar_panel_power",
        name="Solar Panel Power",
        icon="mdi:solar-power",
        native_unit_of_measurement=UnitOfPower.WATT,
        device_class=SensorDeviceClass.POWER,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: _data(d, "solar_panel_power_w"),
    ),
    # --- Load ---
    ChargerSensorDescription(
        key="load_voltage",
        name="Load Voltage",
        icon="mdi:lightning-bolt",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "load_voltage_v"),
    ),
    ChargerSensorDescription(
        key="load_current",
        name="Load Current",
        icon="mdi:current-dc",
        native_unit_of_measurement=UnitOfElectricCurrent.AMPERE,
        device_class=SensorDeviceClass.CURRENT,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "load_current_a"),
    ),
    ChargerSensorDescription(
        key="load_power",
        name="Load Power",
        icon="mdi:power-plug",
        native_unit_of_measurement=UnitOfPower.WATT,
        device_class=SensorDeviceClass.POWER,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda d: _data(d, "load_power_w"),
    ),
    # --- Starting battery ---
    ChargerSensorDescription(
        key="starting_battery_voltage",
        name="Starting Battery Voltage",
        icon="mdi:car-battery",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda d: _data(d, "starting_battery_voltage_v"),
    ),
    # --- Energy counters ---
    ChargerSensorDescription(
        key="charge_capacity",
        name="Charge Capacity",
        icon="mdi:battery-charging",
        native_unit_of_measurement="Ah",
        state_class=SensorStateClass.TOTAL_INCREASING,
        suggested_display_precision=0,
        value_fn=lambda d: _data(d, "charge_capacity_ah"),
    ),
    ChargerSensorDescription(
        key="charge_energy",
        name="Charge Energy",
        icon="mdi:battery-charging",
        native_unit_of_measurement=UnitOfEnergy.WATT_HOUR,
        device_class=SensorDeviceClass.ENERGY,
        state_class=SensorStateClass.TOTAL_INCREASING,
        suggested_display_precision=0,
        value_fn=lambda d: _data(d, "charge_energy_wh"),
    ),
    ChargerSensorDescription(
        key="assistant_charge_capacity",
        name="Assistant Charge Capacity",
        icon="mdi:battery-charging-outline",
        native_unit_of_measurement="Ah",
        state_class=SensorStateClass.TOTAL_INCREASING,
        suggested_display_precision=0,
        value_fn=lambda d: _data(d, "assistant_charge_capacity_ah"),
    ),
    ChargerSensorDescription(
        key="assistant_charge_energy",
        name="Assistant Charge Energy",
        icon="mdi:battery-charging-outline",
        native_unit_of_measurement=UnitOfEnergy.WATT_HOUR,
        device_class=SensorDeviceClass.ENERGY,
        state_class=SensorStateClass.TOTAL_INCREASING,
        suggested_display_precision=0,
        value_fn=lambda d: _data(d, "assistant_charge_energy_wh"),
    ),
    # --- Diagnostics ---
    ChargerSensorDescription(
        key="connection_status",
        name="Connection Status",
        icon="mdi:bluetooth-connect",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda d: d.get("connection"),
    ),
    ChargerSensorDescription(
        key="device_type",
        name="Device Type",
        icon="mdi:chip",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda d: d.get("device_type"),
    ),
)

_DEVICE_INFO = DeviceInfo(
    identifiers={(DOMAIN, "chargermonitor")},
    name="Charger Monitor",
    manufacturer="Solar Charger",
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: ChargerDataCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        ChargerSensorEntity(coordinator, description) for description in SENSORS
    )


class ChargerSensorEntity(CoordinatorEntity[ChargerDataCoordinator], SensorEntity):
    _attr_has_entity_name = True
    _attr_device_info = _DEVICE_INFO

    def __init__(
        self,
        coordinator: ChargerDataCoordinator,
        description: ChargerSensorDescription,
    ) -> None:
        super().__init__(coordinator)
        self.entity_description = description
        self._attr_unique_id = f"chargermonitor_{description.key}"

    @property
    def native_value(self) -> Any:
        if self.coordinator.data is None:
            return None
        return self.entity_description.value_fn(self.coordinator.data)

    @property
    def available(self) -> bool:
        return (
            self.coordinator.last_update_success
            and self.coordinator.data is not None
        )
