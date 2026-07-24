from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from homeassistant.components.binary_sensor import (
    BinarySensorDeviceClass,
    BinarySensorEntity,
    BinarySensorEntityDescription,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EntityCategory
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import LiTimeBatteryDataCoordinator


def _data(payload: dict[str, Any], key: str) -> Any:
    data = payload.get("data")
    return data.get(key) if isinstance(data, dict) else None


@dataclass(frozen=True, kw_only=True)
class LiTimeBinarySensorDescription(BinarySensorEntityDescription):
    value_fn: Callable[[dict[str, Any]], bool | None] = lambda _: None


BINARY_SENSORS: tuple[LiTimeBinarySensorDescription, ...] = (
    LiTimeBinarySensorDescription(
        key="connected",
        name="Connected",
        device_class=BinarySensorDeviceClass.CONNECTIVITY,
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: data.get("connection") == "connected",
    ),
    LiTimeBinarySensorDescription(
        key="extended_layout",
        name="Extended Telemetry Layout",
        icon="mdi:format-list-numbered",
        entity_category=EntityCategory.DIAGNOSTIC,
        value_fn=lambda data: _data(data, "extended_layout"),
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
        LiTimeBinarySensorEntity(coordinator, description)
        for description in BINARY_SENSORS
    )


class LiTimeBinarySensorEntity(
    CoordinatorEntity[LiTimeBatteryDataCoordinator], BinarySensorEntity
):
    _attr_has_entity_name = True
    _attr_device_info = _DEVICE_INFO

    def __init__(
        self,
        coordinator: LiTimeBatteryDataCoordinator,
        description: LiTimeBinarySensorDescription,
    ) -> None:
        super().__init__(coordinator)
        self.entity_description = description
        self._attr_unique_id = f"litimebattery_{description.key}"

    @property
    def is_on(self) -> bool | None:
        return self.entity_description.value_fn(self.coordinator.data)