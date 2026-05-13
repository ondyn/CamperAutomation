# Charger Monitor → Home Assistant Integration Plan

## Current State Assessment

- `android-app/chargermonitor` is a Flutter app that connects to a solar charge controller via BLE (GATT service `000018F0...`).
- It decodes a 40-byte realtime frame into 22 fields: battery, assistant battery, solar panel, load, and starting battery voltages/currents/powers, plus status flags.
- The app is purely foreground/UI-driven: no background service, no external API.
- Home Assistant Core runs inside Termux on the **same Android phone**.
- A reference custom integration (`termux_tilt`) already lives in `hass-config/custom_components/` and follows the `DataUpdateCoordinator` / `config_flow` pattern — it is the structural template for the new integration.

---

## Architecture Decision

**Flutter exposes a local REST API → HA polls it via a custom integration.**

```
BLE Device (charger)
      │ GATT notify (device pushes frames)
      ▼
Flutter Foreground Service  ←──── Android keeps alive (notification shown)
      │ maintains latest RealtimeData in memory
      │ hosts HTTP server on 127.0.0.1:8765 (loopback only)
      ▼
HA custom integration (chargermonitor)
      │ DataUpdateCoordinator polls /api/charger every N seconds
      │ exposes ~24 sensor entities
      ▼
Lovelace Dashboard Card
```

### Why this approach over alternatives

| Approach | Pros | Cons |
|---|---|---|
| **Flutter local REST + HA polls** | Battery-controlled polling; HA drives frequency; simple loopback IPC; no external exposure | Requires embedded HTTP server in Flutter |
| Flutter pushes to HA REST API | Real-time push; no server in Flutter | Flutter must track HA state; runs more often; harder to throttle |
| MQTT broker in Termux | Decoupled; supports multiple subscribers | Another service to maintain; more moving parts on a resource-constrained phone |
| Shared filesystem / named pipe | Ultra-simple | Polling only on HA side; race conditions; no structured data |

**Chosen approach** is the best fit because:
- HA configures the polling cadence (battery-conscious).
- Flutter only does work when the BLE device delivers a notify frame — completely passive otherwise.
- Loopback HTTP is trivially secure (no network exposure).
- Clean separation of concerns: Flutter owns BLE; HA owns data lifecycle.

---

## Gap-to-Target Analysis

| Gap | Risk | Resolution |
|---|---|---|
| No Android Foreground Service | BLE killed when app backgrounded | Phase 1 |
| No HTTP server in Flutter | No IPC channel to HA | Phase 2 |
| No HA custom integration | No entities | Phase 3 |
| No Lovelace card | No dashboard | Phase 4 |
| No power-save BLE mode | Continuous BLE radio drain | Phase 5 (optional) |

---

## Phase 1 — Flutter: Android Foreground Service

Goal: keep BLE connection alive when the app is in background or screen is off.

Android requires a **Foreground Service** with a persistent notification for long-running BLE work.

### 1.1 New Flutter packages (add to `pubspec.yaml`)

```yaml
dependencies:
  flutter_background_service: ^5.x.x   # manages foreground service lifecycle
  flutter_local_notifications: ^18.x.x # required: notification for foreground service
```

### 1.2 AndroidManifest.xml additions (`android/app/src/main/AndroidManifest.xml`)

```xml
<!-- Foreground service permissions -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
<!-- Required for displaying foreground service notification -->
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>

<!-- Inside <application> block, declare the background service -->
<service
    android:name="id.flutter.flutter_background_service.BackgroundService"
    android:foregroundServiceType="connectedDevice"
    android:exported="false"/>
```

### 1.3 Code refactor: extract `ChargerService`

Create `lib/charger_service.dart`:
- Move all BLE connection logic (`DeviceDashboardPage._connectAndListen`) into `ChargerService`.
- `ChargerService` maintains: last `RealtimeData`, connection state, device type string, last-update timestamp.
- `ChargerService` owns the 5 s heartbeat timer and reconnect loop.
- `ChargerService` is a singleton started/stopped by the background service entry point.
- UI layer (`DeviceDashboardPage`) reads state from `ChargerService` instead of managing BLE directly.

### 1.4 Background service entry point

Create `lib/background_main.dart`:
- `@pragma('vm:entry-point') void backgroundMain()` — this is the isolate entry for the foreground service.
- Initialises `flutter_background_service` with a foreground notification ("Charger Monitor running").
- Creates `ChargerService` and starts the local HTTP server (Phase 2).
- On service stop: closes HTTP server, disconnects BLE.

### 1.5 Service startup from `main.dart`

In `main()`:
```dart
await FlutterBackgroundService().configure(
  androidConfiguration: AndroidConfiguration(
    onStart: backgroundMain,
    isForegroundMode: true,
    notificationChannelId: 'charger_monitor',
    initialNotificationTitle: 'Charger Monitor',
    initialNotificationContent: 'Waiting for BLE device…',
    foregroundServiceNotificationId: 888,
    foregroundServiceTypes: [AndroidForegroundType.connectedDevice],
  ),
  iosConfiguration: IosConfiguration(autoStart: false),
);
await FlutterBackgroundService().startService();
```

### 1.6 UI ↔ Service communication

`flutter_background_service` exposes `invoke()` / `on()` for inter-isolate messaging.  
The UI can call `service.invoke('get_state')` and receive the latest JSON back via an event stream, so the dashboard keeps working when the service is running in background.

---

## Phase 2 — Flutter: Embedded REST API

Goal: expose last-known charger data on `127.0.0.1:8765` so HA can poll it.

### 2.1 New Flutter package

```yaml
dependencies:
  shelf: ^1.x.x           # embedded HTTP server
  shelf_router: ^1.x.x    # optional, for clean routing
```

### 2.2 Server setup (inside `backgroundMain`)

```dart
final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8765);
```
Or using `shelf`:
```dart
final handler = const Pipeline().addHandler(_router);
final server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 8765);
```

### 2.3 Endpoints

#### `GET /health`
```json
{ "status": "ok", "uptime_seconds": 3600 }
```

#### `GET /api/charger`
```json
{
  "connection": "connected",
  "device_type": "MPPT150/35",
  "device_type_code": 2,
  "last_update_ms": 1715423400000,
  "data": {
    "battery_voltage_v": 25.6,
    "battery_current_a": 12.3,
    "assistant_battery_voltage_v": 12.1,
    "assistant_battery_current_a": 0.0,
    "solar_panel_voltage_v": 32.4,
    "solar_panel_power_w": 180,
    "load_voltage_v": 25.5,
    "load_current_a": 3.2,
    "load_power_w": 82,
    "starting_battery_voltage_v": 12.8,
    "starting_battery_voltage2_v": 0.0,
    "charge_capacity_ah": 45.2,
    "charge_energy_wh": 1153.0,
    "assistant_charge_capacity_ah": 0.0,
    "assistant_charge_energy_wh": 0.0
  },
  "flags": {
    "charge_state": true,
    "assistant_charge_state": false,
    "full_charge": false,
    "over_temp": false,
    "battery_over_pressure": false,
    "pv_over_pressure": false,
    "battery_under_voltage": false
  }
}
```

`connection` values: `"connected"`, `"connecting"`, `"disconnected"`.  
`data` is `null` when `connection != "connected"`.

### 2.4 Security note

The server **must** bind to `InternetAddress.loopbackIPv4` (`127.0.0.1`), never to `0.0.0.0`.  
This guarantees that only processes on the same device (i.e., Termux/HA) can reach it.  
No authentication is needed given loopback-only binding.

### 2.5 Mapping from `RealtimeData` to JSON

`ChargerService` serialises its current `RealtimeData` to the JSON map above.  
When no frame has been received yet, `data` is `null` and `connection` reflects the current BLE state.

---

## Phase 3 — Home Assistant: Custom Integration `chargermonitor`

Goal: create `hass-config/custom_components/chargermonitor/` that polls the Flutter REST endpoint and exposes sensor entities.

Reference: `hass-config/custom_components/termux_tilt/` — use the same file layout.

### 3.1 File layout

```
hass-config/custom_components/chargermonitor/
├── __init__.py          # setup_entry / unload_entry
├── manifest.json
├── const.py             # domain, default interval, endpoint URL
├── coordinator.py       # ChargerDataCoordinator (DataUpdateCoordinator)
├── config_flow.py       # UI config: poll interval
├── sensor.py            # sensor entity definitions
├── strings.json
└── translations/
    └── en.json
```

### 3.2 `manifest.json`

```json
{
  "domain": "chargermonitor",
  "name": "Charger Monitor",
  "codeowners": ["@ondyn"],
  "config_flow": true,
  "documentation": "https://github.com/ondyn/CamperAutomation",
  "integration_type": "device",
  "iot_class": "local_polling",
  "requirements": [],
  "version": "0.1.0"
}
```

### 3.3 `const.py`

```python
DOMAIN = "chargermonitor"
DEFAULT_SCAN_INTERVAL = 60          # seconds — safe default for battery
MIN_SCAN_INTERVAL = 10
MAX_SCAN_INTERVAL = 300
CHARGER_API_URL = "http://127.0.0.1:8765/api/charger"
```

### 3.4 `coordinator.py`

```python
class ChargerDataCoordinator(DataUpdateCoordinator):
    """Fetches charger data from the local Flutter REST endpoint."""

    def __init__(self, hass, scan_interval_seconds: int):
        super().__init__(
            hass,
            logger=_LOGGER,
            name=DOMAIN,
            update_interval=timedelta(seconds=scan_interval_seconds),
        )
        self._session = async_get_clientsession(hass)

    async def _async_update_data(self) -> dict:
        try:
            async with async_timeout.timeout(5):
                resp = await self._session.get(CHARGER_API_URL)
                resp.raise_for_status()
                return await resp.json()
        except Exception as err:
            raise UpdateFailed(f"Charger API error: {err}") from err
```

On `UpdateFailed`, HA marks entities as `unavailable` automatically.

### 3.5 `sensor.py` — entity definitions

Define one `SensorEntityDescription` per metric:

| Entity | Unit | device_class | state_class |
|---|---|---|---|
| `battery_voltage` | V | `voltage` | `measurement` |
| `battery_current` | A | `current` | `measurement` |
| `solar_panel_voltage` | V | `voltage` | `measurement` |
| `solar_panel_power` | W | `power` | `measurement` |
| `load_voltage` | V | `voltage` | `measurement` |
| `load_current` | A | `current` | `measurement` |
| `load_power` | W | `power` | `measurement` |
| `assistant_battery_voltage` | V | `voltage` | `measurement` |
| `assistant_battery_current` | A | `current` | `measurement` |
| `starting_battery_voltage` | V | `voltage` | `measurement` |
| `charge_capacity` | Ah | — | `total_increasing` |
| `charge_energy` | Wh | `energy` | `total_increasing` |
| `assistant_charge_capacity` | Ah | — | `total_increasing` |
| `assistant_charge_energy` | Wh | `energy` | `total_increasing` |
| `connection_status` | — (enum) | — | — (diagnostic) |
| `device_type` | — (string) | — | — (diagnostic) |

Boolean flags (charge_state, over_temp, etc.) are exposed as `BinarySensorEntity` or as a `sensor` with `on`/`off` string values.

Each entity accesses `coordinator.data["data"][key]` with a `key_fn` accessor; it returns `None` (→ `unknown`) when `data` is `null` (BLE disconnected).

### 3.6 `config_flow.py`

Two-step UI flow:
1. Discovery step: verify the endpoint is reachable (`GET /health`).
2. Options step: choose poll interval (slider 10–300 s, default 60 s).

Follows the same pattern as `termux_tilt/config_flow.py`.

### 3.7 `__init__.py`

```python
async def async_setup_entry(hass, entry):
    interval = entry.options.get(CONF_SCAN_INTERVAL, DEFAULT_SCAN_INTERVAL)
    coordinator = ChargerDataCoordinator(hass, interval)
    await coordinator.async_config_entry_first_refresh()
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    await hass.config_entries.async_forward_entry_setups(entry, ["sensor", "binary_sensor"])
    return True
```

### 3.8 Add to HA configuration

Via UI: Settings → Integrations → Add Integration → "Charger Monitor".  
No manual YAML entry needed (config_flow handles it).  
Optionally add a `chargermonitor:` stub in `configuration.yaml` for documentation purposes.

---

## Phase 4 — Home Assistant: Lovelace Dashboard

Goal: a clear, at-a-glance power overview on the HA dashboard.

### 4.1 Recommended card layout (standard built-in cards)

```
┌─────────────────────────────────────────────────────┐
│  [Entities card]  Charger Status                    │
│   • Connection: connected                           │
│   • Device: MPPT150/35                              │
├────────────────────┬────────────────────────────────┤
│  [Gauge] Battery V │  [Gauge] Solar Power           │
│      25.6 V        │        180 W                   │
├────────────────────┼────────────────────────────────┤
│  [Statistics card] Charge Energy (Wh) — daily      │
├────────────────────┴────────────────────────────────┤
│  [Entities] Flags: Charging ✓  Full ✗  Over-temp ✗  │
└─────────────────────────────────────────────────────┘
```

Use standard `gauge`, `entities`, `statistics-graph` and `history-graph` cards — no custom JS required for a functional dashboard.

### 4.2 Optional: Custom card `charger-monitor-card.js`

Place in `hass-config/www/charger-monitor-card.js`.  
Renders a compact solar power-flow diagram (PV → Battery → Load) with live numbers, similar to the energy flow diagram in HA Energy dashboard.  
This is optional but gives a much better UX than a list of sensors.

Steps:
1. Create `www/charger-monitor-card.js` as a vanilla JS Lit-Element card.
2. Register in HA: Settings → Dashboards → Resources → add `/local/charger-monitor-card.js`.
3. Use in dashboard YAML:
   ```yaml
   type: custom:charger-monitor-card
   entity_prefix: sensor.chargermonitor_
   ```

---

## Phase 5 — Battery Efficiency Tuning (Optional Power-Save Mode)

The default architecture keeps BLE connected continuously (required for GATT notify). This is unavoidable if you want sub-minute freshness. However, if battery is critical:

### Option A: Keep-alive (default, recommended)
- BLE notify: device pushes frames; radio is mostly idle between frames.
- Heartbeat every 5 s: ~4 bytes, minimal radio time.
- HA polls REST every 60 s: HTTP local call, no radio.
- **Net impact**: BLE radio stays powered but GATT notify mode is low-power by design.

### Option B: Scheduled connect (lower power, less fresh data)
- Foreground service wakes on a WorkManager periodic task (e.g., every 5 min).
- Connects to BLE, waits for one valid realtime frame, updates REST endpoint, disconnects.
- Total BLE session: ~3–10 s per cycle.
- HA poll interval can be tuned to match (e.g., 5 min).
- Implementation: use `android_alarm_manager_plus` or WorkManager via a method channel.
- Trade-off: data is 0–5 min stale; simpler on battery; slightly more complex code.

### Configurable interval in HA config_flow
The poll interval in the config flow (`MIN_SCAN_INTERVAL`=10 s, `MAX_SCAN_INTERVAL`=300 s) lets you tune HA's refresh rate independently of BLE cadence. Recommended starting point: **60 s**.

---

## Implementation Order & Dependencies

```
Phase 1 (Foreground Service)
  └─► Phase 2 (REST API)          ← depends on service running in background
        └─► Phase 3 (HA Integration) ← depends on REST API being available
              └─► Phase 4 (Dashboard) ← depends on entities existing in HA
Phase 5 (Power-save)              ← independent, optional optimisation after Phase 1
```

---

## Validation Checklist

### After Phase 1 (background service)
- [ ] App survives screen-off and swipe-away from recents.
- [ ] Foreground notification appears after app launch.
- [ ] BLE RSSI and heartbeat timer stay active (check logcat: `adb logcat -s ChargerService`).
- [ ] Reconnect fires after simulated BLE disconnect.

### After Phase 2 (REST API)
- [ ] `curl http://127.0.0.1:8765/health` returns `{"status":"ok"}` from Termux.
- [ ] `curl http://127.0.0.1:8765/api/charger` returns full JSON with live data.
- [ ] Binding to `127.0.0.1` confirmed: `curl http://192.168.x.x:8765/api/charger` must refuse connection.
- [ ] `connection` field correctly transitions `connecting` → `connected` → `disconnected`.

### After Phase 3 (HA integration)
- [ ] Integration appears in Settings → Integrations.
- [ ] All ~20 sensor entities are created and not in `unavailable` state.
- [ ] Sensor values match what the Flutter dashboard shows.
- [ ] HA log (`home-assistant.log`) shows no repeated errors for `chargermonitor`.
- [ ] Poll interval change in Options takes effect without HA restart.

### After Phase 4 (dashboard)
- [ ] Dashboard loads without JS errors.
- [ ] Gauge cards update on next poll.
- [ ] History graphs accumulate data over time.

---

## Operational Risk Notes & Fallbacks

| Risk | Mitigation |
|---|---|
| Flutter app killed by Android battery optimisation | Add app to battery optimisation whitelist; instruct user to disable optimisation for chargermonitor |
| HA polls before Flutter starts after phone reboot | HA entities show `unavailable` gracefully; coordinator retries on next interval |
| Port 8765 conflict with another process | Choose alternate port (e.g., 18765); expose as a `const.py` constant configurable at build time |
| BLE device out of range | `connection: "disconnected"` in JSON → all data sensors show `unavailable` in HA |
| HA restart means integration re-registers coordinator | `async_config_entry_first_refresh` handles first-fetch; subsequent polls resume normally |
| Termux not running when Flutter polls loopback | N/A — both are on same OS; loopback always available |
| Flutter foreground service stopped manually by user | BLE disconnects; HA entities go `unavailable`; user must reopen app to restart service |
