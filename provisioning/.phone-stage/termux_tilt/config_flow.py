from __future__ import annotations

import voluptuous as vol

from homeassistant import config_entries
from homeassistant.core import callback

from .const import (
    CONF_ACTIVATION_ENTITY_ID,
    CONF_ACTIVATION_STATE,
    DEFAULT_ACTIVATION_ENTITY_ID,
    DEFAULT_ACTIVATION_STATE,
    DEFAULT_NAME,
    DOMAIN,
)


class TermuxTiltConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
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
                vol.Optional(
                    CONF_ACTIVATION_ENTITY_ID,
                    default=DEFAULT_ACTIVATION_ENTITY_ID,
                ): str,
                vol.Optional(
                    CONF_ACTIVATION_STATE,
                    default=DEFAULT_ACTIVATION_STATE,
                ): str,
            }
        )
        return self.async_show_form(step_id="user", data_schema=schema)

    @staticmethod
    @callback
    def async_get_options_flow(config_entry):
        return TermuxTiltOptionsFlow(config_entry)


class TermuxTiltOptionsFlow(config_entries.OptionsFlow):
    def __init__(self, config_entry) -> None:
        self.config_entry = config_entry

    async def async_step_init(self, user_input=None):
        if user_input is not None:
            return self.async_create_entry(title="", data=user_input)

        options = {**self.config_entry.data, **self.config_entry.options}
        schema = vol.Schema(
            {
                vol.Optional(
                    CONF_ACTIVATION_ENTITY_ID,
                    default=options.get(CONF_ACTIVATION_ENTITY_ID, DEFAULT_ACTIVATION_ENTITY_ID),
                ): str,
                vol.Optional(
                    CONF_ACTIVATION_STATE,
                    default=options.get(CONF_ACTIVATION_STATE, DEFAULT_ACTIVATION_STATE),
                ): str,
            }
        )
        return self.async_show_form(step_id="init", data_schema=schema)