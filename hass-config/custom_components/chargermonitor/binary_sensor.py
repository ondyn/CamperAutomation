from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
    BinarySensorEntityDescription,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import ChargerDataCoordinator


def _flag(d: dict, key: str) -> bool | None:
    """Return a flag value from coordinator data['flags'], or None if disconnected."""
    flags = d.get("flags")
    if flags is None:
        return None
    return flags.get(key)


@dataclass(frozen=True, kw_only=True)
class ChargerBinarySensorDescription(BinarySensorEntityDescription):
    value_fn: Callable[[dict], bool | None] = lambda _: None


BINARY_SENSORS: tuple[ChargerBinarySensorDescription, ...] = (
    ChargerBinarySensorDescription(
        key="charge_state",
        name="Charging",
        icon="mdi:battery-charging",
        device_class=BinarySensorDeviceClass.BATTERY_CHARGING,
        value_fn=lambda d: _flag(d, "charge_state"),
    ),
    ChargerBinarySensorDescription(
        key="assistant_charge_state",
        name="Assistant Charging",
        icon="mdi:battery-charging-outline",
        value_fn=lambda d: _flag(d, "assistant_charge_state"),
    ),
    ChargerBinarySensorDescription(
        key="full_charge",
        name="Battery Full",
        icon="mdi:battery-check",
        value_fn=lambda d: _flag(d, "full_charge"),
    ),
    ChargerBinarySensorDescription(
        key="over_temp",
        name="Over Temperature",
        icon="mdi:thermometer-alert",
        device_class=BinarySensorDeviceClass.HEAT,
        value_fn=lambda d: _flag(d, "over_temp"),
    ),
    ChargerBinarySensorDescription(
        key="battery_over_pressure",
        name="Battery Over-Voltage",
        icon="mdi:battery-alert",
        device_class=BinarySensorDeviceClass.PROBLEM,
        value_fn=lambda d: _flag(d, "battery_over_pressure"),
    ),
    ChargerBinarySensorDescription(
        key="pv_over_pressure",
        name="PV Over-Voltage",
        icon="mdi:solar-panel-large",
        device_class=BinarySensorDeviceClass.PROBLEM,
        value_fn=lambda d: _flag(d, "pv_over_pressure"),
    ),
    ChargerBinarySensorDescription(
        key="battery_under_voltage",
        name="Battery Under-Voltage",
        icon="mdi:battery-alert-variant",
        device_class=BinarySensorDeviceClass.PROBLEM,
        value_fn=lambda d: _flag(d, "battery_under_voltage"),
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
        ChargerBinarySensorEntity(coordinator, description)
        for description in BINARY_SENSORS
    )


class ChargerBinarySensorEntity(
    CoordinatorEntity[ChargerDataCoordinator], BinarySensorEntity
):
    _attr_has_entity_name = True
    _attr_device_info = _DEVICE_INFO

    def __init__(
        self,
        coordinator: ChargerDataCoordinator,
        description: ChargerBinarySensorDescription,
    ) -> None:
        super().__init__(coordinator)
        self.entity_description = description
        self._attr_unique_id = f"chargermonitor_{description.key}"

    @property
    def is_on(self) -> bool | None:
        if self.coordinator.data is None:
            return None
        return self.entity_description.value_fn(self.coordinator.data)

    @property
    def available(self) -> bool:
        return (
            self.coordinator.last_update_success
            and self.coordinator.data is not None
        )
