# Termux Camera Photo Integration

## Current State

- Home Assistant custom components are versioned in `hass-config/custom_components` and provisioned to phone by scripts in `provisioning/ssh`.
- Home Assistant runs in Termux on Android, so `termux-camera-photo` can capture directly on-device.

## What This Adds

- New HA custom integration: `termux_camera_photo`.
- New Lovelace card asset: `/local/termux-camera-gallery-card.js`.
- New provisioning script: `provisioning/ssh/21_install_termux_camera_photo.sh`.
- Example dashboard YAML and notification automation YAML.

## Entities Created By Integration

- `button.<entry_name>_take_picture`
- `camera.<entry_name>_latest_picture`
- `sensor.<entry_name>_photos_stored`

Sensor attributes include:

- `recent_photos` list with URL + filename + timestamp
- `latest_photo_url`
- `last_error`

## Capture Flow

1. Button press (or service call) triggers `termux-camera-photo`.
2. Image is stored in `/config/www/<www_subdir>/photo_*.jpg` (resolved via HA config path).
3. Integration refreshes gallery list and emits event `termux_camera_photo.photo_captured`.
4. Dashboard thumbnails update from sensor attributes.

## Provisioning

Run:

```bash
./provisioning/ssh/21_install_termux_camera_photo.sh
```

The script:

- auto-detects phone host/user when possible
- installs Termux package `termux-api` if needed
- deploys custom component and custom card into active HA config
- optionally restarts Home Assistant (`RESTART_HA=1`, default)

## Manual Android Prerequisites

- Install Termux and Termux:API from the same source/signing key.
- Grant camera permission to Termux:API app.

## Dashboard Setup

1. Add Lovelace resource `/local/termux-camera-gallery-card.js` as type `module`.
2. Create integration entry in HA UI: Settings -> Devices & Services -> Add integration -> Termux Camera Photo.
3. Use example from `hass-config/termux_camera_photo_example_dashboard.yaml`.

## Notification Automation

Use `hass-config/termux_camera_photo_example_automation.yaml` to send each new image to Pixel 8 Pro device ID `6393f16dcebe72e35a868b91397da5c8`.

## Validation Checklist

After deployment and HA restart:

1. Integration loads without errors in HA logs.
2. `termux_camera_photo.capture_photo` service is visible in Developer Tools.
3. Pressing `button.*_take_picture` creates a file under `/config/www/<www_subdir>/`.
4. Sensor `recent_photos` attribute updates and card thumbnails are clickable.
5. Pixel 8 Pro receives notification with image preview.

## Operational Risks And Fallback

- If `termux-camera-photo` fails, `last_error` is populated and entities remain available.
- If camera permission is denied on Android, captures will fail until permission is granted.
- If custom card resource is missing, use core `picture-entity` card with `camera.*_latest_picture` as fallback.