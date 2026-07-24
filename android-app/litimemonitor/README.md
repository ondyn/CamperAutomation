# LiTimeMonitor

LiTimeMonitor is a read-only Android BLE bridge for LiTime smart batteries. It polls LiTime command `0x13`, displays battery telemetry, and exposes the latest state through an HTTP API bound only to Android loopback.

## Current state

- BLE service `F000FFC0-0451-4000-B000-000000000000`
- Notification subscription on `FFC1` and `FFC2`, matching LiTime 2.9.0
- Writable `FFC1` preferred, with property-based fallback to `FFC2`
- Automatic reconnect and two-second telemetry polling
- Foreground service continues while the UI is closed
- V1 (16-cell) and V2 (32-cell) command `0x13` decoding
- Local API at `127.0.0.1:8766`

The protocol was recovered by static analysis. A real-battery capture is still required to confirm characteristic write selection and engineering-unit scaling on each supported battery model. Capacity and status fields are therefore exposed as raw values.

## API

- `GET /health`
- `GET /api/battery`
- `GET /api/litime`

The server deliberately binds to `127.0.0.1`. Use an on-device Home Assistant integration or an authenticated local forwarding mechanism; do not expose the port directly to the internet.

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

LiTimeMonitor only sends the read-only telemetry request. If a battery behaves unexpectedly, stop the foreground service or uninstall the app; no BMS configuration is modified. Keep the official LiTime app available until telemetry has been compared against the same physical battery.
