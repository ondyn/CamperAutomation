# ESP32-C3 Super Mini — Camper Automation Wiring Guide

Board: **ESP32-C3 Super Mini** (mischianti.org pinout reference)  
ESPHome config: `esphome/config-esp/esphymer.yaml`  
Logic level: **3.3 V** on all GPIOs  
Available power rails: **5 V** (USB C pin), **3.3 V** (onboard LDO), **GND**

---

## Pinout Quick Reference

```
                  ┌──────────────────────────────┐
              5V ─┤ 5V                     GPIO5 ├─ [PIR Signal]
             GND ─┤ GND                    GPIO6 ├─ [Phone Charger ctrl]
            3.3V ─┤ 3.3V                   GPIO7 ├─ [PIR Signal] ← existing
           GPIO4 ─┤ GPIO4  (free/XSHUT)    GPIO8 ├─ I2C SDA
           GPIO3 ─┤ GPIO3  (free)          GPIO9 ├─ I2C SCL
           GPIO2 ─┤ GPIO2  (BOOT, free)   GPIO10 ├─ DS18B20 1-Wire
           GPIO1 ─┤ GPIO1  (free)         GPIO20 ├─ UART0 RX ← Truma LIN
           GPIO0 ─┤ GPIO0  (free)         GPIO21 ├─ UART0 TX ← Truma LIN
                  └──────────────────────────────┘
```

---

## Assigned Pin Map

| GPIO  | Direction | Connected to              | Notes                               |
|-------|-----------|---------------------------|-------------------------------------|
| GPIO6 | OUT       | P-MOS optocoupler input   | Phone charger — inverted logic      |
| GPIO7 | IN        | HC-SR501 OUT              | PIR motion sensor                   |
| GPIO8 | I/O       | I2C SDA                   | BME280 (0x76) + VL53L0X (0x29)     |
| GPIO9 | I/O       | I2C SCL                   | Same I2C bus as SDA                 |
| GPIO10| IN/OD     | DS18B20 data wire         | All 3 sensors; 4.7 kΩ pull-up req. |
| GPIO20| IN        | LIN-UART converter TX→ESP | UART0 RX — Truma iNetBox           |
| GPIO21| OUT       | LIN-UART converter RX←ESP | UART0 TX — Truma iNetBox           |

**Free GPIOs:** GPIO0, GPIO1, GPIO2 (BOOT), GPIO3, GPIO4, GPIO5

---

## Feature 1 — DS18B20 One-Wire Temperature Sensors (×3)

### Hardware

- **Sensors wired in parallel** on a single data wire
- Requires one **4.7 kΩ pull-up resistor** between DATA and 3.3 V (only one, even for 3 sensors)
- Can be powered in *normal mode* (VCC to 3.3 V) or *parasitic mode* (VCC shorted to GND, draws power from data line). Normal mode recommended for reliability.

### Wiring

```
ESP32-C3 Super Mini       DS18B20 (×3, all in parallel)
──────────────────         ──────────────────────────
3.3V ─────────────────────── VCC (pin 3)
                 │
              4.7 kΩ
                 │
GPIO10 ──────────┴────────── DATA (pin 2)
GND ──────────────────────── GND (pin 1)
```

Flat-face DS18B20 (looking at flat side):  
`[GND] [DATA] [VCC]` → left to right

### ESPHome Config

```yaml
one_wire:
  - platform: gpio
    pin: GPIO10
    id: bus_b

sensor:
  - platform: dallas_temp
    one_wire_id: bus_b
    address: 0x8b3c01f095401e28   # replace with your sensor addresses
    name: "T1"
    unit_of_measurement: "°C"

  - platform: dallas_temp
    one_wire_id: bus_b
    address: 0xa83c01f095b01928
    name: "T2"
    unit_of_measurement: "°C"

  - platform: dallas_temp
    one_wire_id: bus_b
    address: 0xdb3c01f0952a3328
    name: "T3"
    unit_of_measurement: "°C"
```

> **Finding sensor addresses:** Flash with the above config (no addresses), open ESPHome logs → boot will print discovered 1-Wire addresses. Copy them in.

---

## Feature 2 — Truma iNetBox via LIN-to-UART Converter

### Hardware

The Truma iNetBox communicates over a LIN bus (single-wire, 12 V signalling). A **LIN-to-UART converter** (e.g., MCP2003B breakout, TJA1020, or MXSTER LIN adapter) bridges LIN to 3.3 V UART.

#### LIN Transceiver wiring

```
Van 12 V ─────────────────── VBAT (LIN side supply)
LIN bus wire ─────────────── LIN pin
LIN GND ──────────────────── GND (shared with ESP GND)

LIN transceiver UART side:
3.3V ─────────────────────── VCC (logic side, if separate)
GPIO21 (ESP TX) ──────────── RXD (conv. receives from ESP)
GPIO20 (ESP RX) ──────────── TXD (conv. sends to ESP)
GND ──────────────────────── GND
```

> **CRITICAL:** LIN bus carries 12 V. The UART side *must* be 3.3 V logic-level compatible with the ESP32-C3. If your converter has a 5 V UART side only, add a 3.3 V/5 V level-shifter on the TX/RX lines to the ESP.

> **Polarity note:** On some adapters TXD/RXD labels refer to the module's perspective (TXD = module transmits = ESP receives on GPIO20). Double-check with your specific board.

### ESPHome Config

```yaml
uart:
  - id: lin_uart_bus
    tx_pin: GPIO21
    rx_pin: GPIO20
    baud_rate: 9600
    stop_bits: 2

external_components:
  - source: github://cobaltfish/esphome-truma_inetbox@feature/esphome-2024.12
    components: ["truma_inetbox"]

truma_inetbox:
  uart_id: lin_uart_bus

sensor:
  - platform: truma_inetbox
    name: "Current Room Temperature"
    type: CURRENT_ROOM_TEMPERATURE
  - platform: truma_inetbox
    name: "Current Water Temperature"
    type: CURRENT_WATER_TEMPERATURE
  - platform: truma_inetbox
    name: "Target Room Temperature"
    type: TARGET_ROOM_TEMPERATURE
  - platform: truma_inetbox
    name: "Target Water Temperature"
    type: TARGET_WATER_TEMPERATURE

binary_sensor:
  - platform: truma_inetbox
    name: "CP Plus alive"
    type: CP_PLUS_CONNECTED
```

---

## Feature 3 — PIR Motion Sensor (HC-SR501)

### Hardware

- Supply: **5 V** (HC-SR501 requires 4.5–20 V; do **not** use 3.3 V)
- OUT signal: 3.3 V compatible (the sensor's output HIGH is ~3.3 V)
- Adjustable sensitivity and hold-time via two onboard potentiometers
- Default hold time: ~5 s; default sensitivity: medium

### Wiring

```
ESP32-C3 Super Mini       HC-SR501
──────────────────         ──────────────────────────
5V ────────────────────── VCC  (middle pin / +)
GPIO7 ─────────────────── OUT  (signal pin)
GND ────────────────────── GND (– pin)
```

HC-SR501 pinout (3 pins, left-to-right with dome facing you):  
`[GND] [OUT] [VCC]`

### ESPHome Config

```yaml
binary_sensor:
  - platform: gpio
    pin:
      number: GPIO7
      mode:
        input: true
    name: "PIR Sensor"
    device_class: motion
    filters:
      - delayed_off: 10s   # holds ON for 10s after last detection
```

> **Warm-up:** HC-SR501 needs ~30–60 s warm-up after power-on before giving reliable readings. During this period it may trigger falsely.

---

## Feature 4 — Water Level Sensor (VL53L0X or VL6180X, Time-of-Flight)

### Hardware

Mounted inside or above the water tank, facing downward. Measures distance from sensor to water surface. Fill level is derived by subtracting distance from total tank depth.

- Supply: **3.3 V** (most breakout boards have onboard regulator; check yours)
- Interface: **I2C** — shares bus with BME280 (no address conflict)
  - VL53L0X default address: **0x29**
  - BME280 address: **0x76**
  - MPU6050 address: **0x68**
- Optional **XSHUT** pin (active LOW): pulling it LOW resets/disables the sensor; connect to GPIO4 if you need software reset or multiple VL53L0X on same bus

### Wiring

```
ESP32-C3 Super Mini       VL53L0X / VL6180X breakout
──────────────────         ──────────────────────────
3.3V ──────────────────── VIN / VCC
GND ────────────────────── GND
GPIO8 (SDA) ───────────── SDA
GPIO9 (SCL) ───────────── SCL
GPIO4 ─────────────────── XSHUT  (optional — pull HIGH via 10 kΩ if unused)
```

### ESPHome Config (VL53L0X)

```yaml
i2c:
  sda: GPIO8
  scl: GPIO9
  scan: true
  id: bus_a

sensor:
  - platform: vl53l0x
    name: "Water Tank Distance"
    i2c_id: bus_a
    address: 0x29
    update_interval: 10s
    unit_of_measurement: "m"
    id: water_distance

  - platform: template
    name: "Water Level"
    unit_of_measurement: "%"
    device_class: moisture
    state_class: measurement
    accuracy_decimals: 0
    update_interval: 10s
    lambda: |-
      const float tank_depth_m = 0.40;  // adjust to your tank
      const float sensor_offset_m = 0.02;
      float dist = id(water_distance).state;
      if (isnan(dist) || dist <= 0) return NAN;
      float level = (tank_depth_m - (dist - sensor_offset_m)) / tank_depth_m * 100.0;
      return clamp(level, 0.0f, 100.0f);
```

> Replace `tank_depth_m` (0.40 m = 40 cm) with your actual tank internal depth in metres.

> **VL6180X alternative:** Use `platform: vl6180x` instead. VL6180X has shorter range (up to ~10 cm) — better suited for very shallow tanks. VL53L0X reaches up to ~120 cm.

---

## Feature 5 — Temperature, Humidity, Pressure (BME280)

### Hardware

- Supply: **3.3 V**
- Interface: **I2C**, address **0x76** (SDO pin tied to GND) or 0x77 (SDO to 3.3 V)
- CSB pin must be tied **HIGH (3.3 V)** to force I2C mode (vs SPI)

### Wiring

```
ESP32-C3 Super Mini       BME280 breakout
──────────────────         ──────────────────────────
3.3V ──────────────────── VCC
GND ────────────────────── GND
GPIO8 (SDA) ───────────── SDA
GPIO9 (SCL) ───────────── SCL
GND ────────────────────── SDO  → I2C address = 0x76
3.3V ───────────────────── CSB  → forces I2C mode
```

> If using a module/breakout that already has pull-ups on SDA/SCL and SDO/CSB hardwired, just connect VCC, GND, SDA, SCL.

### ESPHome Config

```yaml
sensor:
  - platform: bme280_i2c
    i2c_id: bus_a
    address: 0x76
    update_interval: 30s
    temperature:
      name: "BME280 Temperature"
    pressure:
      name: "BME280 Pressure"
    humidity:
      name: "BME280 Humidity"
```

---

## Feature 6 — Phone Charging Control (P-MOS + PC817C217N Optocoupler)

### Hardware

Controls whether the phone (running Home Assistant) is being charged by switching the 5 V/12 V charger line using a **P-channel MOSFET board with optical isolation**.

- **ESP side:** GPIO6 drives the optocoupler LED via current-limiting resistor (built into most P-MOS boards)
- **Optocoupler (PC817C217N):** isolated signal path → P-MOS gate control → switches charger power line
- **P-MOS (e.g., AOD407, IRF9540):** handles the actual current to the charger
- Logic: `inverted: true` in ESPHome → switch **ON** in Home Assistant = GPIO6 LOW = optocoupler LED ON = P-MOS ON = charging **ON**

### Wiring

```
ESP32-C3 Super Mini       P-MOS board (with PC817C217N)
──────────────────         ──────────────────────────
GPIO6 ─────────────────── IN  (optocoupler anode side, via built-in 330 Ω)
GND ────────────────────── GND (logic side)

P-MOS board power side:
+12V or +5V ────────────── VIN  (charger supply in)
GND load side ──────────── GND
P-MOS drain output ──────► Phone charger USB input (+)
GND ────────────────────── Phone charger USB GND
```

> Your P-MOS board may label pins differently (e.g., SIG/IN/CTRL). Check the board silkscreen. The key: the **control input** pin connects to GPIO6.

> **Safe default:** On boot/reset, GPIO6 defaults LOW → optocoupler OFF → P-MOS gate pulled HIGH → P-MOS OFF → **charger disabled until HA explicitly enables it**. This is the fail-safe state.

### ESPHome Config

```yaml
switch:
  - platform: gpio
    pin: GPIO6
    name: "Phone Charger"
    inverted: true
    restore_mode: ALWAYS_OFF   # safe default: charger OFF on reboot
```

---

## I2C Bus Summary

All I2C devices share **SDA=GPIO8 / SCL=GPIO9** (internal pull-ups enabled by ESPHome):

| Device     | I2C Address | Feature              |
|------------|-------------|----------------------|
| BME280     | 0x76        | Temp / Humidity / Pressure |
| VL53L0X    | 0x29        | Water tank distance  |
| MPU6050    | 0x68        | Accelerometer / levelling (bonus) |

No address conflicts. ESPHome config:

```yaml
i2c:
  sda: GPIO8
  scl: GPIO9
  scan: true
  id: bus_a
```

---

## Power Supply Overview

| Rail   | Source         | Used by                                   |
|--------|----------------|-------------------------------------------|
| 5 V    | USB-C on board | HC-SR501 VCC (must be 5 V)                |
| 3.3 V  | Onboard LDO    | BME280, VL53L0X, DS18B20 VCC, ESP GPIOs  |
| GND    | Common         | All components                            |
| 12 V   | Van battery    | LIN transceiver (LIN bus side), P-MOS load |

> **Total 3.3 V current budget:** ESP32-C3 core ~80 mA + BME280 ~1 mA + VL53L0X ~20 mA (peak) + DS18B20 ×3 ~5 mA = ~106 mA. Onboard LDO is typically rated 600 mA. Safe budget.

> **GPIO current:** Never exceed 40 mA per GPIO or 300 mA total draw from GPIO pins. All peripherals here are well within limits (the P-MOS board draws ~5–10 mA from GPIO6 through the optocoupler LED).

---

## Pull-up / Pull-down Resistor Summary

| Signal     | GPIO  | External resistor | Value  | Between        |
|------------|-------|-------------------|--------|----------------|
| DS18B20    | GPIO10| **Required**      | 4.7 kΩ | GPIO10 ↔ 3.3 V |
| I2C SDA    | GPIO8 | ESPHome internal  | ~4.7 kΩ | (auto)        |
| I2C SCL    | GPIO9 | ESPHome internal  | ~4.7 kΩ | (auto)        |
| VL53L0X XSHUT | GPIO4 | Recommended   | 10 kΩ  | GPIO4 ↔ 3.3 V (if pin unused, keeps sensor enabled) |
| PIR OUT    | GPIO7 | None needed       | —      | HC-SR501 drives it actively |

---

## Remaining Free GPIOs

| GPIO  | Notes                                           |
|-------|-------------------------------------------------|
| GPIO0 | ADC1_0, XTAL_32K_P — safe as digital GPIO      |
| GPIO1 | ADC1_1, XTAL_32K_N — safe as digital GPIO      |
| GPIO2 | ADC1_2, BOOT pin — usable after boot           |
| GPIO3 | ADC1_3 — clean general-purpose GPIO            |
| GPIO4 | ADC1_4, SCK — recommended for VL53L0X XSHUT   |
| GPIO5 | ADC2_0, MISO — safe as digital GPIO            |

---

## Validation Checklist

After wiring each component, verify in ESPHome logs and HA:

- [ ] **DS18B20:** `dallas_temp` reports 3 addresses at boot; all 3 sensors show temperature readings
- [ ] **Truma iNetBox:** `CP Plus alive` binary sensor shows `ON`; room/water temps appear in HA
- [ ] **PIR HC-SR501:** Wave hand in front — `PIR Sensor` entity toggles ON then OFF after hold time
- [ ] **VL53L0X:** Distance sensor shows a plausible value (cm/m); `Water Level` % matches expected fill
- [ ] **BME280:** Temperature matches ambient; humidity and pressure are sensible values
- [ ] **Phone Charger switch:** Toggle ON in HA → phone starts charging; toggle OFF → charging stops; confirm charger is OFF after ESP reboot (safe default)

---

## Troubleshooting Notes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| DS18B20 reads -127 °C | Missing or wrong pull-up resistor | Add 4.7 kΩ between GPIO10 and 3.3 V |
| DS18B20 reads all `nan` | All sensors on wrong pin or data wire broken | Check GPIO10 connection |
| Truma shows no data | LIN bus not connected, wrong baud rate | Verify 9600 baud, 2 stop bits; check LIN wire to iNetBox |
| PIR always ON | HC-SR501 powered from 3.3 V | Move VCC to 5 V rail |
| PIR never triggers | Sensitivity pot too low | Turn sensitivity pot CW |
| VL53L0X not found (I2C scan) | Wrong I2C address or power | Verify 0x29; check if XSHUT is held LOW |
| BME280 reads at 0x77 instead of 0x76 | SDO pin is floating or tied HIGH | Tie SDO to GND for address 0x76 |
| Phone charger always ON | inverted logic mismatch | Swap GPIO level (remove inverted: true if needed); check optocopler polarity |
| Phone charger never turns ON | P-MOS gate not controlled | Check optocoupler wiring and supply rails |
