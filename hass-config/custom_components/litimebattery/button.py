from __future__ import annotations

from homeassistant.components.button import ButtonEntity
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


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    coordinator: LiTimeBatteryDataCoordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([LiTimePowerOffButton(coordinator)])


class LiTimePowerOffButton(
    CoordinatorEntity[LiTimeBatteryDataCoordinator], ButtonEntity
):
    _attr_has_entity_name = True
    _attr_name = "Power Off"
    _attr_unique_id = "litimebattery_power_off"
    _attr_icon = "mdi:power"
    _attr_device_info = _DEVICE_INFO

    @property
    def available(self) -> bool:
        return super().available and self.coordinator.data.get("connection") == "connected"

    async def async_press(self) -> None:
        await self.coordinator.async_power_off()