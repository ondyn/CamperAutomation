# ESP32-S3-DevKitC-1 N16R8 — Camper Automation Wiring Guide

Board: **ESP32-S3-DevKitC-1 N16R8** (ESP32-S3-WROOM-1**U**, external IPEX antenna)
Flash: 16 MB quad · PSRAM: 8 MB octal · Logic level: **3.3 V**
ESPHome config: `esphome/config-esp/esphymer.yaml`
Power rails: **5 V** (USB / VIN pin), **3.3 V** (onboard LDO), **GND**

This ESP32-S3 node keeps the Truma, actuators, tank probes, PIR, rain sensor and **T1**
DS18B20. BME280, INA219, VL6180X, starter battery voltage, engine D+ and the other two DS18B20 sensors are on a
separate ESP32-C3 Super Mini configured in `esphome/config-esp/esphymer2.yaml`. This
reuses the existing nRF24 roof-vent controller board, now extended with sensors;
there is no separate `vent-remote` board. It uses 10.129.28.205; see
[the second-node section](#second-node--esp32-c3-super-mini).

> **IPEX/U.FL antenna is mandatory.** The `-1U` module has no PCB antenna. Without the
> pigtail attached the radio scans and finds **zero** networks — it does not fall back to
> a chip antenna.

> Pin assignments below are cross-checked against Espressif's official ESP32-S3-DevKitC-1
> schematic (`02_ESP32-S3-DevKitC-1` sheet) and pinout diagram: J1/J3 headers expose
> GPIO0–21, 35–48 only — **GPIO22–25 do not exist on the chip**, and GPIO26–34 are wired
> internally to the module's flash/PSRAM only, never brought to a header pin.

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
| GPIO10 | IN/OD  | 1-Wire data                    | DS18B20 T1                         | 4.7 kΩ pull-up to 3.3 V recommended          |
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

**Free for expansion:** GPIO8, GPIO9 and GPIO20 are unused by this node because I2C and
engine D+ moved to esphymer2. GPIO20 is still native USB D+; reusing it disables that
interface. GPIO1, 2, 6, 7, GPIO47 and GPIO38 (the alternate RGB LED pin when the LED uses
GPIO48) remain assigned below.

| GPIO   | Dir    | Function                       | Peripheral                          | Notes                                        |
|--------|--------|---------------------------------|--------------------------------------|----------------------------------------------|
| GPIO1  | IN     | Gas bottle primary/secondary    | Mechanical switch to GND             | Internal pull-up; LOW = primary/interconnected |
| GPIO2  | IN     | 12V supply present              | Optocoupler                          | Internal pull-down                           |
| GPIO6  | IN     | Mains 230V connected            | Optocoupler (12 V signal)            | Internal pull-down                           |
| GPIO7  | OUT    | Gas valve heater                | N-MOS + optocoupler                  | Fail-safe OFF at reset                       |
| GPIO19 | OUT    | EBL30 "turn OFF" pulse (A12)    | N-MOS + optocoupler                  | Native-USB D-, repurposed — see caveat below |
| GPIO38 | OUT    | EBL30 "turn ON" pulse (A11)     | N-MOS + optocoupler                  | Free only while status LED is on GPIO48      |
| GPIO47 | OUT    | Water pump enable               | N-MOS + optocoupler, active-low      | `inverted: true`, fail-safe OFF at reset     |

## Second node — ESP32-C3 Super Mini

The second node separates the I2C sensors, starter battery voltage, engine-running signal and two remaining
DS18B20s from the ESP32-S3 harness, and also controls the roof vent using the existing
nRF24L01(+) transmitter. Config: `esphome/config-esp/esphymer2.yaml`, board definition
`lolin_c3_mini`, ESP-IDF 6.0.1 (same as the former vent configuration). The physical
board is the existing **ESP32-C3 Super Mini**, not an ESP8266 or ESP32-S3.

| ESPHome GPIO / rail | Function | Wiring |
|--------------------|----------|--------|
| GPIO0 | I2C SDA | BME280, INA219, INA226 and VL6180X shared bus |
| GPIO1 | I2C SCL | Same shared bus; pull-ups only to 3.3 V |
| GPIO3 | nRF24 CE | Radio header pin 3 |
| GPIO4 | nRF24 SCK | Radio header pin 5 |
| GPIO5 | nRF24 MISO | Radio header pin 7 |
| GPIO6 | nRF24 MOSI | Radio header pin 6 |
| GPIO7 | nRF24 CSN | Radio header pin 4 |
| GPIO8 | Onboard TX LED | Existing active-low Super Mini LED; boot strap, no external load |
| GPIO10 | 1-Wire data | DS18B20 T2 and T3 in parallel; 4.7 kOhm pull-up to 3.3 V |
| GPIO20 | Engine running (alternator D+) | Optocoupler collector; active-low input with pull-up; emitter to GND |
| GPIO18 / GPIO19 | Native USB | Reserved for flashing and `USB_SERIAL_JTAG` logging |
| GPIO2 / GPIO9 | Boot straps | Leave unloaded; GPIO9 is the BOOT button |
| GPIO21 | Spare | Do not attach a UART0 adapter while GPIO20 is used for D+ |
| 3V3 / GND | Sensor and radio supply | Radio pin 2 = 3V3, pin 1 = GND; use 3.3 V-compatible breakouts |

The nRF24 IRQ (pin 8) stays disconnected. Fit **10 uF plus 100 nF** directly across
the radio VCC/GND pins; never power the nRF24 from 5 V. The existing radio harness
on GPIO3-7 stays unchanged; no ESPHome `spi:` bus is needed because the vent driver
uses bit-banged SPI. GPIO4/5 are **not** available for I2C on this combined board.
If using a PA/LNA radio module, provide its own adequately rated 3.3 V regulator.

Connect D+ only through the optocoupler interface, never directly to an ESP GPIO.
GPIO20 is C3 UART0 RX, so the logger explicitly uses native USB instead of UART0.
This C3 pin map is independent of the S3 pin map above: GPIO0 is not a C3 boot strap.
The node uses static IP `10.129.28.205`; `.204` is retired from vent control.

### Roof vent and migration

`peripherals/vent_remote.yaml` retains the paired remote ID, four-channel hopping,
10-round transmissions, 10 fan speeds, direction, power, lid open/close/stop and rain
enable from the previous controller. Commands are ignored during the initial 5 s
after radio setup; no command or state restoration moves the vent at boot.
The protocol and initial radio testing are in
[the vent integration guide](../architecture/vent-rf-integration.md).

1. Save the existing controller firmware/config and record Home Assistant entity
   references before changing the board. Preserve the radio GPIO3-7 wiring.
2. Wire I2C to GPIO0/1, T2/T3 to GPIO10 and the D+ optocoupler to GPIO20.
   Do not reuse the former ESP8266 GPIO14/12 harness or GPIO4/5 I2C assignments.
3. Validate/compile `esphymer2.yaml`, then **flash over USB** for the initial device
   rename/platform migration. Verify native USB logging and radio initialization
   before reconnecting vehicle sense leads.
4. Add/reconfigure **esphymer2 at 10.129.28.205** in Home Assistant. Remove the old
   `vent-remote` integration entry after testing; the IP-fixer no longer manages it.
   Update dashboard/automation references to `*_esphymer2_roof_vent_*` entity IDs
   (check the actual IDs assigned by HA). Commands remain one-way/assumed state;
   using the original remote can make HA's displayed state stale.
5. Verify sensor reporting while issuing vent commands and while reconnecting Wi-Fi.
   Reboot without commands and confirm the vent does not move.

To fall back, disconnect the added sensor/sense harness and restore the saved vent
firmware by USB. Restore its previous HA entry/IP only if reverting to that deployment.

### Starter battery voltage (8-15 V)

Enabled by `starter_battery: !include peripherals/starter_battery_voltage.yaml` in
`esphome/config-esp/esphymer2.yaml`. This adds **Starter Battery Voltage** to Home
Assistant without changing the separate INA219 **Battery Voltage** entity. Use a
preassembled **INA226 I2C voltage/current monitor breakout**, powered at **3.3 V**.
It reads bus voltage directly: **no A0 wiring, external divider, LM4040 or ADC
multiplier is needed**. The firmware polls every 5 s, with 16-conversion hardware
averaging and 1100 us ADC conversion time. This is a slow battery-health measurement,
**not** a recorder of cranking dips or automotive pulse peaks.

Set the INA226 to **0x41**, leaving the existing INA219 at **0x40**. On the INA226
chip, 0x41 means **A0 to VS (3.3 V), A1 to GND**; these address pins are unrelated
to any ESP analog-input pin. Breakout jumper labels differ, so check the board schematic
and remove conflicting default bridges before soldering the address selection.
Confirm 0x41 in the ESPHome I2C scan.

#### Proposed protected sense circuit

This is a **voltage-sense lead only**, not the ESP's power supply. Use a separate,
automotive-protected 12 V-to-5 V converter for the C3. The module's **VCC/VS
must never connect to battery positive**. All grounds below join battery negative
at a quiet common point; this interface is not isolated.

The resistor limits transient current so the TVS does not have to absorb the vehicle's
full load-dump energy. This simplified circuit assumes correct polarity and **positive
transients only**. It has no reverse-blocking MOSFET or series diode.
**Negative pulses or reversed battery connections can damage the INA226**; even a
unidirectional TVS's forward clamp does not guarantee its -0.3 V input limit.

```text
Starter BAT+
     |
 F1 100 mA fuse (DC rated, installed close to battery)
     |
 R1 1 kOhm, 10 W, pulse-rated
     |
     +------ TVS1 unidirectional 18 V TVS ----- BAT- / GND
     |       cathode at sense node, anode at GND
     +--------------------------------------- INA226 IN+ / VIN+
     |
     +--------------------------------------- INA226 IN- / VIN-
     +--------------------------------------- INA226 VBUS, if separate
     +------ C1 100 nF, 50 V ----------------- GND

ESP 3V3 ------------------------------------- INA226 VCC / VS
ESP GND ------------------------------------- INA226 GND
ESP GPIO1 ----------------------------------- INA226 SCL
ESP GPIO0 ----------------------------------- INA226 SDA
BAT- ---------------------------------------- common GND
```

**Voltage only:** tie IN+ and IN- to the same protected sense node. If the module
exposes a separate VBUS terminal, tie that there too; otherwise verify VBUS is
already connected to IN- on the PCB. No load connects to these terminals.
**Never pass starter-motor current through the breakout's shunt.**

| Part | Selection / purpose |
|------|---------------------|
| F1 | 100 mA inline fuse, with DC voltage and interrupt ratings appropriate for a starter battery. Protects the sense cable; never rely on a PCB resistor to protect an unfused battery wire. |
| INA226 module | Preassembled breakout with accessible 0x41 address selection and schematic. Use 3.3 V VCC and I2C pull-ups. Avoid boards with a divider, indicator LED or other load on the measured bus unless its loading is accounted for. |
| R1 | 1 kOhm, 1%, 10 W, flameproof pulse-rated resistor, with >= 100 V working rating. Verify pulse energy and temperature derating. Do not reduce/remove it: TVS sizing depends on this current limiting. |
| TVS1 | **Unidirectional 18 V standoff**, e.g. SMBJ18A-class, preferably automotive-qualified. Cathode (banded end) to the sense node after R1; anode to GND. Select maximum specified clamp <= 30 V over the relevant pulse/temperature conditions. This is not reverse-polarity protection for the INA226. |
| C1 | 100 nF ceramic, >= 50 V, immediately between the protected sense node and GND. |

**Do not reuse the earlier 24 V TVS:** its clamp can exceed the INA226's **36 V
operating limit** (40 V absolute maximum is not a design target). A TVS's standoff
voltage is **not** its clamp voltage. Keep TVS and C1 ground returns short, and use
a twisted sense/ground pair away from starter/heater wiring.

**Example envelope, not certification:** for a +100 V pulse lasting 400 ms,
R1 current is bounded by 100 mA, resistor power by 10 W and energy by 4 J.
If TVS1 holds its node at or below +30 V, its worst positive-pulse dissipation for
this 1 kOhm feed is about `30 * (100 - 30) / 1000 = 2.1 W`, or 0.84 J over 400 ms.
Verify resistor and TVS ratings and pulse/temperature curves against the actual
installation. This envelope does not cover negative pulses or reverse polarity.

Fast edges and wiring inductance still require oscilloscope
verification: **all INA226 sense inputs must stay between -0.3 V and 36 V**.
This proposal does **not** establish ISO 7637-2 / ISO 16750-2 compliance. Larger or
repeated load dumps need revised protection or a qualified automotive input module.
Never test by disconnecting the battery while the engine runs. The circuit does
not protect the ESP's separate power input.

#### Accuracy, validation and calibration

The INA226 bus ADC has **1.25 mV resolution** and a specified bus-voltage gain error
up to **0.1%** under datasheet conditions. Resolution is not system accuracy.
The INA226's VBUS input loading, TVS leakage, breakout extras
and ground drops introduce an additional `R1 * total_sense_current` error:
10 uA means 0.01 V; 100 uA means 0.1 V. Do not load this sense node with an LED
or the ESP power supply. VBUS input impedance is typically 830 kOhm, so that input
alone causes about 0.018 V drop across R1 at 15 V. Verify the assembled circuit at 8, 12 and 15 V and at
relevant temperatures; aim for <= 0.1 V error before using battery warnings.

Only `bus_voltage` is exposed; shunt/current/power calibration is not used for
voltage scaling. No fixed multiplier or guessed diode-drop correction is applied.
Firmware rejects raw bus readings >= 18 V or negative values as `NaN`/unavailable,
logs a warning and sets **Starter Battery Voltage Out of Range**. This avoids
presenting a TVS-clamped reading as the actual battery voltage. The warning clears
on the next normal reading. An I2C fault appears as **Starter battery INA226** in
**Device Status**; after 20 s without readings, voltage becomes unavailable rather
than remaining stale. Readings below 8 V remain valid; a disconnected sense wire
cannot reliably be distinguished from a dead battery.

1. With the INA226 **disconnected**, use a current-limited bench supply on the
   protection assembly. At 8, 12 and 15 V verify the sense node follows the input
   with only the expected leakage-induced drop across R1. Check TVS polarity.
2. Test positive clamping on the assembly alone. A current-limited 30 V input
   should be clamped below 30 V. Do not apply reversed polarity with the INA226
   attached. Static tests do not prove fast transient protection.
3. Connect the INA226 and ESP, confirm I2C addresses **0x40 and 0x41**, and compare
   Home Assistant to a multimeter at the battery at 8, 12 and 15 V. Inspect the
   protected-node voltage too to distinguish sensor error from protection loading.
4. If calibration is needed, add `calibrate_linear` **after the range-check lambda
   and before `timeout`** in the package's `bus_voltage.filters`: map two measured
   uncorrected INA226 voltages to their multimeter battery voltages. Recheck the
   midpoint and temperature behavior; excessive/nonlinear loading is a hardware
   issue, not something to hide with a guessed constant.
5. Run `esphome config esphome/config-esp/esphymer2.yaml` and
   `esphome compile esphome/config-esp/esphymer2.yaml`, then flash and confirm the
   new entity plus the existing INA219, D+, I2C and temperature entities still work.
   Check that the overrange warning clears when normal voltage returns. Disconnect
   I2C (with power off before changing wiring) and verify the fault and 20 s voltage
   timeout after restarting; reconnect and verify recovery.

Maintain a common ground while connected; disconnect the fused sense lead before
unpowering/removing the node for service. To migrate from the previous A0 design,
disconnect the old A0 sense circuit entirely before connecting the INA226 harness.
To roll back, disconnect the fused sense lead and comment out the `starter_battery`
package, leaving the other peripherals unchanged.

References: [INA226 datasheet](https://www.ti.com/lit/ds/symlink/ina226.pdf),
[ESPHome INA226 support](https://esphome.io/components/sensor/ina226/),
[SMBJ TVS datasheet](https://www.vishay.com/docs/88392/smbj.pdf).

### Why this distribution

- **ADC1 = GPIO1–10.** ADC2 is unusable while Wi-Fi is active, so ADC1 is the only analog
  resource on this chip. Every purely digital function was pushed to GPIO11+ so that
  GPIO1, 2, 6, 7 stay free for further analog sensors; the rain board took GPIO5 because it
  is the one peripheral here that genuinely needs an ADC.
- **1-Wire on GPIO10** is kept from the ESP32-C3 build for T1; T2/T3 are on the separate
  C3 node.
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
`sensor.esphymer_device_status` covers the enabled ESP32-S3 subsystems. The second node has
its own `sensor.esphymer2_device_status`.

---

## Feature 1 — DS18B20 One-Wire Temperature Sensor (T1)

- T1 is the only DS18B20 on the ESP32-S3 node. T2 and T3 are connected in parallel to the
  separate C3 node (see [the second-node section](#second-node--esp32-c3-super-mini)).
- Use one 4.7 kΩ pull-up between DATA and 3.3 V on each node's 1-Wire bus.
- Normal (non-parasitic) power mode recommended.

```
ESP32-S3-DevKitC-1        DS18B20 T1
──────────────────         ──────────────────────────
3.3V ─────────────────────── VCC (pin 3)
GPIO10 ──────────────────── DATA (pin 2)
GND ──────────────────────── GND (pin 1)
3.3V ───── 4.7 kΩ ─────────┘
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

- `sensor.esphymer_device_status` — faults from T1, the LIN UART and Truma component.
- `sensor.esphymer2_device_status` — faults from the second node's I2C bus, BME280,
  INA219, starter battery INA226, T2 and T3.
- `binary_sensor.esphymer_device_problem` — `on` whenever any component reports a warning or
  error. Use it as the automation trigger; read the text sensor for the detail.

---

## Feature 6 — BME280 (Temperature / Humidity / Pressure, ESP32-C3)

- 3.3 V, I2C address **0x76** (SDO → GND). CSB tied HIGH forces I2C mode.

```
3.3V ──────────────────── VCC          GND ─────────── SDO  → 0x76
GND ───────────────────── GND          3.3V ────────── CSB  → I2C mode
GPIO0 (SDA) ───────────── SDA
GPIO1 (SCL) ───────────── SCL
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
ESP32-C3 Super Mini        INA219 breakout            Battery circuit
──────────────────         ─────────────────          ───────────────
3.3V ─────────────────────── VCC
GND ──────────────────────── GND  (must be battery negative)
GPIO0 (SDA) ───────────── SDA
GPIO1 (SCL) ───────────── SCL
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

## Feature 9b — EBL30 12V Power Toggle, Gas System, Power Presence, Water Pump

These four peripherals (`peripherals/ebl30_power.yaml`, `gas_system.yaml`, `power_status.yaml`,
`water_pump.yaml`) all drive or read a single N-MOS/optocoupler stage per signal — no
special wiring beyond the GPIO, 3.3 V logic side, and shared GND.

- **EBL30 power toggle** (GPIO38 = A11 "on" pulse, GPIO19 = A12 "off" pulse): the
  electroblock's own lines are normally pulled up to 12 V and triggered by a LOW pulse.
  ESP GPIO HIGH turns the opto/MOS on, which pulls the EBL30 line LOW for ~200 ms. Home
  Assistant only sees one toggle entity; the two physical lines are never pulsed
  together, and a `script: mode: queued` enforces the >=500 ms minimum gap between
  commands.
  > GPIO19 is the native-USB D- pin. It is free to reuse because this board's console
  > and flashing already run over the external CH343 UART bridge (GPIO43/44), not the
  > chip's native USB peripheral. Expect (and ignore) an ESPHome compile-time warning
  > "GPIO19 conflicts with USB-Serial-JTAG".
- **Gas bottle source** (GPIO1): plain switch to GND, closed when bottles are
  interconnected (primary). Internal pull-up; open = secondary.
- **Gas valve heater** (GPIO7): plain on/off N-MOS switch, fail-safe OFF at reset.
- **12V supply present** (GPIO2) / **mains 230V connected** (GPIO6): each uses an
  optocoupler input configured with a pull-up and inverted logic, so a LOW GPIO level
  means present and a disconnected input reads inactive.
- **Engine running / D+**: on the separate C3, through an optocoupler to GPIO20.
  The alternator's D+ terminal only energises once the engine is running and charging — a
  firmer signal than "ignition on". `device_class: running`; the GPIO input is configured
  active-low with a pull-up.
- **Water pump enable** (GPIO47): same active-low N-MOS drive style as the EBL30
  lines — `inverted: true` so Home Assistant's on/off matches the physical LOW-active
  trigger. Fail-safe OFF at reset.

---

## Feature 10 — VL6180X Time-of-Flight Range Sensor

Short-range (0–200 mm) ToF distance plus ambient light, on the C3's shared I2C bus at
0x29. Enabled in `esphymer2.yaml`.

```
ESP32-C3 Super Mini        VL6180X breakout
──────────────────         ─────────────────────────
3.3V ─────────────────────── VIN / 3V3
GND ──────────────────────── GND
GPIO0 (SDA) ────────────── SDA
GPIO1 (SCL) ────────────── SCL
(unconnected) ─────────── CE / XSHUT  (breakouts pull it up; only needed for >1 sensor)
```

> **Third-party component.** `vl6180x` is not part of ESPHome; it is pulled from
> `thedayowl/esphome-vl6180x` and **pinned to commit `3edff0aa`** so an upstream change
> cannot silently enter the build. Review the diff before moving the pin. Range is only
> 0–200 mm — for tank-depth use, VL53L0X (≈120 cm) is the better part.

---

## I2C Bus Summary

On the C3, SDA = GPIO0 and SCL = GPIO1. Add 4.7 kΩ pull-ups to 3.3 V if
the harness is longer than ~30 cm.

| Device   | Address | Feature                           |
|----------|---------|-----------------------------------|
| BME280   | 0x76    | Temp / humidity / pressure        |
| INA219   | 0x40    | Battery voltage / current / power |
| INA226   | 0x41    | Starter battery voltage           |
| VL6180X  | 0x29    | Time-of-flight range + lux        |

---

## Power Supply Overview

| Node | Rail | Used by |
|------|------|---------|
| ESP32-S3 | 5 V | HC-SR501 VCC |
| ESP32-S3 | 3.3 V | Rain board, T1 DS18B20 and LIN logic side |
| ESP32-S3 | GND | ESP32-S3 peripherals and logic-side interfaces |
| ESP32-S3 | 12 V | LIN transceiver bus side and P-MOS load |
| ESP32-C3 Super Mini | 5 V / USB | C3 supply from automotive-protected converter |
| ESP32-C3 Super Mini | 3.3 V | nRF24, BME280, INA219, INA226, VL6180X, T2 and T3 DS18B20 |
| ESP32-C3 Super Mini | GND | C3 sensors, radio and optocoupler logic side |
| Battery circuit | 12 V | INA219 shunt path; follow the shunt wiring above |

> The ESP32-S3 with Wi-Fi + PSRAM draws noticeably more than the C3 (peaks ~350–500 mA on
> TX bursts). Feed the board from a supply good for **≥1 A** and add a 470 µF bulk capacitor
> at the 5 V input if it is fed over a long cable run — brownouts show up as random reboots.

---

## Pull-up / Pull-down Summary

| Signal | GPIO / label | External resistor | Value | Between |
|--------|--------------|-------------------|-------|---------|
| T1 DS18B20 data | ESP32-S3 GPIO10 | Recommended | 4.7 kΩ | GPIO10 ↔ 3.3 V |
| T2/T3 DS18B20 data | C3 GPIO10 | Recommended | 4.7 kΩ | GPIO10 ↔ 3.3 V |
| I2C SDA/SCL | C3 GPIO0/1 | Board-dependent; add for long harness | 4.7 kΩ | Each line ↔ 3.3 V |
| Water probes | ESP32-S3 GPIO12–15 | Internal pull-down | — | auto |
| PIR OUT | ESP32-S3 GPIO4 | None | — | actively driven |
| Charger ctrl | ESP32-S3 GPIO16 | On P-MOS board | — | — |

---

## Validation Checklist

- [ ] IPEX antenna attached; ESPHome log shows the camper SSID in scan results
- [ ] `esphome logs` over UART0 works (logger on GPIO43/44)
- [ ] Onboard RGB LED lights (if dark, flip `status_led_pin` between GPIO48 and GPIO38)
- [ ] ESP32-S3's T1 reports plausible °C; C3's I2C scan lists 0x76, 0x40, 0x41 and 0x29
- [ ] C3 discovers T2 and T3 and both report plausible °C
- [ ] Starter Battery Voltage agrees with a multimeter at 8, 12 and 15 V
- [ ] C3 USB logging works; `nRF24 ready` appears and Roof Vent Radio OK is on
- [ ] Roof vent power/fan/direction/lid/rain/resend work while sensors continue updating
- [ ] Rebooting the combined node does not move the vent
- [ ] Engine Running (D+) changes state only when the alternator signal is present
- [ ] `CP Plus alive` = ON and Truma room/water temperatures populate
- [ ] PIR toggles on hand wave
- [ ] Fresh and Waste Water Level step 0 → 25 → 50 → 75 → 100 % as electrodes are shorted to common
- [ ] Phone Charger switch toggles the load and is OFF after a reboot
- [ ] Battery Current on esphymer2 is negative under load and positive while charging
- [ ] Rain Detected flips when the plate is wetted; tune `Rain Threshold` from HA
- [ ] Status LED breathes green once everything is healthy
- [ ] Setting `Status LED Notification` in HA switches the LED to a slow blink
- [ ] `sensor.esphymer_device_status` and `sensor.esphymer2_device_status` read `OK`
- [ ] `esphymer` and `esphymer2` appear in Home Assistant at 10.129.28.200 and
  10.129.28.205 respectively

---

## Troubleshooting Notes

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `No networks found` on every scan | IPEX antenna not attached to the `-1U` module | Seat the U.FL pigtail until it clicks |
| Board boots to download mode | Something pulls GPIO0 low | Free GPIO0; it is the BOOT strap |
| Random crashes after adding PSRAM | Harness on GPIO33–37 | Those pins belong to the octal PSRAM |
| No serial log output | Logger left on the S3 default `USB_SERIAL_JTAG` while using the CH343 port | Keep `hardware_uart: UART0` |
| DS18B20 reads −127 °C | Missing/wrong pull-up | 4.7 kΩ between the affected node's data GPIO and 3.3 V |
| Truma shows no data | LIN wiring/level or swapped TX/RX | Verify 9600 8N2 and transceiver polarity |
| PIR always ON | Powered from 3.3 V | Move VCC to the 5 V rail |
| Water level stuck at 0 % | Common probe not driven or electrodes not wetted | Check GPIO11 wiring and probe continuity |
| Charger always ON | Inverted logic mismatch | Check opto polarity / drop `inverted: true` |
