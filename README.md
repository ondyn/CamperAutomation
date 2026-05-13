# CamperAutomation

Camper van automation stack centered on Home Assistant Core running in Termux on Android, with ESPHome nodes and VPN-first remote access.

## What This Repo Contains

- `boot/`: Termux:Boot launch scripts (`00-bootstrap` orchestrates VPN -> SSH -> HA).
- `scripts/`: runtime control scripts (`bootstrap_services.sh`, `hass.sh`, `hassctl.sh`, backup/restore helpers).
- `hass-config/`: Home Assistant config, custom components, and frontend cards.
- `esphome/config-esp/`: ESPHome node definitions.
- `provisioning/`: laptop-driven USB/ADB + SSH provisioning automation.
- `android-app/`: charger-monitor and protocol analysis app artifacts.
- `docs/`: setup, operations, troubleshooting, architecture, and status docs.

## Quick Start

1. Install and provision the Android host using `docs/setup/installation.md`.
2. Use provisioning automation from `provisioning/README.md`.
3. Use incident recovery procedures from `docs/operations-runbook.md`.

## Documentation

- Main docs index: `docs/README.md`
- Setup: `docs/setup/installation.md`
- Operations: `docs/operations-runbook.md`
- Troubleshooting notes: `docs/troubleshooting/`
- Architecture plans: `docs/architecture/`
- Historical status snapshots: `docs/status/`

Reference Home Assistant Core fork:

- <https://github.com/ondyn/hass-core/blob/without-uv/homeassistant.md>
