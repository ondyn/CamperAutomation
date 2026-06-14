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
from .coordinator import OBDDataCoordinator

# ── Helpers ───────────────────────────────────────────────────────────────

def _data_flag(d: dict, key: str) -> bool | None:
    data_block = d.get("data")
    if data_block is None:
        return None
    return data_block.get(key)


# ── Entity description ────────────────────────────────────────────────────

@dataclass(frozen=True, kw_only=True)
class OBDBinarySensorDescription(BinarySensorEntityDescription):
    value_fn: Callable[[dict], bool | None] = lambda _: None


# ── Binary sensor definitions ─────────────────────────────────────────────

BINARY_SENSORS: tuple[OBDBinarySensorDescription, ...] = (
    OBDBinarySensorDescription(
        key="obd_connected",
        name="OBD Connected",
        icon="mdi:bluetooth-connect",
        device_class=BinarySensorDeviceClass.CONNECTIVITY,
        value_fn=lambda d: d.get("connection") == "connected",
    ),
    OBDBinarySensorDescription(
        key="mil",
        name="Check Engine Light",
        icon="mdi:engine-outline",
        device_class=BinarySensorDeviceClass.PROBLEM,
        value_fn=lambda d: _data_flag(d, "mil_on"),
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
        OBDBinarySensor(coordinator, entry, desc) for desc in BINARY_SENSORS
    )


# ── Entity class ──────────────────────────────────────────────────────────

class OBDBinarySensor(CoordinatorEntity[OBDDataCoordinator], BinarySensorEntity):
    """A single OBD-derived binary sensor."""

    entity_description: OBDBinarySensorDescription
    _attr_has_entity_name = True

    def __init__(
        self,
        coordinator: OBDDataCoordinator,
        entry: ConfigEntry,
        description: OBDBinarySensorDescription,
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
    def is_on(self) -> bool | None:
        return self.entity_description.value_fn(self.coordinator.data)
