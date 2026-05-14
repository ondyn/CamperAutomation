from __future__ import annotations

import voluptuous as vol

from homeassistant import config_entries
from homeassistant.core import callback

from .const import (
    CONF_CAMERA_ID,
    CONF_KEEP_LATEST,
    CONF_WWW_SUBDIR,
    DEFAULT_CAMERA_ID,
    DEFAULT_KEEP_LATEST,
    DEFAULT_NAME,
    DEFAULT_WWW_SUBDIR,
    DOMAIN,
    MAX_KEEP_LATEST,
)


class TermuxCameraPhotoConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input=None):
        if self._async_current_entries():
            return self.async_abort(reason="single_instance_allowed")

        if user_input is not None:
            title = user_input.pop("name")
            return self.async_create_entry(title=title, data=user_input)

        schema = vol.Schema(
            {
                vol.Required("name", default=DEFAULT_NAME): str,
                vol.Optional(CONF_CAMERA_ID, default=DEFAULT_CAMERA_ID): vol.Coerce(int),
                vol.Optional(CONF_WWW_SUBDIR, default=DEFAULT_WWW_SUBDIR): str,
                vol.Optional(CONF_KEEP_LATEST, default=DEFAULT_KEEP_LATEST): vol.All(
                    vol.Coerce(int),
                    vol.Range(min=1, max=MAX_KEEP_LATEST),
                ),
            }
        )
        return self.async_show_form(step_id="user", data_schema=schema)

    @staticmethod
    @callback
    def async_get_options_flow(config_entry):
        return TermuxCameraPhotoOptionsFlow(config_entry)


class TermuxCameraPhotoOptionsFlow(config_entries.OptionsFlow):
    def __init__(self, config_entry) -> None:
        self._entry = config_entry

    async def async_step_init(self, user_input=None):
        if user_input is not None:
            return self.async_create_entry(title="", data=user_input)

        options = {**self._entry.data, **self._entry.options}
        schema = vol.Schema(
            {
                vol.Optional(CONF_CAMERA_ID, default=options.get(CONF_CAMERA_ID, DEFAULT_CAMERA_ID)): vol.Coerce(int),
                vol.Optional(CONF_WWW_SUBDIR, default=options.get(CONF_WWW_SUBDIR, DEFAULT_WWW_SUBDIR)): str,
                vol.Optional(CONF_KEEP_LATEST, default=options.get(CONF_KEEP_LATEST, DEFAULT_KEEP_LATEST)): vol.All(
                    vol.Coerce(int),
                    vol.Range(min=1, max=MAX_KEEP_LATEST),
                ),
            }
        )
        return self.async_show_form(step_id="init", data_schema=schema)