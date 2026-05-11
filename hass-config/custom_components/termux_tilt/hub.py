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
from homeassistant.helpers.event import (
    async_call_later,
    async_track_state_change_event,
    async_track_time_interval,
)
from homeassistant.helpers.restore_state import RestoreEntity
from homeassistant.util import dt as dt_util

from .const import (
    ANGLE_EPSILON_DEGREES,
    CALIBRATION_LEVEL_STEP,
    CALIBRATION_SEQUENCE,
    CONF_ACTIVATION_ENTITY_ID,
    CONF_ACTIVATION_STATE,
    CONF_AXLE_TRACK_MM,
    CONF_CALIBRATION_COEFFICIENTS,
    CONF_CALIBRATION_LEVEL_VECTOR,
    CONF_CALIBRATION_TARGET_LIFT_MM,
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
    DEFAULT_CALIBRATION_TARGET_LIFT_MM,
    DEFAULT_UPDATE_INTERVAL_SECONDS,
    DEFAULT_WHEELBASE_MM,
    DOMAIN,
    LIFT_CORNERS,
    MANUAL_SAMPLING_TIMEOUT_SECONDS,
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
        self._manual_timeout_unsub: CALLBACK_TYPE | None = None
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

        self._calibration_active = False
        self._calibration_step_index = 0
        self._calibration_samples: dict[str, tuple[float, float, float]] = {}
        self._calibration_last_error: str | None = None
        self._calibration_completed_at: datetime | None = None

        self.activation_entity_id = ""
        self.activation_state = ""
        self.axle_track_mm = DEFAULT_AXLE_TRACK_MM
        self.wheelbase_mm = DEFAULT_WHEELBASE_MM
        self.update_interval_seconds = DEFAULT_UPDATE_INTERVAL_SECONDS
        self.zero_pitch_degrees = 0.0
        self.zero_roll_degrees = 0.0
        self.calibration_target_lift_mm = DEFAULT_CALIBRATION_TARGET_LIFT_MM
        self.calibration_level_vector: tuple[float, float, float] | None = None
        self.calibration_coefficients: dict[str, tuple[float, float]] = {}

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
            "manual_sampling_timeout_seconds": MANUAL_SAMPLING_TIMEOUT_SECONDS,
            "calibration_active": self._calibration_active,
            "calibration_has_model": self._has_calibration_model,
            "calibration_step": self._current_calibration_step_key(),
            "calibration_step_index": self._calibration_step_index,
            "calibration_total_steps": len(self._calibration_steps()),
            "calibration_instruction": self._calibration_instruction(),
            "calibration_progress": self._calibration_progress(),
            "calibration_target_lift_mm": self.calibration_target_lift_mm,
            "calibration_last_error": self._calibration_last_error,
            "calibration_completed_at": self._calibration_completed_at,
        }

    async def async_setup(self) -> None:
        await self.async_reload_from_entry(self.entry)

    async def async_shutdown(self) -> None:
        self._stop_sampling_loop()
        self._cancel_manual_sampling_timeout()
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
            except (RuntimeError, ValueError, TypeError, KeyError, json.JSONDecodeError) as err:
                self.command_available = False
                self._snapshot.error = str(err)
                self._notify_listeners()
                return

            self.command_available = True
            raw_pitch, raw_roll = _legacy_angles(accelerometer)
            if self._has_calibration_model:
                self._snapshot = _build_snapshot_calibrated(
                    accelerometer=accelerometer,
                    gyroscope=gyroscope,
                    axle_track_mm=self.axle_track_mm,
                    wheelbase_mm=self.wheelbase_mm,
                    calibration_level_vector=self.calibration_level_vector,
                    calibration_coefficients=self.calibration_coefficients,
                    raw_pitch=raw_pitch,
                    raw_roll=raw_roll,
                )
            else:
                self._snapshot = _build_snapshot_legacy(
                    accelerometer=accelerometer,
                    gyroscope=gyroscope,
                    axle_track_mm=self.axle_track_mm,
                    wheelbase_mm=self.wheelbase_mm,
                    zero_pitch_degrees=self.zero_pitch_degrees,
                    zero_roll_degrees=self.zero_roll_degrees,
                    raw_pitch=raw_pitch,
                    raw_roll=raw_roll,
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
        if enabled:
            self._schedule_manual_sampling_timeout()
        else:
            self._cancel_manual_sampling_timeout()
        self._async_reconcile_sampling_loop(schedule_immediate_sample=enabled)
        self._notify_listeners()

    async def async_start_calibration(self, target_lift_mm: float | None = None) -> None:
        if target_lift_mm is not None and target_lift_mm > 0:
            self.calibration_target_lift_mm = float(target_lift_mm)
        self._calibration_active = True
        self._calibration_step_index = 0
        self._calibration_samples = {}
        self._calibration_last_error = None
        self._notify_listeners()

    async def async_capture_calibration_step(self) -> None:
        if not self._calibration_active:
            raise RuntimeError("Calibration is not active. Start calibration first.")

        await self.async_sample_once()
        if not self._snapshot.accelerometer:
            raise RuntimeError("No accelerometer sample available.")

        normalized = _normalize_vector(self._snapshot.accelerometer)
        current_step = self._current_calibration_step_key()
        if current_step is None:
            raise RuntimeError("Calibration step is not available.")

        self._calibration_samples[current_step] = normalized
        self._calibration_step_index += 1

        if self._calibration_step_index >= len(self._calibration_steps()):
            try:
                level_vector, coefficients = _build_calibration_model(
                    samples=self._calibration_samples,
                    target_lift_mm=self.calibration_target_lift_mm,
                )
            except Exception as err:
                self._calibration_last_error = str(err)
                self._calibration_active = False
                self._notify_listeners()
                raise

            self._calibration_active = False
            self._calibration_completed_at = dt_util.utcnow()
            await self.async_update_options(
                {
                    CONF_CALIBRATION_LEVEL_VECTOR: [round(v, 8) for v in level_vector],
                    CONF_CALIBRATION_COEFFICIENTS: {
                        corner: [round(coefficients[corner][0], 8), round(coefficients[corner][1], 8)]
                        for corner in LIFT_CORNERS
                    },
                    CONF_CALIBRATION_TARGET_LIFT_MM: self.calibration_target_lift_mm,
                }
            )
            self._notify_listeners()
            return

        self._notify_listeners()

    async def async_cancel_calibration(self) -> None:
        self._calibration_active = False
        self._calibration_step_index = 0
        self._calibration_samples = {}
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
        self.axle_track_mm = int(round(float(options.get(CONF_AXLE_TRACK_MM, DEFAULT_AXLE_TRACK_MM))))
        self.wheelbase_mm = int(round(float(options.get(CONF_WHEELBASE_MM, DEFAULT_WHEELBASE_MM))))
        self.update_interval_seconds = int(
            round(float(options.get(CONF_UPDATE_INTERVAL_SECONDS, DEFAULT_UPDATE_INTERVAL_SECONDS)))
        )
        self.zero_pitch_degrees = float(options.get(CONF_ZERO_PITCH_DEGREES, 0.0))
        self.zero_roll_degrees = float(options.get(CONF_ZERO_ROLL_DEGREES, 0.0))
        self.calibration_target_lift_mm = float(
            options.get(CONF_CALIBRATION_TARGET_LIFT_MM, DEFAULT_CALIBRATION_TARGET_LIFT_MM)
        )
        self.calibration_level_vector = _coerce_vector(options.get(CONF_CALIBRATION_LEVEL_VECTOR))
        self.calibration_coefficients = _coerce_coefficients(options.get(CONF_CALIBRATION_COEFFICIENTS))

    @property
    def _has_calibration_model(self) -> bool:
        if self.calibration_level_vector is None:
            return False
        return all(corner in self.calibration_coefficients for corner in LIFT_CORNERS)

    def _calibration_steps(self) -> list[str]:
        return [CALIBRATION_LEVEL_STEP, *CALIBRATION_SEQUENCE]

    def _current_calibration_step_key(self) -> str | None:
        if not self._calibration_active:
            return None
        steps = self._calibration_steps()
        if self._calibration_step_index >= len(steps):
            return None
        return steps[self._calibration_step_index]

    def _calibration_progress(self) -> float:
        total = len(self._calibration_steps())
        if total <= 0:
            return 0.0
        return round(min(1.0, max(0.0, self._calibration_step_index / total)), 3)

    def _calibration_instruction(self) -> str:
        if not self._calibration_active:
            if self._has_calibration_model:
                return "Calibration saved. Start calibration to replace it."
            return "Calibration not started."

        step = self._current_calibration_step_key()
        if step == CALIBRATION_LEVEL_STEP:
            return "Place the van on level ground and press Capture step."

        wheel_label = step.replace("_", " ") if step else "wheel"
        target_cm = round(self.calibration_target_lift_mm / 10.0, 1)
        return f"Lift {wheel_label} by {target_cm} cm, then press Capture step."

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
    def _schedule_manual_sampling_timeout(self) -> None:
        self._cancel_manual_sampling_timeout()
        self._manual_timeout_unsub = async_call_later(
            self.hass,
            MANUAL_SAMPLING_TIMEOUT_SECONDS,
            self._handle_manual_sampling_timeout,
        )

    @callback
    def _cancel_manual_sampling_timeout(self) -> None:
        if self._manual_timeout_unsub is not None:
            self._manual_timeout_unsub()
            self._manual_timeout_unsub = None

    @callback
    def _handle_manual_sampling_timeout(self, _now: datetime) -> None:
        if not self._manual_sampling_enabled:
            return
        self._manual_sampling_enabled = False
        self._manual_timeout_unsub = None
        self._async_reconcile_sampling_loop(schedule_immediate_sample=False)
        self._notify_listeners()

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


def _coerce_vector(value: Any) -> tuple[float, float, float] | None:
    if not isinstance(value, (list, tuple)) or len(value) != 3:
        return None
    try:
        vector = (float(value[0]), float(value[1]), float(value[2]))
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(item) for item in vector):
        return None
    return _normalize_tuple(vector)


def _coerce_coefficients(value: Any) -> dict[str, tuple[float, float]]:
    if not isinstance(value, dict):
        return {}

    coeffs: dict[str, tuple[float, float]] = {}
    for corner in LIFT_CORNERS:
        item = value.get(corner)
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            continue
        try:
            a = float(item[0])
            b = float(item[1])
        except (TypeError, ValueError):
            continue
        if not math.isfinite(a) or not math.isfinite(b):
            continue
        coeffs[corner] = (a, b)

    return coeffs


def _legacy_angles(accelerometer: dict[str, float]) -> tuple[float, float]:
    if not accelerometer:
        raise RuntimeError("accelerometer data was not present in termux-sensor output")

    accel_x = accelerometer["x"]
    accel_y = accelerometer["y"]
    accel_z = accelerometer["z"]

    raw_pitch = math.degrees(math.atan2(accel_y, math.sqrt((accel_x * accel_x) + (accel_z * accel_z))))
    raw_roll = math.degrees(math.atan2(accel_x, accel_z))
    return raw_pitch, raw_roll


def _build_snapshot_legacy(
    *,
    accelerometer: dict[str, float],
    gyroscope: dict[str, float],
    axle_track_mm: float,
    wheelbase_mm: float,
    zero_pitch_degrees: float,
    zero_roll_degrees: float,
    raw_pitch: float,
    raw_roll: float,
) -> TiltSnapshot:
    pitch = raw_pitch - zero_pitch_degrees
    roll = raw_roll - zero_roll_degrees

    pitch_slope = math.tan(math.radians(pitch))
    roll_slope = math.tan(math.radians(roll))
    wheel_lifts_mm, highest_corner, lowest_corner = _wheel_lifts_from_slopes(
        pitch_slope=pitch_slope,
        roll_slope=roll_slope,
        axle_track_mm=axle_track_mm,
        wheelbase_mm=wheelbase_mm,
    )

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


def _build_snapshot_calibrated(
    *,
    accelerometer: dict[str, float],
    gyroscope: dict[str, float],
    axle_track_mm: float,
    wheelbase_mm: float,
    calibration_level_vector: tuple[float, float, float] | None,
    calibration_coefficients: dict[str, tuple[float, float]],
    raw_pitch: float,
    raw_roll: float,
) -> TiltSnapshot:
    if calibration_level_vector is None:
        raise RuntimeError("Calibration level vector is not available.")
    if not all(corner in calibration_coefficients for corner in LIFT_CORNERS):
        raise RuntimeError("Calibration model is incomplete.")

    basis_x, basis_y = _build_level_basis(calibration_level_vector)
    projected_x, projected_y = _project_vector(_normalize_vector(accelerometer), basis_x, basis_y)

    corner_heights = {
        corner: (calibration_coefficients[corner][0] * projected_x) + (calibration_coefficients[corner][1] * projected_y)
        for corner in LIFT_CORNERS
    }

    highest_corner = max(corner_heights, key=corner_heights.get)
    lowest_corner = min(corner_heights, key=corner_heights.get)
    highest_height = corner_heights[highest_corner]
    wheel_lifts_mm = {
        corner: round(max(0.0, highest_height - height), 1)
        for corner, height in corner_heights.items()
    }

    pitch_slope, roll_slope = _slopes_from_corner_heights(
        corner_heights=corner_heights,
        axle_track_mm=axle_track_mm,
        wheelbase_mm=wheelbase_mm,
    )
    pitch = math.degrees(math.atan(pitch_slope))
    roll = math.degrees(math.atan(roll_slope))

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


def _wheel_lifts_from_slopes(
    *,
    pitch_slope: float,
    roll_slope: float,
    axle_track_mm: float,
    wheelbase_mm: float,
) -> tuple[dict[str, float], str, str]:
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
    return wheel_lifts_mm, highest_corner, lowest_corner


def _slopes_from_corner_heights(
    *,
    corner_heights: dict[str, float],
    axle_track_mm: float,
    wheelbase_mm: float,
) -> tuple[float, float]:
    pitch_slope = (
        (corner_heights[CORNER_FRONT_LEFT] + corner_heights[CORNER_FRONT_RIGHT])
        - (corner_heights[CORNER_REAR_LEFT] + corner_heights[CORNER_REAR_RIGHT])
    ) / (2.0 * max(1.0, wheelbase_mm))

    roll_slope = (
        (corner_heights[CORNER_FRONT_RIGHT] + corner_heights[CORNER_REAR_RIGHT])
        - (corner_heights[CORNER_FRONT_LEFT] + corner_heights[CORNER_REAR_LEFT])
    ) / (2.0 * max(1.0, axle_track_mm))

    return pitch_slope, roll_slope


def _build_calibration_model(
    *,
    samples: dict[str, tuple[float, float, float]],
    target_lift_mm: float,
) -> tuple[tuple[float, float, float], dict[str, tuple[float, float]]]:
    missing = [step for step in [CALIBRATION_LEVEL_STEP, *CALIBRATION_SEQUENCE] if step not in samples]
    if missing:
        raise RuntimeError(f"Missing calibration samples: {', '.join(missing)}")

    level_vector = _normalize_tuple(samples[CALIBRATION_LEVEL_STEP])
    basis_x, basis_y = _build_level_basis(level_vector)

    rows_by_corner: dict[str, list[tuple[float, float, float]]] = {corner: [] for corner in LIFT_CORNERS}
    for lifted_corner in CALIBRATION_SEQUENCE:
        vector = _normalize_tuple(samples[lifted_corner])
        projected_x, projected_y = _project_vector(vector, basis_x, basis_y)
        for corner in LIFT_CORNERS:
            target = target_lift_mm if corner == lifted_corner else 0.0
            rows_by_corner[corner].append((projected_x, projected_y, target))

    coefficients = {corner: _solve_2d_least_squares(rows_by_corner[corner]) for corner in LIFT_CORNERS}
    return level_vector, coefficients


def _solve_2d_least_squares(rows: list[tuple[float, float, float]]) -> tuple[float, float]:
    if len(rows) < 2:
        raise RuntimeError("Insufficient calibration rows to solve the orientation model.")

    sxx = sum(x * x for x, _, _ in rows)
    syy = sum(y * y for _, y, _ in rows)
    sxy = sum(x * y for x, y, _ in rows)
    sxt = sum(x * target for x, _, target in rows)
    syt = sum(y * target for _, y, target in rows)

    det = (sxx * syy) - (sxy * sxy)
    if abs(det) < 1e-9:
        raise RuntimeError("Calibration data is degenerate; repeat calibration with cleaner samples.")

    a = ((sxt * syy) - (syt * sxy)) / det
    b = ((syt * sxx) - (sxt * sxy)) / det
    return a, b


def _normalize_vector(vector: dict[str, float]) -> tuple[float, float, float]:
    return _normalize_tuple((vector["x"], vector["y"], vector["z"]))


def _normalize_tuple(vector: tuple[float, float, float]) -> tuple[float, float, float]:
    length = math.sqrt((vector[0] * vector[0]) + (vector[1] * vector[1]) + (vector[2] * vector[2]))
    if length <= 0:
        raise RuntimeError("Invalid zero-length gravity vector in calibration data.")
    return (vector[0] / length, vector[1] / length, vector[2] / length)


def _build_level_basis(
    level_vector: tuple[float, float, float],
) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    level = _normalize_tuple(level_vector)
    reference = (0.0, 0.0, 1.0)

    if abs(_dot(level, reference)) > 0.9:
        reference = (0.0, 1.0, 0.0)

    basis_x = _normalize_tuple(_cross(reference, level))
    basis_y = _normalize_tuple(_cross(level, basis_x))
    return basis_x, basis_y


def _project_vector(
    vector: tuple[float, float, float],
    basis_x: tuple[float, float, float],
    basis_y: tuple[float, float, float],
) -> tuple[float, float]:
    return _dot(vector, basis_x), _dot(vector, basis_y)


def _dot(left: tuple[float, float, float], right: tuple[float, float, float]) -> float:
    return (left[0] * right[0]) + (left[1] * right[1]) + (left[2] * right[2])


def _cross(left: tuple[float, float, float], right: tuple[float, float, float]) -> tuple[float, float, float]:
    return (
        (left[1] * right[2]) - (left[2] * right[1]),
        (left[2] * right[0]) - (left[0] * right[2]),
        (left[0] * right[1]) - (left[1] * right[0]),
    )


def _direction_for_pitch(pitch: float) -> str:
    if abs(pitch) <= ANGLE_EPSILON_DEGREES:
        return STATE_LEVEL
    return STATE_FRONT_DOWN if pitch > 0 else STATE_REAR_DOWN


def _direction_for_roll(roll: float) -> str:
    if abs(roll) <= ANGLE_EPSILON_DEGREES:
        return STATE_LEVEL
    return STATE_RIGHT_DOWN if roll > 0 else STATE_LEFT_DOWN
