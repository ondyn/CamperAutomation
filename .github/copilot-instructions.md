# CamperAutomation AI Instructions

## Mission
This repository defines a camper-van automation platform where Home Assistant Core runs on a rooted Android phone inside Termux, reachable remotely over VPN, and integrated with ESPHome nodes based mainly on ESP32 boards.

Primary target state:
- Home Assistant Core runs reliably on Android (Termux) in the camper van.
- Home Assistant Companion apps from other devices access this instance over VPN.
- ESPHome nodes provide sensing and control for van systems (temperature, water, rain, GPS-related telemetry, heater integration, leveling, and future modules like camera/OBD).

## Current Architecture Snapshot
- Android/Termux install and operational notes are in instalation.md.
- Boot scripts for Termux:Boot are in boot/ with boot/00-bootstrap as primary orchestrator.
- Home Assistant runtime helper scripts are in scripts/ (bootstrap_services.sh, hass.sh, update_ip.py legacy).
- Home Assistant config is in hass-config/.
- ESPHome configs are in home-automation/config-esp/.
- docker-compose under home-automation/ is used for ESPHome dashboard/container workflows.

## Critical Constraints
- This environment is resource-constrained (phone CPU/storage/battery) and operationally remote.
- Prefer robust, restart-safe, low-maintenance changes over complex one-off optimizations.
- Avoid exposing Home Assistant directly to the public internet.
- Keep secrets out of tracked files and use secrets files wherever possible.
- Preserve existing behavior unless task explicitly asks for refactor or redesign.

## Working Rules For Changes
- Keep Android + Termux paths explicit and correct (for example /data/data/com.termux/files/home/...).
- When proposing install fixes, prioritize reproducible commands and clear rollback steps.
- For Home Assistant changes, keep configuration valid YAML and compatible with current config style.
- For ESPHome changes, prioritize deterministic boot behavior and reliable reconnect on hotspot/VPN changes.
- For sensor/control logic, include safety-oriented defaults (fail-safe OFF states, sane update intervals, guard conditions).

## Reliability Priorities
- Service startup sequence must be deterministic: VPN, SSH, then Home Assistant.
- Any network-dependent integration should degrade gracefully if hotspot/VPN is temporarily unavailable.
- Automations should avoid tight loops and excessive polling.
- Logging should be sufficient for remote troubleshooting while avoiding unnecessary churn.

## Domain Conventions In This Repo
- Scripts in boot/ are shell launchers for Termux:Boot.
- boot/00-bootstrap is the primary boot orchestrator with startup order VPN -> SSH -> Home Assistant.
- scripts/bootstrap_services.sh performs readiness checks and writes bootstrap logs.
- scripts/hass.sh starts Home Assistant without mutating HA .storage files.
- hass-config/configuration.yaml uses includes for automations, scripts, scenes.
- ESPHome config in home-automation/config-esp/esphymer.yaml includes custom truma_inetbox external component plus BME280, Dallas, MPU6050 and template calculations.

## Termux Source Policy (from termux/termux-app README)
- Use Android >= 7 for full Termux app + package support.
- Install Termux and all Termux plugins (for example Termux:Boot) from the same source/signing key only.
- Do not mix Termux sources (GitHub, F-Droid, Play) on the same install because sharedUserId signature mismatch will break plugin compatibility.
- If using GitHub builds, use official releases/artifacts from termux/termux-app only.
- Treat non-official redistributed GitHub APKs as untrusted due public test-key signing risk.
- Prefer stable F-Droid or official GitHub release channels over Play Store experimental branch for this project.

## Security And Operations
- Prefer VPN-first remote access (Tailscale userspace networking in Termux).
- Keep SSH hardening in scope for remote access tasks.
- Track package/tooling compatibility issues (pip/uv/Termux package ecosystem) explicitly when encountered.
- If logs indicate recurring runtime faults, prioritize root-cause mitigation before adding features.

## Expected Output Style For AI Work
For architecture or implementation requests in this workspace, provide:
1. Current-state assessment (what exists now).
2. Gap-to-target analysis (what is missing/risky).
3. Concrete implementation steps with file-level edits.
4. Validation checklist (commands/tests/log checks).
5. Operational risk notes and fallback plan.
