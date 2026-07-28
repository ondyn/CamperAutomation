from __future__ import annotations

from typing import Any

from homeassistant.components.switch import SwitchEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.update_coordinator import CoordinatorEntity

from .const import DOMAIN
from .coordinator import LiTimeBatteryDataCoordinator

_DEVICE_INFO = DeviceInfo(
    identifiers={(DOMAIN, "litimebattery")},
    name="LiTime Battery",
    manufacturer="LiTime",
)


def _discharge_enabled(payload: dict[str, Any]) -> bool | None:
    data = payload.get("data")
    value = data.get("discharge_enabled") if isinstance(data, dict) else None
    return value if isinstance(value, bool) else None


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: LiTimeBatteryDataCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([LiTimeDischargeSwitch(coordinator)])


class LiTimeDischargeSwitch(
    CoordinatorEntity[LiTimeBatteryDataCoordinator], SwitchEntity
):
    _attr_has_entity_name = True
    _attr_name = "Discharge Switch"
    _attr_unique_id = "litimebattery_discharge_switch"
    _attr_icon = "mdi:car-battery"
    _attr_device_info = _DEVICE_INFO

    @property
    def is_on(self) -> bool | None:
        return _discharge_enabled(self.coordinator.data)

    @property
    def available(self) -> bool:
        return super().available and self.coordinator.data.get("connection") == "connected"

    async def async_turn_on(self, **kwargs: Any) -> None:
        await self.coordinator.async_set_discharge_enabled(True)

    async def async_turn_off(self, **kwargs: Any) -> None:
        await self.coordinator.async_set_discharge_enabled(False)