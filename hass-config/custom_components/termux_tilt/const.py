from __future__ import annotations

from homeassistant.const import Platform

DOMAIN = "termux_tilt"

PLATFORMS: list[Platform] = [
    Platform.BUTTON,
    Platform.NUMBER,
    Platform.SENSOR,
    Platform.SWITCH,
]

CONF_ACTIVATION_ENTITY_ID = "activation_entity_id"
CONF_ACTIVATION_STATE = "activation_state"
CONF_AXLE_TRACK_MM = "axle_track_mm"
CONF_WHEELBASE_MM = "wheelbase_mm"
CONF_UPDATE_INTERVAL_SECONDS = "update_interval_seconds"
CONF_ZERO_PITCH_DEGREES = "zero_pitch_degrees"
CONF_ZERO_ROLL_DEGREES = "zero_roll_degrees"
CONF_CALIBRATION_LEVEL_VECTOR = "calibration_level_vector"
CONF_CALIBRATION_COEFFICIENTS = "calibration_coefficients"
CONF_CALIBRATION_TARGET_LIFT_MM = "calibration_target_lift_mm"

DEFAULT_NAME = "Van Tilt Meter"
DEFAULT_ACTIVATION_ENTITY_ID = "sensor.mi11_app_importance"
DEFAULT_ACTIVATION_STATE = "foreground"
DEFAULT_AXLE_TRACK_MM = 1980
DEFAULT_WHEELBASE_MM = 3600
DEFAULT_UPDATE_INTERVAL_SECONDS = 2
DEFAULT_CALIBRATION_TARGET_LIFT_MM = 100.0
MANUAL_SAMPLING_TIMEOUT_SECONDS = 300

SERVICE_SAMPLE_ONCE = "sample_once"
SERVICE_SET_ZERO = "set_zero"
SERVICE_START_SAMPLING = "start_sampling"
SERVICE_STOP_SAMPLING = "stop_sampling"
SERVICE_START_CALIBRATION = "start_calibration"
SERVICE_CAPTURE_CALIBRATION_STEP = "capture_calibration_step"
SERVICE_CANCEL_CALIBRATION = "cancel_calibration"

ATTR_ENTRY_ID = "entry_id"

STATE_LEVEL = "level"
STATE_FRONT_DOWN = "front_down"
STATE_REAR_DOWN = "rear_down"
STATE_LEFT_DOWN = "left_down"
STATE_RIGHT_DOWN = "right_down"

CORNER_FRONT_LEFT = "front_left"
CORNER_FRONT_RIGHT = "front_right"
CORNER_REAR_LEFT = "rear_left"
CORNER_REAR_RIGHT = "rear_right"

CALIBRATION_LEVEL_STEP = "level"
CALIBRATION_SEQUENCE = (
    CORNER_FRONT_RIGHT,
    CORNER_FRONT_LEFT,
    CORNER_REAR_RIGHT,
    CORNER_REAR_LEFT,
)

LIFT_CORNERS = (
    CORNER_FRONT_LEFT,
    CORNER_FRONT_RIGHT,
    CORNER_REAR_LEFT,
    CORNER_REAR_RIGHT,
)

ANGLE_EPSILON_DEGREES = 0.25