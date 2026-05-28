# Roof Vent RF Integration Plan

## Device Identification

The installed unit is a **CE-marked 12V roof vent fan** (common Chinese OEM, sold under various brands —
WC-1200, Heng Long, Camplux variants, etc.). Key observable features:

- Clear plastic fan blades, ~400 mm square plastic frame
- Rain sensor dome on inner frame
- 12V DC supply (red/white wire pair visible at frame edge)
- Wireless remote with a re-pair procedure: *hold POWER + RAIN SENSOR button on the vent for 4 s*

## Radio Protocol Analysis

The pairing procedure ("hold to enter learning mode") is the universal signature of **EV1527 / RC-Switch
fixed-code, 433.92 MHz ASK/OOK** radio.

Key properties:
- **Not Bluetooth, not Zigbee, not Z-Wave** — it is simple RF
- **Not encrypted** — EV1527 is a fixed 20-bit address + 4-bit data per frame
- **One-way only** — the vent only receives; there is no acknowledgement or state feedback
- "Pairing" just means the receiver learns the transmitter's fixed address; it is fully replayable
- Multiple remotes can be paired simultaneously — adding the ESP does not break the original remote

## Integration Options

| Approach | Effort | Reliability | Invasiveness |
|---|---|---|---|
| **RF replay via ESP32 + TX module** | Low | High (no state feedback) | None — non-invasive |
| **Wire to PCB button pads** | Medium | High | Low — solder only, leave PCB intact |
| **Replace control board** | High | Very high (full PWM control) | High — invasive |

**Recommended path:** RF replay first (Phase 1–2 below). Add wired button-pad tapping later if
state feedback becomes required.

---

## Hardware Required

- **433 MHz TX+RX module pair** (e.g. AliExpress listing 1005003047926557, select "433M" colour)  
  - TX module: FS1000A or equivalent, DATA+VCC+GND
  - RX module: XY-MK-5V or equivalent superregenerative, DATA+VCC+GND
- **ESP32 board** (any `esp32dev`-compatible; a spare C3 also works with pin adjustments)
- Short wire antenna on RX/TX modules: 17.3 cm straight wire = quarter-wave at 433.92 MHz

### Wiring

```
RX module VCC  → ESP32 3.3V
RX module GND  → ESP32 GND
RX module DATA → ESP32 GPIO14

TX module VCC  → ESP32 5V  (needs 5V for adequate range)
TX module GND  → ESP32 GND
TX module DATA → ESP32 GPIO4
```

During code capture: place the RX module **≤20 cm from the vent remote** — cheap superregenerative
receivers are noisy, proximity compensates.

---

## Phase 1 — Capture Remote Codes

Flash the sniffer config below to a spare ESP32. Open the ESPHome log and press **each remote button
3–5 times**. Note the decoded code string per button — EV1527 codes are fixed, so each button press
should produce an identical string.

**`esphome/config-esp/vent-sniffer.yaml`**

```yaml
esphome:
  name: vent-sniffer
  friendly_name: Vent Sniffer
  platform: ESP32
  board: esp32dev

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password

api:
  encryption:
    key: !secret enc_key

ota:
  password: !secret ota_pwd

logger:
  level: DEBUG

remote_receiver:
  pin:
    number: GPIO14
    inverted: false
  dump: all          # logs every protocol it can decode
  tolerance: 25%     # lenient for noisy cheap receiver
  buffer_size: 4kb
  idle: 4ms
```

**Expected log output (one line per button press):**

```
[D][rc_switch] Received RCSwitch Raw: protocol=1 data='101010001100110010101100'
```

If the log shows `[raw]` lines but no decoded protocol, add `dump: raw` and paste the timings —
the protocol can be decoded manually from pulse widths.

If the log is silent:
- Verify 433 MHz variant was ordered (not 315 MHz)
- Move remote closer to the RX module antenna
- Try a different GPIO pin

---

## Phase 2 — Transmit Config (replaces sniffer)

After capturing all codes, create the final ESPHome config. Replace placeholder `'YOUR_CODE_HERE'`
strings with the actual captured codes.

**`esphome/config-esp/vent-remote.yaml`**

```yaml
esphome:
  name: vent-remote
  friendly_name: Vent Remote
  platform: ESP32
  board: esp32dev

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  ap:
    ssid: "vent-remote-fallback"
    password: !secret ap_pwd

api:
  encryption:
    key: !secret enc_key

ota:
  password: !secret ota_pwd

logger:
  level: INFO

remote_transmitter:
  pin: GPIO4
  carrier_duty_percent: 100%   # pure OOK — no carrier wave

button:
  - platform: template
    name: "Vent Power"
    icon: mdi:fan
    on_press:
      - remote_transmitter.transmit_rc_switch_raw:
          code: 'YOUR_CODE_HERE'
          protocol: 1
          repeat:
            times: 5
            wait_time: 10ms

  - platform: template
    name: "Vent Speed Up"
    icon: mdi:fan-plus
    on_press:
      - remote_transmitter.transmit_rc_switch_raw:
          code: 'YOUR_CODE_HERE'
          protocol: 1
          repeat:
            times: 5
            wait_time: 10ms

  - platform: template
    name: "Vent Speed Down"
    icon: mdi:fan-minus
    on_press:
      - remote_transmitter.transmit_rc_switch_raw:
          code: 'YOUR_CODE_HERE'
          protocol: 1
          repeat:
            times: 5
            wait_time: 10ms

  - platform: template
    name: "Vent Direction Toggle"
    icon: mdi:fan-chevron-up
    on_press:
      - remote_transmitter.transmit_rc_switch_raw:
          code: 'YOUR_CODE_HERE'
          protocol: 1
          repeat:
            times: 5
            wait_time: 10ms
```

> `repeat: times: 5` is required — EV1527 receivers expect to see the same frame repeated several
> times before acting. Do not reduce below 3.

### Re-pairing the vent to the ESP32

1. Put vent into learning mode: hold POWER + RAIN SENSOR button on vent frame for 4 s (LED blinks).
2. Immediately trigger the ESPHome "Vent Power" button from HA / ESPHome dashboard.
3. Vent confirms pairing (beep or LED change).
4. The original handheld remote continues to work in parallel — EV1527 receivers support multiple learned codes.

---

## Phase 3 — Home Assistant Integration

Once `vent-remote` is adopted into HA via the ESPHome integration, create a fan entity template
to expose it as a proper HA fan device (speed buttons mapped to percentage steps).

```yaml
# hass-config/packages/vent.yaml
fan:
  - platform: template
    fans:
      roof_vent:
        friendly_name: "Roof Vent"
        value_template: "{{ is_state('input_boolean.vent_power', 'on') }}"
        turn_on:
          service: button.press
          target:
            entity_id: button.vent_remote_vent_power
        turn_off:
          service: button.press
          target:
            entity_id: button.vent_remote_vent_power
        set_percentage:
          service: script.vent_set_speed
          data:
            percentage: "{{ percentage }}"
```

A simple dashboard card:

```yaml
type: entities
title: Roof Vent
entities:
  - entity: button.vent_remote_vent_power
  - entity: button.vent_remote_vent_speed_up
  - entity: button.vent_remote_vent_speed_down
  - entity: button.vent_remote_vent_direction_toggle
```

---

## Phase 4 — Optional: Wired Button-Pad Control

If RF becomes unreliable or state feedback is needed, open the vent's inner control PCB and
solder wires to the on-board button pads. Drive them LOW via ESP32 GPIO through an optocoupler
(PC817 or similar) to avoid ground loop issues between the ESP and vent PSU.

This keeps the original vent PCB intact and active — the ESP just "presses" the buttons digitally.

For open/close lid position feedback: add a small **reed switch + magnet** to the lid mechanism
and wire to an ESP32 binary sensor input. This gives HA a `cover` entity with real open/closed state.

---

## Limitations and Notes

- **No state feedback via RF** — HA does not know the current fan speed or whether the lid is open;
  it only sends commands. Use wired reed switch if position feedback is required.
- **Rain sensor** on the vent operates independently at hardware level — it will still auto-close
  in rain regardless of HA commands (this is the desired safe-default behavior).
- **Range**: FS1000A at 5V achieves ~10–30 m line-of-sight inside a metal van body; more than
  sufficient for a van interior.
- **Interference**: The 433 MHz band is shared (door openers, tyre sensors, weather stations).
  The `repeat: 5` transmit count and EV1527 address matching at the receiver side make false
  triggers extremely unlikely.
