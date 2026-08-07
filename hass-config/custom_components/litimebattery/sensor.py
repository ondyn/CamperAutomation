from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
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
    PERCENTAGE,
    UnitOfElectricCurrent,
    UnitOfElectricPotential,
    UnitOfPower,
    UnitOfTemperature,
    UnitOfTime,
)
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import LiTimeBatteryDataCoordinator


def _data(payload: dict[str, Any], key: str) -> Any:
    data = payload.get("data")
    return data.get(key) if isinstance(data, dict) else None


@dataclass(frozen=True, kw_only=True)
class LiTimeSensorDescription(SensorEntityDescription):
    value_fn: Callable[[dict[str, Any]], Any] = lambda _: None


SENSORS: tuple[LiTimeSensorDescription, ...] = (
    LiTimeSensorDescription(
        key="battery_voltage",
        name="Battery Voltage",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=3,
        value_fn=lambda data: _data(data, "battery_voltage_v"),
    ),
    LiTimeSensorDescription(
        key="output_voltage",
        name="Output Voltage",
        native_unit_of_measurement=UnitOfElectricPotential.VOLT,
        device_class=SensorDeviceClass.VOLTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=3,
        value_fn=lambda data: _data(data, "output_voltage_v"),
    ),
    LiTimeSensorDescription(
        key="current",
        name="Current",
        native_unit_of_measurement=UnitOfElectricCurrent.AMPERE,
        device_class=SensorDeviceClass.CURRENT,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=2,
        value_fn=lambda data: _data(data, "current_a"),
    ),
    LiTimeSensorDescription(
        key="power",
        name="Power",
        native_unit_of_measurement=UnitOfPower.WATT,
        device_class=SensorDeviceClass.POWER,
        state_class=SensorStateClass.MEASUREMENT,
        suggested_display_precision=1,
        value_fn=lambda data: _data(data, "power_w"),
    ),
    LiTimeSensorDescription(
        key="state_of_charge",
        name="State of Charge",
        native_unit_of_measurement=PERCENTAGE,
        device_class=SensorDeviceClass.BATTERY,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda data: _data(data, "soc_percent"),
    ),
    LiTimeSensorDescription(
        key="state_of_health",
        name="State of Health",
        native_unit_of_measurement=PERCENTAGE,
        state_class=SensorStateClass.MEASUREMENT,
        value_fn=lambda data: _data(data, "soh_percent"),
    ),
    LiTimeSensorDescription(
        key="operating_state",
        name="Operating State",
        icon="mdi:battery-sync",
        value_fn=lambda data: _data(data, "operating_state")
        if data.get("connection") == "connected"
        else "offline",
    ),
    *(
        LiTimeSensorDescription(
            key=key,
            name=name,
            native_unit_of_measurement=UnitOfTime.HOURS,
            device_class=SensorDeviceClass.DURATION,
            state_class=SensorStateClass.MEASUREMENT,
            suggested_display_precision=2,
            value_fn=lambda data, field=field: _data(data, field)
            if data.get("connection") == "connected"
            else None,
        )
        for key, name, field in (
            ("time_to_full", "Time to Full", "estimated_hours_to_full"),
            ("time_to_empty", "Time to Empty", "estimated_hours_to_empty"),
        )
    ),
    *(
        LiTimeSensorDescription(
            key=key,
            name=name,
            native_unit_of_measurement="Ah",
            state_class=SensorStateClass.MEASUREMENT,
            suggested_display_precision=2,
            value_fn=lambda data, field=field: _data(data, field),
        )
        for key, name, field in (
            ("remaining_capacity", "Remaining Capacity", "remaining_capacity_ah"),
            ("full_charge_capacity", "Full Charge Capacity", "full_charge_capacity_ah"),
            ("rated_capacity", "Rated Capacity", "rated_capacity_ah"),
        )
    ),
    *(
        LiTimeSensorDescription(
            key=key,
            name=name,
            native_unit_of_measurement=UnitOfElectricPotential.VOLT,
            device_class=SensorDeviceClass.VOLTAGE,
            state_class=SensorStateClass.MEASUREMENT,
            suggested_display_precision=3,
            value_fn=lambda data, field=field: _data(data, field),
        )
        for key, name, field in (
            ("minimum_cell_voltage", "Minimum Cell Voltage", "minimum_cell_voltage_v"),
            ("maximum_cell_voltage", "Maximum Cell Voltage", "maximum_cell_voltage_v"),
            ("cell_voltage_delta", "Cell Voltage Delta", "cell_voltage_delta_v"),
        )
    ),
    LiTimeSensorDescription(
        key="balancing_cells",
        name="Balancing Cells",
        icon="mdi:scale-balance",
        value_fn=lambda data: ", ".join(
            str(cell) for cell in (_data(data, "balancing_cells") or [])
        )
        or "None",
    ),
    *(
        LiTimeSensorDescription(
            key=key,
            name=name,
            icon=icon,
            entity_category=EntityCategory.DIAGNOSTIC,
            value_fn=lambda data, field=field: _data(data, field),
        )
        for key, name, field, icon in (
            ("cell_count", "Cell Count", "cell_count", "mdi:battery-multiple"),
            (
                "temperature_sensor_count",
                "Temperature Sensor Count",
                "temperature_sensor_count",
                "mdi:thermometer-lines",
            ),
        )
    ),
    LiTimeSensorDescription(
        key="remaining_capacity_raw",
        name="Remaining Capacity Raw",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: _data(data, "remaining_capacity_raw"),
    ),
    LiTimeSensorDescription(
        key="full_charge_capacity_raw",
        name="Full Charge Capacity Raw",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: _data(data, "full_charge_capacity_raw"),
    ),
    LiTimeSensorDescription(
        key="rated_capacity_raw",
        name="Rated Capacity Raw",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: _data(data, "rated_capacity_raw"),
    ),
    LiTimeSensorDescription(
        key="discharge_cycles",
        name="Discharge Cycles",
        icon="mdi:counter",
        state_class=SensorStateClass.TOTAL_INCREASING,
        value_fn=lambda data: _data(data, "discharge_cycles"),
    ),
    LiTimeSensorDescription(
        key="total_discharge_capacity_raw",
        name="Total Discharge Capacity Raw",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: _data(data, "total_discharge_capacity_raw"),
    ),
    *(
        LiTimeSensorDescription(
            key=key,
            name=name,
            icon="mdi:code-braces",
            entity_category=EntityCategory.DIAGNOSTIC,
            value_fn=lambda data, field=field: _data(data, field),
        )
        for key, name, field in (
            ("alarm_status_raw", "Alarm Status Raw", "alarm_status"),
            ("protection_status_raw", "Protection Status Raw", "protection_status"),
            ("fault_status_raw", "Fault Status Raw", "fault_status"),
            ("balance_status_raw", "Balance Status Raw", "balance_status"),
            ("battery_status_raw", "Battery Status Raw", "battery_status"),
            ("other_information_raw", "Other Information Raw", "other_information"),
        )
    ),
    LiTimeSensorDescription(
        key="connection_status",
        name="Connection Status",
        icon="mdi:bluetooth-connect",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: data.get("connection"),
    ),
    LiTimeSensorDescription(
        key="device_name",
        name="Device Name",
        icon="mdi:identifier",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: data.get("device_name"),
    ),
    LiTimeSensorDescription(
        key="last_update",
        name="Last Update",
        device_class=SensorDeviceClass.TIMESTAMP,
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: datetime.fromtimestamp(
            data["last_update_ms"] / 1000, tz=UTC
        )
        if data.get("last_update_ms") is not None
        else None,
    ),
)

_DEVICE_INFO = DeviceInfo(
    identifiers={(DOMAIN, "litimebattery")},
    name="LiTime Battery",
    manufacturer="LiTime",
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: LiTimeBatteryDataCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities(
        LiTimeSensorEntity(coordinator, description) for description in SENSORS
    )

    known_cells: set[int] = set()
    known_temperatures: set[int] = set()

    @callback
    def add_array_entities() -> None:
        data = coordinator.data.get("data") if coordinator.data else None
        if not isinstance(data, dict):
            return

        entities: list[SensorEntity] = []
        cells = data.get("cell_voltages_v")
        if isinstance(cells, list):
            for index in range(len(cells)):
                if index not in known_cells:
                    known_cells.add(index)
                    entities.append(LiTimeCellVoltageSensor(coordinator, index))

        temperatures = data.get("temperatures_c")
        if isinstance(temperatures, list):
            for index in range(len(temperatures)):
                if index not in known_temperatures:
                    known_temperatures.add(index)
                    entities.append(LiTimeTemperatureSensor(coordinator, index))

        if entities:
            async_add_entities(entities)

    add_array_entities()
    entry.async_on_unload(coordinator.async_add_listener(add_array_entities))


class LiTimeSensorEntity(
    CoordinatorEntity[LiTimeBatteryDataCoordinator], SensorEntity
):
    _attr_has_entity_name = True
    _attr_device_info = _DEVICE_INFO

    def __init__(
        self,
        coordinator: LiTimeBatteryDataCoordinator,
        description: LiTimeSensorDescription,
    ) -> None:
        super().__init__(coordinator)
        self.entity_description = description
        self._attr_unique_id = f"litimebattery_{description.key}"

    @property
    def native_value(self) -> Any:
        return self.entity_description.value_fn(self.coordinator.data)


class LiTimeArraySensor(
    CoordinatorEntity[LiTimeBatteryDataCoordinator], SensorEntity
):
    _attr_has_entity_name = True
    _attr_device_info = _DEVICE_INFO
    _field: str

    def __init__(
        self, coordinator: LiTimeBatteryDataCoordinator, index: int
    ) -> None:
        super().__init__(coordinator)
        self._index = index

    @property
    def native_value(self) -> float | None:
        values = _data(self.coordinator.data, self._field)
        if not isinstance(values, list) or self._index >= len(values):
            return None
        value = values[self._index]
        return float(value) if isinstance(value, int | float) else None


class LiTimeCellVoltageSensor(LiTimeArraySensor):
    _field = "cell_voltages_v"
    _attr_device_class = SensorDeviceClass.VOLTAGE
    _attr_native_unit_of_measurement = UnitOfElectricPotential.VOLT
    _attr_state_class = SensorStateClass.MEASUREMENT
    _attr_suggested_display_precision = 3
    _attr_icon = "mdi:battery-heart-variant"

    def __init__(
        self, coordinator: LiTimeBatteryDataCoordinator, index: int
    ) -> None:
        super().__init__(coordinator, index)
        self._attr_name = f"Cell {index + 1} Voltage"
        self._attr_unique_id = f"litimebattery_cell_{index + 1}_voltage"


class LiTimeTemperatureSensor(LiTimeArraySensor):
    _field = "temperatures_c"
    _attr_device_class = SensorDeviceClass.TEMPERATURE
    _attr_native_unit_of_measurement = UnitOfTemperature.CELSIUS
    _attr_state_class = SensorStateClass.MEASUREMENT
    _attr_suggested_display_precision = 1

    def __init__(
        self, coordinator: LiTimeBatteryDataCoordinator, index: int
    ) -> None:
        super().__init__(coordinator, index)
        self._attr_name = f"Temperature {index + 1}"
        self._attr_unique_id = f"litimebattery_temperature_{index + 1}"