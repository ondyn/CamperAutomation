from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import CALLBACK_TYPE, HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.util import dt as dt_util

from .const import (
    CONF_CAMERA_ID,
    CONF_KEEP_LATEST,
    CONF_WWW_SUBDIR,
    DEFAULT_CAMERA_ID,
    DEFAULT_KEEP_LATEST,
    DEFAULT_WWW_SUBDIR,
    DOMAIN,
    EVENT_PHOTO_CAPTURED,
    MAX_KEEP_LATEST,
)


@dataclass(slots=True)
class PhotoMeta:
    filename: str
    absolute_path: str
    url: str
    captured_at_iso: str


class TermuxCameraPhotoHub:
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self.entry = entry
        self._listeners: list[Callable[[], None]] = []
        self._capture_lock = asyncio.Lock()

        self.camera_id = DEFAULT_CAMERA_ID
        self.www_subdir = DEFAULT_WWW_SUBDIR
        self.keep_latest = DEFAULT_KEEP_LATEST
        self.output_dir = Path(hass.config.path("www", self.www_subdir))

        self.command_available = True
        self.last_error: str | None = None
        self.last_captured_at: str | None = None
        self.latest_photo: PhotoMeta | None = None
        self.recent_photos: list[PhotoMeta] = []

        self.device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            manufacturer="Termux",
            model="Android Camera",
            name=entry.title,
        )

        self._apply_entry_values(entry)

    async def async_setup(self) -> None:
        self._ensure_output_dir()
        self._refresh_recent_photos()

    async def async_reload_from_entry(self, entry: ConfigEntry) -> None:
        self.entry = entry
        self._apply_entry_values(entry)
        self._ensure_output_dir()
        self._refresh_recent_photos()
        self._notify_listeners()

    @callback
    def async_add_listener(self, listener: Callable[[], None]) -> CALLBACK_TYPE:
        self._listeners.append(listener)

        @callback
        def remove_listener() -> None:
            if listener in self._listeners:
                self._listeners.remove(listener)

        return remove_listener

    @property
    def extra_state_attributes(self) -> dict:
        return {
            "camera_id": self.camera_id,
            "www_subdir": self.www_subdir,
            "output_dir": str(self.output_dir),
            "keep_latest": self.keep_latest,
            "latest_photo_url": self.latest_photo.url if self.latest_photo else None,
            "latest_photo_path": self.latest_photo.absolute_path if self.latest_photo else None,
            "latest_photo_filename": self.latest_photo.filename if self.latest_photo else None,
            "last_captured_at": self.last_captured_at,
            "recent_photos": [
                {
                    "filename": photo.filename,
                    "url": photo.url,
                    "captured_at": photo.captured_at_iso,
                }
                for photo in self.recent_photos
            ],
            "last_error": self.last_error,
        }

    async def async_capture_photo(self, camera_id: int | None = None) -> None:
        async with self._capture_lock:
            self._ensure_output_dir()
            target_camera_id = self.camera_id if camera_id is None else int(camera_id)
            target_path = self.output_dir / self._build_filename()

            try:
                process = await asyncio.create_subprocess_exec(
                    "termux-camera-photo",
                    "-c",
                    str(target_camera_id),
                    str(target_path),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
            except FileNotFoundError:
                self.command_available = False
                self.last_error = "termux-camera-photo command not found. Install termux-api package and Termux:API app."
                self._notify_listeners()
                return

            stdout, stderr = await process.communicate()
            if process.returncode != 0:
                self.command_available = True
                self.last_error = (
                    stderr.decode("utf-8", errors="ignore").strip()
                    or stdout.decode("utf-8", errors="ignore").strip()
                    or f"termux-camera-photo exited with code {process.returncode}"
                )
                self._notify_listeners()
                return

            if not target_path.exists() or target_path.stat().st_size <= 0:
                self.command_available = True
                self.last_error = "Capture command finished, but no photo file was created."
                self._notify_listeners()
                return

            self.command_available = True
            self.last_error = None
            self.last_captured_at = dt_util.utcnow().isoformat()
            self._refresh_recent_photos()
            self.hass.bus.async_fire(
                EVENT_PHOTO_CAPTURED,
                {
                    "entry_id": self.entry.entry_id,
                    "filename": target_path.name,
                    "url": self.latest_photo.url if self.latest_photo else None,
                    "absolute_path": str(target_path),
                    "captured_at": self.last_captured_at,
                },
            )
            self._notify_listeners()

    async def async_get_latest_image_bytes(self) -> bytes | None:
        if self.latest_photo is None:
            self._refresh_recent_photos()
        if self.latest_photo is None:
            return None

        image_path = Path(self.latest_photo.absolute_path)
        if not image_path.exists():
            self._refresh_recent_photos()
            if self.latest_photo is None:
                return None
            image_path = Path(self.latest_photo.absolute_path)
            if not image_path.exists():
                return None

        return await self.hass.async_add_executor_job(image_path.read_bytes)

    def _apply_entry_values(self, entry: ConfigEntry) -> None:
        options = {**entry.data, **entry.options}
        self.camera_id = int(options.get(CONF_CAMERA_ID, DEFAULT_CAMERA_ID))

        subdir = str(options.get(CONF_WWW_SUBDIR, DEFAULT_WWW_SUBDIR)).strip().strip("/")
        self.www_subdir = subdir or DEFAULT_WWW_SUBDIR

        requested_keep_latest = int(options.get(CONF_KEEP_LATEST, DEFAULT_KEEP_LATEST))
        self.keep_latest = max(1, min(MAX_KEEP_LATEST, requested_keep_latest))

        self.output_dir = Path(self.hass.config.path("www", self.www_subdir))

    def _ensure_output_dir(self) -> None:
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def _refresh_recent_photos(self) -> None:
        if not self.output_dir.exists():
            self.recent_photos = []
            self.latest_photo = None
            return

        files = [
            file
            for pattern in ("*.jpg", "*.jpeg", "*.png")
            for file in self.output_dir.glob(pattern)
            if file.is_file()
        ]
        files.sort(key=lambda file: file.stat().st_mtime, reverse=True)

        photos: list[PhotoMeta] = []
        for file in files[: self.keep_latest]:
            captured_at = dt_util.utc_from_timestamp(file.stat().st_mtime).isoformat()
            photos.append(
                PhotoMeta(
                    filename=file.name,
                    absolute_path=str(file),
                    url=f"/local/{self.www_subdir}/{file.name}",
                    captured_at_iso=captured_at,
                )
            )

        self.recent_photos = photos
        self.latest_photo = photos[0] if photos else None

    def _build_filename(self) -> str:
        # UTC timestamp keeps file order stable even across timezone changes.
        stamp = dt_util.utcnow().strftime("%Y%m%dT%H%M%SZ")
        return f"photo_{stamp}.jpg"

    @callback
    def _notify_listeners(self) -> None:
        for listener in list(self._listeners):
            listener()