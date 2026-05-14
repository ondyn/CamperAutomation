from __future__ import annotations

from homeassistant.const import Platform

DOMAIN = "termux_camera_photo"

PLATFORMS: list[Platform] = [
    Platform.BUTTON,
    Platform.CAMERA,
    Platform.SENSOR,
]

CONF_CAMERA_ID = "camera_id"
CONF_WWW_SUBDIR = "www_subdir"
CONF_KEEP_LATEST = "keep_latest"

DEFAULT_NAME = "Van Camera"
DEFAULT_CAMERA_ID = 0
DEFAULT_WWW_SUBDIR = "camper_camera"
DEFAULT_KEEP_LATEST = 24

ATTR_ENTRY_ID = "entry_id"
ATTR_CAMERA_ID = "camera_id"
ATTR_FILENAME = "filename"

SERVICE_CAPTURE_PHOTO = "capture_photo"
SERVICE_DELETE_PHOTO = "delete_photo"
EVENT_PHOTO_CAPTURED = "termux_camera_photo.photo_captured"
EVENT_PHOTO_DELETED = "termux_camera_photo.photo_deleted"

MAX_KEEP_LATEST = 200