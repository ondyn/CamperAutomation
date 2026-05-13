# Camper Automation

- HomeAssistant in Termux on Android Mi11 phone
- ESP Home
- Tailscale

## Installation and provisioning

- End-to-end install guide (USB + ADB + SSH): `instalation.md`
- Automation scripts: `provisioning/README.md`

## Tilt Meter Integration

- Custom integration path: `hass-config/custom_components/termux_tilt`
- Runtime requirement on the phone: Android app `com.termux.api` plus the Termux package `termux-api`
- Recommended activation source on this phone: `sensor.mi11_app_importance == foreground`
- Manual controls exposed by the integration: `button.sample_once`, `button.set_zero`, `switch.live_sampling`

Reference Home Assistant Core fork:

- [https://github.com/ondyn/hass-core/blob/without-uv/homeassistant.md](https://github.com/ondyn/hass-core/blob/without-uv/homeassistant.md)
