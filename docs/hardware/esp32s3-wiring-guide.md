# ESP32-S3-DevKitC-1 N16R8 — Camper Automation Wiring Guide

Board: **ESP32-S3-DevKitC-1 N16R8** (ESP32-S3-WROOM-1**U**, external IPEX antenna)
Flash: 16 MB quad · PSRAM: 8 MB octal · Logic level: **3.3 V**
ESPHome config: `esphome/config-esp/esphymer.yaml`
Power rails: **5 V** (USB / VIN pin), **3.3 V** (onboard LDO), **GND**

> **IPEX/U.FL antenna is mandatory.** The `-1U` module has no PCB antenna. Without the
> pigtail attached the radio scans and finds **zero** networks — it does not fall back to
> a chip antenna.

---

## Reserved / Do-Not-Use Pins

| GPIO         | Reserved for                          | Consequence if used                         |
|--------------|---------------------------------------|---------------------------------------------|
| 26–32        | On-module SPI flash                    | Board will not boot                         |
| 33–37        | On-module octal PSRAM (R8)             | PSRAM fails / random crashes                |
| 43, 44       | UART0 TX/RX → onboard CH343 USB bridge | Loses serial console & flashing/log path    |
| 19, 20       | Native USB D− / D+ (USB-OTG / JTAG)    | Loses native-USB port                       |
| 0            | BOOT strapping + BOOT button           | Held low at reset → enters download mode    |
| 3            | JTAG source strapping                  | Affects debug mode selection at reset       |
| 45           | VDD_SPI voltage strapping              | Wrong flash voltage → brick-on-boot risk    |
| 46           | ROM-message strapping, boot-time pull  | Unreliable boot / glitch on the pin         |
| 38 (or 48)   | Onboard WS2812 RGB LED                 | Board revision dependent (v1.1 = 38, v1.0 = 48) |

Usable, unconstrained: **GPIO1–18, 21, 39–42, 47** (plus whichever of 38/48 the LED does not use).

---

## Assigned Pin Map

| GPIO   | Dir    | Function                       | Peripheral                          | Notes                                        |
|--------|--------|--------------------------------|-------------------------------------|----------------------------------------------|
| GPIO4  | IN     | PIR motion                     | HC-SR501 OUT                        | RTC pin → usable as deep-sleep wake source   |
| GPIO5  | IN     | Rain board analog out          | FC-37 / YL-83 AO                    | ADC1_CH4, 12 dB attenuation                  |
| GPIO8  | I/O    | I2C SDA                        | BME280 0x76, INA219 0x40, VL6180X 0x29 | Shared bus `bus_a`                        |
| GPIO9  | I/O    | I2C SCL                        | same bus                            |                                              |
| GPIO10 | IN/OD  | 1-Wire data                    | DS18B20 ×3                          | 4.7 kΩ pull-up to 3.3 V required             |
| GPIO11 | OUT    | Fresh water probe common       | Fresh tank probe rail               | Pulsed HIGH ~25 ms per sample (anti-corrosion)|
| GPIO12 | IN     | Fresh water 25 %               | Probe electrode                     | Internal pull-down                           |
| GPIO13 | IN     | Fresh water 50 %               | Probe electrode                     | Internal pull-down                           |
| GPIO14 | IN     | Fresh water 75 %               | Probe electrode                     | Internal pull-down                           |
| GPIO15 | IN     | Fresh water 100 %              | Probe electrode                     | Internal pull-down                           |
| GPIO16 | OUT    | Phone charger control          | P-MOS + PC817 optocoupler           | `inverted: true`, fail-safe OFF at reset     |
| GPIO17 | OUT    | LIN UART TX → transceiver RXD  | Truma iNetBox                       | UART1, 9600 8N2                              |
| GPIO18 | IN     | LIN UART RX ← transceiver TXD  | Truma iNetBox                       |                                              |
| GPIO21 | OUT    | Waste water probe common       | Waste tank probe rail               | Pulsed HIGH ~25 ms per sample                |
| GPIO39 | IN     | Waste water 25 %               | Probe electrode                     | JTAG MTCK, free as GPIO                      |
| GPIO40 | IN     | Waste water 50 %               | Probe electrode                     | JTAG MTDO, free as GPIO                      |
| GPIO41 | IN     | Waste water 75 %               | Probe electrode                     | JTAG MTDI, free as GPIO                      |
| GPIO42 | IN     | Waste water 100 %              | Probe electrode                     | JTAG MTMS, free as GPIO                      |
| GPIO48 | OUT    | Onboard WS2812 status LED      | On-module RGB LED                   | v1.0 = 48, v1.1 = 38 — `status_led_pin` sub  |
| GPIO43 | OUT    | Console TX (logger)            | CH343 bridge                        | Reserved                                     |
| GPIO44 | IN     | Console RX                     | CH343 bridge                        | Reserved                                     |

**Free for expansion:** GPIO1, 2, 6, 7 (all ADC1 — kept free for analog inputs),
GPIO47, and GPIO38 (if the RGB LED is on 48).

### Why this distribution

- **ADC1 = GPIO1–10.** ADC2 is unusable while Wi-Fi is active, so ADC1 is the only analog
  resource on this chip. Every purely digital function was pushed to GPIO11+ so that
  GPIO1, 2, 6, 7 stay free for further analog sensors; the rain board took GPIO5 because it
  is the one peripheral here that genuinely needs an ADC.
- **I2C on 8/9 and 1-Wire on 10** are kept from the ESP32-C3 build so existing harnesses,
  pull-ups and the DS18B20 addresses in the config need no rework.
- **LIN moved off UART0.** On the C3 the LIN bus sat on GPIO20/21, which *is* UART0 — that
  is why `logger:` had to be disabled there. On the S3 the LIN bus uses UART1 on GPIO17/18,
  so the serial console and remote debugging are available again.
- **Each tank gets a contiguous block** (fresh 11–15, waste 21 + 39–42) — one 5-way connector
  and one ribbon run per tank. Waste sits on the JTAG-capable pins because those carry no
  ADC and no boot-time function: the least valuable pins go to the least demanding load.
- **Actuator (GPIO16) sits next to the LIN pins**, away from the input blocks, to keep the
  switched charger line physically separate from the high-impedance probe inputs.
- **All strapping pins are left unloaded**, so the board always boots even with the harness
  attached — important for an unattended camper install.
- **MPU6050 is not fitted.** Pitch/roll levelling comes from the phone's own IMU.

---

## Enabling / Disabling Subsystems

ESPHome has no in-file conditionals, so each peripheral lives in its own file under
`esphome/config-esp/peripherals/` and is switched on by a line in the `packages:` block at
the top of `esphymer.yaml`. Comment the line out and that subsystem — pins, entities and
drivers — disappears from the build entirely.

```yaml
packages:
  temperature:   !include peripherals/temperature_dallas.yaml
  bme280:        !include peripherals/bme280.yaml
  truma:         !include peripherals/truma.yaml
  pir:           !include peripherals/pir.yaml
  phone_charger: !include peripherals/phone_charger.yaml
  battery:       !include peripherals/battery_ina219.yaml
  rain:          !include peripherals/rain.yaml
  # range:       !include peripherals/range_vl6180x.yaml
```

Both water tanks share one parameterised file, included twice with different `vars:`
(`tank_id`, `tank_name`, and the five pins). Adding a third tank is a copy of that block.

Each peripheral file also registers its own components with the shared fault collector, so
`sensor.esphymer_device_status` automatically covers exactly the subsystems that are
enabled — no bookkeeping in the core file when something is switched off.

---

## Feature 1 — DS18B20 One-Wire Temperature Sensors (×3)

- Sensors wired in parallel on a single data wire; **one** 4.7 kΩ pull-up between DATA and 3.3 V.
- Normal (non-parasitic) power mode recommended.

```
ESP32-S3-DevKitC-1        DS18B20 (×3, parallel)
──────────────────         ──────────────────────────
3.3V ─────────────────────── VCC (pin 3)
                 │
              4.7 kΩ
                 │
GPIO10 ──────────┴────────── DATA (pin 2)
GND ──────────────────────── GND (pin 1)
```

Flat-face DS18B20 (flat side towards you): `[GND] [DATA] [VCC]`

```yaml
one_wire:
  - platform: gpio
    pin:
      number: GPIO10
      mode:
        input: true
        pullup: true
    id: bus_b
```

---

## Feature 2 — Truma iNetBox via LIN-to-UART Converter

The iNetBox speaks LIN (single wire, 12 V). A LIN transceiver (MCP2003B, TJA1020, …)
bridges it to 3.3 V UART.

```
Van 12 V ─────────────────── VBAT (LIN side supply)
LIN bus wire ─────────────── LIN
LIN GND ──────────────────── GND (common with ESP GND)

3.3V ─────────────────────── VCC (logic side)
GPIO17 (ESP TX) ──────────── RXD
GPIO18 (ESP RX) ──────────── TXD
GND ──────────────────────── GND
```

> **CRITICAL:** the UART side must be 3.3 V logic. A 5 V-only converter needs a level shifter.

> **Polarity:** some adapters label TXD/RXD from the module's point of view
> (module TXD = ESP RX = GPIO18). Verify against your board.

```yaml
uart:
  - id: lin_uart_bus
    tx_pin: GPIO17
    rx_pin: GPIO18
    baud_rate: 9600
    stop_bits: 2

truma_inetbox:
  uart_id: lin_uart_bus
```

---

## Feature 3 — PIR Motion Sensor (HC-SR501)

- Supply **5 V** (4.5–20 V; do *not* use 3.3 V). OUT swings to ~3.3 V — safe for the ESP.
- ~30–60 s warm-up after power-on; may trigger falsely during that window.

```
ESP32-S3-DevKitC-1        HC-SR501
──────────────────         ──────────────────────────
5V ────────────────────── VCC  (middle pin / +)
GPIO4 ─────────────────── OUT  (signal)
GND ───────────────────── GND  (– pin)
```

Pinout with dome facing you: `[GND] [OUT] [VCC]`

---

## Feature 4 — Fresh / Waste Water Level (4-step conductive probes)

Each tank has four stainless electrodes at 25 / 50 / 75 / 100 % height plus one common
electrode at the bottom. The common electrode is driven HIGH only for ~25 ms during a
sample, then returned LOW — this avoids continuous DC through the water and the resulting
electrolysis and electrode corrosion. The two tanks are sampled sequentially so the rails
cannot couple through the van chassis.

```
ESP32-S3-DevKitC-1        Fresh tank            Waste tank
──────────────────         ─────────────         ─────────────
GPIO11 ────────────────── Common (bottom)
GPIO12 ────────────────── 25 %
GPIO13 ────────────────── 50 %
GPIO14 ────────────────── 75 %
GPIO15 ────────────────── 100 %
GPIO21 ─────────────────────────────────────── Common (bottom)
GPIO39 ─────────────────────────────────────── 25 %
GPIO40 ─────────────────────────────────────── 50 %
GPIO41 ─────────────────────────────────────── 75 %
GPIO42 ─────────────────────────────────────── 100 %
```

- No external resistors required — the level inputs use internal pull-downs, so an
  uncovered electrode reads LOW.
- Keep probe wiring away from the LIN and charger lines; long runs pick up noise on
  high-impedance inputs.
- Sampling is driven by `script: sample_water_levels` (1 s interval, on boot, and on
  HA client connect).

---

## Feature 5 — Onboard RGB Status LED

The WS2812 on the dev kit is the local health indicator. It is **internal** in ESPHome —
the pattern generator owns it, and Home Assistant steers it through two entities rather
than writing colours directly.

| Source | State                    | Colour  | Pattern                             |
|--------|--------------------------|---------|-------------------------------------|
| ESP    | connecting to Wi-Fi      | violet  | fast blink (200 ms on / 200 ms off) |
| ESP    | Wi-Fi up, no HA API      | blue    | fast blink                          |
| ESP    | component error          | red     | fast blink                          |
| ESP    | component warning        | amber   | fast blink                          |
| HA     | notification `Info`      | cyan    | slow blink (1 s on / 1 s off)       |
| HA     | notification `Warning`   | amber   | slow blink                          |
| HA     | notification `Alert`     | orange  | slow blink                          |
| HA     | notification `Critical`  | magenta | slow blink                          |
| ESP    | everything OK            | green   | slow breathe (~4 s period)          |

**Fast blink = the node is reporting. Slow blink = Home Assistant is reporting.**
Device-level faults (no Wi-Fi, no API, component error) outrank HA notifications, because
a stale HA notification is meaningless when the link is down.

HA-facing entities:

- `select.esphymer_status_led_notification` — `None` / `Info` / `Warning` / `Alert` / `Critical`.
  Set it from an automation, e.g. charger monitor stale → `Warning`, battery SoC low → `Alert`.
- `number.esphymer_status_led_brightness` — 0–100 %, scales every pattern. Drive it from a
  sun/time automation to dim the LED at night; `0` turns the LED off completely.

> **Board revision:** DevKitC-1 v1.0 wires the LED to GPIO48, v1.1 to GPIO38. The pin is the
> `status_led_pin` substitution at the top of `esphymer.yaml` — flip it if the LED stays dark.

### Remote diagnostics

The LED tells you *that* something is wrong; these two entities tell you *what*, without a
serial console:

- `sensor.esphymer_device_status` — human-readable fault list, refreshed every 10 s, e.g.
  `BME280: FAILED, T1: warning, T2: warning, T3: warning`, or `OK` when everything is healthy.
  Covers the I2C bus, BME280, 1-Wire bus, T1–T3, the LIN UART and the Truma component.
- `binary_sensor.esphymer_device_problem` — `on` whenever any component reports a warning or
  error. Use it as the automation trigger; read the text sensor for the detail.

---

## Feature 6 — BME280 (Temperature / Humidity / Pressure)

- 3.3 V, I2C address **0x76** (SDO → GND). CSB tied HIGH forces I2C mode.

```
3.3V ──────────────────── VCC          GND ─────────── SDO  → 0x76
GND ───────────────────── GND          3.3V ────────── CSB  → I2C mode
GPIO8 (SDA) ───────────── SDA
GPIO9 (SCL) ───────────── SCL
```

---


## Feature 7 — Phone Charging Control (P-MOS + PC817 optocoupler)

Switches the charger feed to the phone that runs Home Assistant.

```
ESP32-S3-DevKitC-1        P-MOS board (opto-isolated)
──────────────────         ──────────────────────────
GPIO16 ────────────────── IN  (opto LED, via onboard series resistor)
GND ───────────────────── GND (logic side)

+12V / +5V ────────────── VIN  (charger supply in)
P-MOS drain ───────────►  Phone charger USB (+)
GND ───────────────────── Phone charger USB GND
```

> **Fail-safe is ON, not OFF.** The phone runs Home Assistant, so the charger must stay
> powered whenever the node cannot be told otherwise. The switch uses
> `restore_mode: ALWAYS_ON`, and a 5 s interval re-asserts ON whenever no Home Assistant
> client is subscribed to state. Only a connected HA can switch it off.

> ⚠ **Check the pre-boot window in hardware.** Between power-on and ESPHome setup
> (~1 s) GPIO16 is Hi-Z, so the charger state is decided by the driver board, not by
> firmware. With the active-LOW drive used here (`inverted: true`), fit a pull-down
> (≈10 kΩ from IN to GND) so a floating pin means *charging*. Verify with a meter
> before trusting it — some P-MOS boards already pull their input the other way.

---

## Feature 8 — INA219 Battery Monitor (bi-directional, external shunt)

High-side monitor on the leisure battery. Current and power are **signed**: positive while
charging, negative while the battery discharges.

```
ESP32-S3-DevKitC-1        INA219 breakout            Battery circuit
──────────────────         ─────────────────          ───────────────
3.3V ─────────────────────── VCC
GND ──────────────────────── GND  (must be battery negative)
GPIO8 (SDA) ───────────── SDA
GPIO9 (SCL) ───────────── SCL
                          VIN+ ──────────────── shunt terminal A (battery +)
                          VIN− ──────────────── shunt terminal B (load / charger)
```

> **Set `shunt_resistance` to match your shunt** in `peripherals/battery_ina219.yaml`.
> `0.1 ohm` is the resistor fitted on the breakout itself; a 75 mV/100 A bar shunt is
> `0.00075 ohm`, a 75 mV/50 A shunt is `0.0015 ohm`. Getting this wrong scales every
> current and power reading by the same factor.

> **A0/A1 address straps** select 0x40–0x4F. The config expects the default **0x40**
> (both straps to GND).

> ⚠ The INA219 is only rated to 26 V bus voltage. It suits a 12 V system directly; do not
> put it across a 24 V bank without checking the margin.

---

## Feature 9 — Rain Detector (analog, HA-settable threshold)

A resistive rain board (FC-37 / YL-83 style) read as a voltage on ADC1. The comparison
threshold lives in Home Assistant, so sensitivity is tuned from the UI without reflashing.

```
ESP32-S3-DevKitC-1        Rain board (comparator module)
──────────────────         ─────────────────────────
3.3V ─────────────────────── VCC   (3.3 V — keeps AO inside the ADC range)
GND ──────────────────────── GND
GPIO5 ───────────────────── AO    (analog out; DO is unused)
```

- `sensor.esphymer_rain_sensor_voltage` — raw plate voltage, median-filtered.
- `number.esphymer_rain_threshold` — trip point in volts, restored across reboots.
- `binary_sensor.esphymer_rain_detected` — wet/dry, with 20 s on-delay and 5 min off-delay
  so a splash does not toggle it and a passing shower does not immediately clear.

> **Polarity:** wet plates conduct and pull AO *down*, so "wet" means below the threshold.
> If your board rises when wet, set `rain_wet_below: "false"` at the top of
> `peripherals/rain.yaml`.

> Power the plate from 3.3 V, not 5 V — the ESP32-S3 ADC tops out around 3.1 V even at
> 12 dB attenuation, and the GPIOs are not 5 V tolerant.

---

## Feature 10 — VL6180X Time-of-Flight Range Sensor

Short-range (0–200 mm) ToF distance plus ambient light, on the shared I2C bus at 0x29.
Disabled in `packages:` until it is physically wired.

```
ESP32-S3-DevKitC-1        VL6180X breakout
──────────────────         ─────────────────────────
3.3V ─────────────────────── VIN / 3V3
GND ──────────────────────── GND
GPIO8 (SDA) ───────────── SDA
GPIO9 (SCL) ───────────── SCL
(unconnected) ─────────── CE / XSHUT  (breakouts pull it up; only needed for >1 sensor)
```

> **Third-party component.** `vl6180x` is not part of ESPHome; it is pulled from
> `thedayowl/esphome-vl6180x` and **pinned to commit `3edff0aa`** so an upstream change
> cannot silently enter the build. Review the diff before moving the pin. Range is only
> 0–200 mm — for tank-depth use, VL53L0X (≈120 cm) is the better part.

---

## I2C Bus Summary

SDA = GPIO8, SCL = GPIO9 (internal pull-ups enabled by ESPHome; add 4.7 kΩ externals if the
harness is longer than ~30 cm).

| Device   | Address | Feature                         |
|----------|---------|---------------------------------|
| BME280   | 0x76    | Temp / humidity / pressure      |
| INA219   | 0x40    | Battery voltage / current / power |
| VL6180X  | 0x29    | Time-of-flight range + lux      |

---

## Power Supply Overview

| Rail  | Source          | Used by                                        |
|-------|-----------------|------------------------------------------------|
| 5 V   | USB / VIN pin   | HC-SR501 VCC                                   |
| 3.3 V | Onboard LDO     | BME280, INA219, VL6180X, rain board, DS18B20, LIN logic side |
| GND   | Common          | everything                                     |
| 12 V  | Van battery     | LIN transceiver bus side, P-MOS load, INA219 shunt |

> The ESP32-S3 with Wi-Fi + PSRAM draws noticeably more than the C3 (peaks ~350–500 mA on
> TX bursts). Feed the board from a supply good for **≥1 A** and add a 470 µF bulk capacitor
> at the 5 V input if it is fed over a long cable run — brownouts show up as random reboots.

---

## Pull-up / Pull-down Summary

| Signal        | GPIO       | External resistor | Value   | Between            |
|---------------|------------|-------------------|---------|--------------------|
| DS18B20 data  | GPIO10     | Recommended       | 4.7 kΩ  | GPIO10 ↔ 3.3 V     |
| I2C SDA/SCL   | GPIO8/9    | Internal (ESPHome)| ~4.7 kΩ | auto               |
| Water probes  | GPIO12–15  | Internal pull-down| —       | auto               |
| PIR OUT       | GPIO4      | None              | —       | actively driven    |
| Charger ctrl  | GPIO16     | On P-MOS board    | —       | —                  |

---

## Validation Checklist

- [ ] IPEX antenna attached; ESPHome log shows the camper SSID in scan results
- [ ] `esphome logs` over UART0 works (logger on GPIO43/44)
- [ ] Onboard RGB LED lights (if dark, flip `status_led_pin` between GPIO48 and GPIO38)
- [ ] I2C scan lists 0x76 (and 0x40 / 0x29 once those boards are fitted)
- [ ] Three DS18B20 addresses discovered; T1/T2/T3 report plausible °C
- [ ] `CP Plus alive` = ON and Truma room/water temperatures populate
- [ ] PIR toggles on hand wave
- [ ] Fresh and Waste Water Level step 0 → 25 → 50 → 75 → 100 % as electrodes are shorted to common
- [ ] Phone Charger switch toggles the load and is OFF after a reboot
- [ ] Battery Current is negative under load and positive while charging
- [ ] Rain Detected flips when the plate is wetted; tune `Rain Threshold` from HA
- [ ] Status LED breathes green once everything is healthy
- [ ] Setting `Status LED Notification` in HA switches the LED to a slow blink
- [ ] `sensor.esphymer_device_status` reads `OK`
- [ ] Device appears in Home Assistant at 10.129.28.200 with all entities

---

## Troubleshooting Notes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `No networks found` on every scan | IPEX antenna not attached to the `-1U` module | Seat the U.FL pigtail until it clicks |
| Board boots to download mode | Something pulls GPIO0 low | Free GPIO0; it is the BOOT strap |
| Random crashes after adding PSRAM | Harness on GPIO33–37 | Those pins belong to the octal PSRAM |
| No serial log output | Logger left on the S3 default `USB_SERIAL_JTAG` while using the CH343 port | Keep `hardware_uart: UART0` |
| DS18B20 reads −127 °C | Missing/wrong pull-up | 4.7 kΩ between GPIO10 and 3.3 V |
| Truma shows no data | LIN wiring/level or swapped TX/RX | Verify 9600 8N2 and transceiver polarity |
| PIR always ON | Powered from 3.3 V | Move VCC to the 5 V rail |
| Water level stuck at 0 % | Common probe not driven or electrodes not wetted | Check GPIO11 wiring and probe continuity |
| Charger always ON | Inverted logic mismatch | Check opto polarity / drop `inverted: true` |
