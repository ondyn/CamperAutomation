# LiTimeMonitor

LiTimeMonitor is an Android BLE bridge for LiTime smart batteries. It polls LiTime command `0x13`, displays battery telemetry, and exposes the latest state through an HTTP API bound only to Android loopback. Its only control operation is an explicitly confirmed battery shutdown.

## Current state

- BLE service `F000FFC0-0451-4000-B000-000000000000`
- Notification subscription on legacy `FFE1` plus `FFC1` and `FFC2`, matching LiTime 2.9.0
- Writable `FFE1` preferred for ordinary battery telemetry, with `FFC1`/`FFC2` fallback
- Automatic reconnect and two-second telemetry polling
- Foreground service continues while the UI is closed
- V1 (16-cell) and V2 (32-cell) command `0x13` decoding
- Active cell and temperature sensors, cell spread, capacities, balancing cells, and raw BMS status fields
- Native-compatible time-to-full and time-to-empty estimates, also exposed to Home Assistant
- Confirmed battery shutdown using command `0x60`, guarded by a charger check and confirmation dialog
- Local API at `127.0.0.1:8766`

The protocol was recovered by static analysis and validated against an `L-12100BNNH19` battery using the `FFE0`/`FFE1` transport. On this model, voltage is reported in millivolts, current in milliamps, temperature in whole degrees Celsius, and capacity in hundredths of an amp-hour. Raw capacity and status fields remain in the API alongside interpreted values for diagnostics and future model support.

LiTime 3.0.0 was pulled from the connected phone and compared with the retained 2.9.0 Flutter AOT analysis. Command `0x13` offsets, BLE transport, operating-state values, and charge/discharge estimate formulas are unchanged. Versioned artifacts and the comparison report are in `analysis-3.0.0/`.

## API

- `GET /health`
- `GET /api/battery`
- `GET /api/litime`

The server deliberately binds to `127.0.0.1`. Use an on-device Home Assistant integration or an authenticated local forwarding mechanism; do not expose the port directly to the internet.

The API is telemetry-only. Battery shutdown is intentionally available only from the app UI so it cannot be triggered accidentally by an HTTP client or Home Assistant automation.

## Build and test

```sh
cd android-app/litimemonitor
flutter pub get
flutter test
flutter analyze
flutter build apk --debug
```

The debug APK is written to `build/app/outputs/flutter-apk/app-debug.apk`.

## Operational fallback

LiTimeMonitor normally sends only the read-only telemetry request. The power button sends shutdown command `0x60` once, only after confirmation and only when charging current is not detected. Disconnect all chargers before shutdown; Bluetooth disconnects immediately, and a charger is required to power the battery back on. No BMS configuration is modified.
