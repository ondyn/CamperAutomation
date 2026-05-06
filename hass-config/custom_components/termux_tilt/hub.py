from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
import json
import math
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import STATE_UNAVAILABLE, STATE_UNKNOWN
from homeassistant.core import CALLBACK_TYPE, Event, HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.event import async_track_state_change_event, async_track_time_interval
from homeassistant.helpers.restore_state import RestoreEntity
from homeassistant.util import dt as dt_util

from .const import (
    ANGLE_EPSILON_DEGREES,
    CONF_ACTIVATION_ENTITY_ID,
    CONF_ACTIVATION_STATE,
    CONF_AXLE_TRACK_MM,
    CONF_UPDATE_INTERVAL_SECONDS,
    CONF_WHEELBASE_MM,
    CONF_ZERO_PITCH_DEGREES,
    CONF_ZERO_ROLL_DEGREES,
    CORNER_FRONT_LEFT,
    CORNER_FRONT_RIGHT,
    CORNER_REAR_LEFT,
    CORNER_REAR_RIGHT,
    DEFAULT_ACTIVATION_ENTITY_ID,
    DEFAULT_ACTIVATION_STATE,
    DEFAULT_AXLE_TRACK_MM,
    DEFAULT_UPDATE_INTERVAL_SECONDS,
    DEFAULT_WHEELBASE_MM,
    DOMAIN,
    LIFT_CORNERS,
    STATE_FRONT_DOWN,
    STATE_LEFT_DOWN,
    STATE_LEVEL,
    STATE_REAR_DOWN,
    STATE_RIGHT_DOWN,
)


@dataclass(slots=True)
class TiltSnapshot:
    pitch_degrees: float | None = None
    roll_degrees: float | None = None
    raw_pitch_degrees: float | None = None
    raw_roll_degrees: float | None = None
    wheel_lifts_mm: dict[str, float] = field(default_factory=dict)
    longitudinal_direction: str = STATE_LEVEL
    lateral_direction: str = STATE_LEVEL
    lowest_corner: str | None = None
    highest_corner: str | None = None
    accelerometer: dict[str, float] = field(default_factory=dict)
    gyroscope: dict[str, float] = field(default_factory=dict)
    sampled_at: datetime | None = None
    error: str | None = None


class TermuxTiltHub(RestoreEntity):
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self._listeners: list[Callable[[], None]] = []
        self._interval_unsub: CALLBACK_TYPE | None = None
        self._activation_unsub: CALLBACK_TYPE | None = None
        self._sample_lock = asyncio.Lock()
        self._snapshot = TiltSnapshot(wheel_lifts_mm={corner: 0.0 for corner in LIFT_CORNERS})
        self._manual_sampling_enabled = False
        self._activation_matched = False
        self.command_available = True
        self.device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            manufacturer="Termux",
            model="Android Tilt Meter",
            name=entry.title,
        )
        self._apply_entry_values(entry)

    @property
    def manual_sampling_enabled(self) -> bool:
        return self._manual_sampling_enabled

    @property
    def is_sampling_active(self) -> bool:
        return self._manual_sampling_enabled or self._activation_matched

    @property
    def snapshot(self) -> TiltSnapshot:
        return self._snapshot

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {
            "activation_entity_id": self.activation_entity_id,
            "activation_state": self.activation_state,
            "sampling_active": self.is_sampling_active,
            "manual_sampling_enabled": self._manual_sampling_enabled,
            "axle_track_mm": self.axle_track_mm,
            "wheelbase_mm": self.wheelbase_mm,
            "update_interval_seconds": self.update_interval_seconds,
            "zero_pitch_degrees": self.zero_pitch_degrees,
            "zero_roll_degrees": self.zero_roll_degrees,
            "last_error": self._snapshot.error,
            "sampled_at": self._snapshot.sampled_at,
        }

    async def async_setup(self) -> None:
        await self.async_reload_from_entry(self.entry)

    async def async_shutdown(self) -> None:
        self._stop_sampling_loop()
        if self._activation_unsub:
            self._activation_unsub()
            self._activation_unsub = None

    async def async_reload_from_entry(self, entry: ConfigEntry) -> None:
        self.entry = entry
        self._apply_entry_values(entry)
        await self._async_configure_activation_tracking()
        self._async_reconcile_sampling_loop(schedule_immediate_sample=False)
        self._notify_listeners()

    @callback
    def async_add_listener(self, listener: Callable[[], None]) -> CALLBACK_TYPE:
        self._listeners.append(listener)

        @callback
        def remove_listener() -> None:
            if listener in self._listeners:
                self._listeners.remove(listener)

        return remove_listener

    async def async_sample_once(self) -> None:
        async with self._sample_lock:
            try:
                payload = await self._async_run_termux_sensor()
                accelerometer = _extract_vector(payload, ("accelerometer", "acceleration"))
                gyroscope = _extract_vector(payload, ("gyroscope", "gyro"))
            except Exception as err:
                self.command_available = False
                self._snapshot.error = str(err)
                self._notify_listeners()
                return

            self.command_available = True
            self._snapshot = _build_snapshot(
                accelerometer=accelerometer,
                gyroscope=gyroscope,
                axle_track_mm=self.axle_track_mm,
                wheelbase_mm=self.wheelbase_mm,
                zero_pitch_degrees=self.zero_pitch_degrees,
                zero_roll_degrees=self.zero_roll_degrees,
            )
            self._snapshot.sampled_at = dt_util.utcnow()
            self._notify_listeners()

    async def async_set_zero(self) -> None:
        if self._snapshot.raw_pitch_degrees is None or self._snapshot.raw_roll_degrees is None:
            await self.async_sample_once()

        if self._snapshot.raw_pitch_degrees is None or self._snapshot.raw_roll_degrees is None:
            return

        await self.async_update_options(
            {
                CONF_ZERO_PITCH_DEGREES: self._snapshot.raw_pitch_degrees,
                CONF_ZERO_ROLL_DEGREES: self._snapshot.raw_roll_degrees,
            }
        )

    async def async_set_manual_sampling_enabled(self, enabled: bool) -> None:
        self._manual_sampling_enabled = enabled
        self._async_reconcile_sampling_loop(schedule_immediate_sample=enabled)
        self._notify_listeners()

    async def async_update_options(self, updates: dict[str, Any]) -> None:
        new_options = {**self.entry.options, **updates}
        self.hass.config_entries.async_update_entry(self.entry, options=new_options)
        self._apply_entry_values(self.entry)
        await self.async_reload_from_entry(self.entry)

    def _apply_entry_values(self, entry: ConfigEntry) -> None:
        options = {**entry.data, **entry.options}
        self.activation_entity_id = options.get(CONF_ACTIVATION_ENTITY_ID, DEFAULT_ACTIVATION_ENTITY_ID).strip()
        self.activation_state = options.get(CONF_ACTIVATION_STATE, DEFAULT_ACTIVATION_STATE).strip()
        self.axle_track_mm = float(options.get(CONF_AXLE_TRACK_MM, DEFAULT_AXLE_TRACK_MM))
        self.wheelbase_mm = float(options.get(CONF_WHEELBASE_MM, DEFAULT_WHEELBASE_MM))
        self.update_interval_seconds = float(
            options.get(CONF_UPDATE_INTERVAL_SECONDS, DEFAULT_UPDATE_INTERVAL_SECONDS)
        )
        self.zero_pitch_degrees = float(options.get(CONF_ZERO_PITCH_DEGREES, 0.0))
        self.zero_roll_degrees = float(options.get(CONF_ZERO_ROLL_DEGREES, 0.0))

    async def _async_configure_activation_tracking(self) -> None:
        if self._activation_unsub:
            self._activation_unsub()
            self._activation_unsub = None

        if not self.activation_entity_id:
            self._activation_matched = False
            return

        @callback
        def handle_state_change(event: Event) -> None:
            new_state = event.data.get("new_state")
            self._activation_matched = self._matches_activation_state(new_state.state if new_state else None)
            self._async_reconcile_sampling_loop(schedule_immediate_sample=self._activation_matched)
            self._notify_listeners()

        self._activation_unsub = async_track_state_change_event(
            self.hass,
            [self.activation_entity_id],
            handle_state_change,
        )
        current_state = self.hass.states.get(self.activation_entity_id)
        self._activation_matched = self._matches_activation_state(current_state.state if current_state else None)

    def _matches_activation_state(self, state_value: str | None) -> bool:
        if state_value in (None, STATE_UNKNOWN, STATE_UNAVAILABLE):
            return False

        if not self.activation_state:
            return state_value.lower() in {"on", "foreground", "active"}

        return state_value.lower() == self.activation_state.lower()

    @callback
    def _async_reconcile_sampling_loop(self, schedule_immediate_sample: bool) -> None:
        if self.is_sampling_active:
            if self._interval_unsub is None:
                self._interval_unsub = async_track_time_interval(
                    self.hass,
                    self._handle_interval_tick,
                    timedelta(seconds=max(self.update_interval_seconds, 1.0)),
                )
            if schedule_immediate_sample:
                self.hass.async_create_task(self.async_sample_once())
            return

        self._stop_sampling_loop()

    @callback
    def _handle_interval_tick(self, _now: datetime) -> None:
        self.hass.async_create_task(self.async_sample_once())

    @callback
    def _stop_sampling_loop(self) -> None:
        if self._interval_unsub is not None:
            self._interval_unsub()
            self._interval_unsub = None

    @callback
    def _notify_listeners(self) -> None:
        for listener in list(self._listeners):
            listener()

    async def _async_run_termux_sensor(self) -> dict[str, Any]:
        process = await asyncio.create_subprocess_exec(
            "termux-sensor",
            "-n",
            "1",
            "-s",
            "accelerometer,gyroscope",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=15)
        except asyncio.TimeoutError as err:
            process.kill()
            await process.communicate()
            raise RuntimeError(
                "termux-sensor timed out; verify the Termux:API Android app is installed and allowed to access sensors"
            ) from err

        if process.returncode != 0:
            raise RuntimeError(stderr.decode().strip() or "termux-sensor failed")

        payload = stdout.decode().strip()
        if not payload:
            raise RuntimeError("termux-sensor returned empty output")

        return json.loads(payload)


def _extract_vector(payload: Any, names: tuple[str, ...]) -> dict[str, float]:
    if isinstance(payload, dict):
        for key, value in payload.items():
            if any(name in key.lower() for name in names):
                axes = _coerce_axes(value)
                if axes is not None:
                    return axes

        for value in payload.values():
            axes = _extract_vector(value, names)
            if axes:
                return axes

    if isinstance(payload, list):
        for item in payload:
            axes = _extract_vector(item, names)
            if axes:
                return axes

    return {}


def _coerce_axes(value: Any) -> dict[str, float] | None:
    if isinstance(value, dict):
        if all(axis in value for axis in ("x", "y", "z")):
            return {
                "x": float(value["x"]),
                "y": float(value["y"]),
                "z": float(value["z"]),
            }

        for nested in value.values():
            axes = _coerce_axes(nested)
            if axes is not None:
                return axes

    if isinstance(value, list) and len(value) >= 3:
        try:
            return {"x": float(value[0]), "y": float(value[1]), "z": float(value[2])}
        except (TypeError, ValueError):
            return None

    return None


def _build_snapshot(
    *,
    accelerometer: dict[str, float],
    gyroscope: dict[str, float],
    axle_track_mm: float,
    wheelbase_mm: float,
    zero_pitch_degrees: float,
    zero_roll_degrees: float,
) -> TiltSnapshot:
    if not accelerometer:
        raise RuntimeError("accelerometer data was not present in termux-sensor output")

    accel_x = accelerometer["x"]
    accel_y = accelerometer["y"]
    accel_z = accelerometer["z"]

    raw_pitch = math.degrees(math.atan2(accel_y, math.sqrt((accel_x * accel_x) + (accel_z * accel_z))))
    raw_roll = math.degrees(math.atan2(accel_x, accel_z))
    pitch = raw_pitch - zero_pitch_degrees
    roll = raw_roll - zero_roll_degrees

    pitch_slope = math.tan(math.radians(pitch))
    roll_slope = math.tan(math.radians(roll))

    wheel_positions = {
        CORNER_FRONT_LEFT: (wheelbase_mm / 2.0, -axle_track_mm / 2.0),
        CORNER_FRONT_RIGHT: (wheelbase_mm / 2.0, axle_track_mm / 2.0),
        CORNER_REAR_LEFT: (-wheelbase_mm / 2.0, -axle_track_mm / 2.0),
        CORNER_REAR_RIGHT: (-wheelbase_mm / 2.0, axle_track_mm / 2.0),
    }
    corner_heights = {
        corner: (position_x * pitch_slope) + (position_y * roll_slope)
        for corner, (position_x, position_y) in wheel_positions.items()
    }
    highest_corner = max(corner_heights, key=corner_heights.get)
    lowest_corner = min(corner_heights, key=corner_heights.get)
    highest_height = corner_heights[highest_corner]
    wheel_lifts_mm = {
        corner: round(max(0.0, highest_height - height), 1)
        for corner, height in corner_heights.items()
    }

    return TiltSnapshot(
        pitch_degrees=round(pitch, 2),
        roll_degrees=round(roll, 2),
        raw_pitch_degrees=round(raw_pitch, 2),
        raw_roll_degrees=round(raw_roll, 2),
        wheel_lifts_mm=wheel_lifts_mm,
        longitudinal_direction=_direction_for_pitch(pitch),
        lateral_direction=_direction_for_roll(roll),
        lowest_corner=lowest_corner,
        highest_corner=highest_corner,
        accelerometer=accelerometer,
        gyroscope=gyroscope,
        error=None,
    )


def _direction_for_pitch(pitch: float) -> str:
    if abs(pitch) <= ANGLE_EPSILON_DEGREES:
        return STATE_LEVEL
    return STATE_FRONT_DOWN if pitch > 0 else STATE_REAR_DOWN


def _direction_for_roll(roll: float) -> str:
    if abs(roll) <= ANGLE_EPSILON_DEGREES:
        return STATE_LEVEL
    return STATE_RIGHT_DOWN if roll > 0 else STATE_LEFT_DOWN