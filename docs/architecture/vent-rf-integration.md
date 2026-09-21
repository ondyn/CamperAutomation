# Roof Vent RF Investigation and Integration Plan

## Device Identification

The installed unit is a **CE-marked 12V roof vent fan** (common Chinese OEM, sold under various brands —
WC-1200, Heng Long, Camplux variants, etc.). Key observable features:

- Clear plastic fan blades, ~400 mm square plastic frame
- Rain sensor dome on inner frame
- 12V DC supply (red/white wire pair visible at frame edge)
- Wireless remote with a re-pair procedure: *hold POWER + RAIN SENSOR button on the vent for 4 s*

## Investigation Status

The pairing procedure originally suggested an EV1527-style fixed-code remote, but pairing behaviour
alone does not identify the carrier frequency or modulation. No protocol has been captured yet, so
claims about EV1527, encryption, directionality and replayability remain unproven.

| Band | Test method | Result |
|---|---|---|
| 433.92 MHz | MX-RM-5V receiver with `vent-sniffer.yaml`; separate EV1527 TX/RX loopback configs are available to validate the test rig | No repeatable remote-correlated code or signal |
| 315 MHz | Prior receiver test; exact setup not recorded in this repository | No repeatable remote-correlated code or signal |
| 2.4 GHz | nRF24L01 RPD sweep over 2400-2525 MHz with marked remote-button windows | No remote-correlated narrow-band activity |
| 868 MHz | Not tested | **Next test** |

Negative results apply to the tested hardware and method. They become strong exclusions only when the
receiver is validated with a known transmitter on the same band. The 2.4 GHz scan is considered
negative after repeated marked windows differed no more than the Wi-Fi/BLE baseline.

## Next Test: 868 MHz

### Recommended equipment: RTL-SDR

Use an RTL-SDR Blog V3/V4 or another genuine RTL2832U/R820T2 dongle with an antenna suitable for
868 MHz. An SDR is preferable to a cheap 868 MHz ASK receiver because it shows OOK, 2-FSK, GFSK and
other modulation without knowing the protocol first.

- Use an approximately **8.6 cm** straight quarter-wave antenna, calculated as
  $c / (4f)$ at 868 MHz, or a commercial 868 MHz antenna.
- Keep the remote 0.5-2 m from the antenna. Very close placement can overload the SDR frontend and
  make one signal appear across much of the spectrum.
- Disconnect or switch off unrelated 868 MHz devices where practical.

#### Visual waterfall test

1. Connect the RTL-SDR directly to the Mac and open SDR++ or another waterfall application.
2. Use NFM or raw spectrum view, maximum reliable sample rate (usually 2.4 MS/s), manual gain around
  20-30 dB, and disable AGC.
3. Cover the complete European SRD band in three views:
  - centre 864.2 MHz: approximately 863.0-865.4 MHz
  - centre 866.6 MHz: approximately 865.4-867.8 MHz
  - centre 869.0 MHz: approximately 867.8-870.2 MHz
4. At each centre frequency, observe an idle baseline, then press every remote button repeatedly for
  at least 10 seconds.
5. Record the exact frequency, occupied bandwidth and whether every press produces the same burst.

A valid candidate is a burst that appears at one stable frequency on repeated button presses and is
absent while idle. A continuously present carrier or activity unrelated to button timing is ambient
traffic, not evidence from the remote.

#### Command-line confirmation

On macOS, `rtl-sdr` and `rtl_433` can be installed with Homebrew. First verify the dongle:

```sh
brew install rtl-sdr rtl_433
rtl_test -t
```

After the waterfall identifies a frequency, replace `868.300M` below with the measured value:

```sh
rtl_433 -f 868.300M -s 1024k -g 25 -M level -A
```

`rtl_433` may name a known protocol. If it reports only pulse timings, those are still useful: save
several presses of each button and compare the repeated bit/pulse structure. Do not conclude that the
remote is absent merely because `rtl_433` cannot decode it; the waterfall is the carrier test.

### Embedded fallback: CC1101

If an SDR is unavailable, use a **CC1101 module whose RF matching network and antenna are built for
868/915 MHz**, not a 433 MHz CC1101 board. Connect it to a spare ESP32-C3 over SPI and sweep RSSI from
863 to 870 MHz while pressing the remote. This can detect OOK and FSK, but it requires custom scanner
firmware and gives less diagnostic information than a waterfall. Once an active frequency is known,
configure the CC1101 for that centre frequency and expose its asynchronous demodulated output to a
GPIO for pulse capture.

The CC1101 can reuse the nRF24 scanner's C3 SPI pins:

| CC1101 pin | ESP32-C3 mini pin | Note |
|---|---|---|
| VCC | 3V3 | Never connect to 5 V |
| GND | GND | Common ground |
| CSN | GPIO7 | SPI chip select |
| SCK | GPIO4 | SPI clock |
| MOSI | GPIO6 | SPI controller to CC1101 |
| MISO | GPIO5 | CC1101 to SPI controller |
| GDO0 | GPIO3 | Optional asynchronous packet/pulse output |
| GDO2 | Unconnected | Not needed for the initial RSSI sweep |

Avoid simple RXB6/MX-RM-style 868 MHz receivers as the first 868 MHz test. They are useful only for
ASK/OOK and a negative result would not rule out an FSK remote.

## Integration Options After Capture

| Approach | Effort | Reliability | Invasiveness |
|---|---|---|---|
| **RF replay via ESP32 + TX module** | Low | High (no state feedback) | None — non-invasive |
| **Wire to PCB button pads** | Medium | High | Low — solder only, leave PCB intact |
| **Replace control board** | High | Very high (full PWM control) | High — invasive |

**Recommended path:** identify the 868 MHz carrier and modulation first. RF replay is viable only
after repeatable packets are captured. Add wired button-pad tapping if RF remains unidentified or
state feedback is required.

---

## Historical 433 MHz Attempt

The remainder of this 433 MHz section is retained as a record and as a reusable test setup. It is
not the current integration plan because the vent remote was not detected in this band.

### Hardware Required

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

### Phase 1 — Capture Remote Codes

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

### Phase 2 — Transmit Config (replaces sniffer)

After capturing all codes, create the final ESPHome config. Replace placeholder `'YOUR_CODE_HERE'`
strings with the actual captured codes.

Proposed file (not yet created): **`esphome/config-esp/vent-remote.yaml`**

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

## Home Assistant Integration After Protocol Capture

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

## Optional: Wired Button-Pad Control

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
