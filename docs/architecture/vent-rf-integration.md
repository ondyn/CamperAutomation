# Roof Vent RF Investigation and Integration Plan

## Device Identification

The installed unit is a **CE-marked 12V roof vent fan** (common Chinese OEM, sold under various brands —
WC-1200, Heng Long, Camplux variants, etc.). Key observable features:

- Clear plastic fan blades, ~400 mm square plastic frame
- Rain sensor dome on inner frame
- 12V DC supply (red/white wire pair visible at frame edge)
- Wireless remote with a re-pair procedure: *hold POWER + RAIN SENSOR button on the vent for 4 s*

## Investigation Status

**Solved (2026-10-05):** the remote is an **LT8920 2.4 GHz GFSK transmitter (1 Mbps, hopping
2408/2428/2464/2480 MHz)** that sends its **complete state** in every packet. Framing, fields, checksum
and CRC are verified on the remote's internal SPI bus, and `vent/vent_protocol.py` reproduces every
captured frame - see [Radio Protocol](#radio-protocol-fully-decoded-2026-10-05).
The earlier EV1527 / 433 MHz hypothesis (based on the pairing procedure) was wrong.

| Band | Test method | Result |
|---|---|---|
| 433.92 MHz | MX-RM-5V receiver with `vent-sniffer.yaml`; separate EV1527 TX/RX loopback configs are available to validate the test rig | Inconclusive: `inverted: true` broke rc_switch decoding (fixed 2026-10-04) and a superregenerative OOK receiver cannot see FSK. Excluded anyway by the PCB antenna size |
| 315 MHz | Prior receiver test; exact setup not recorded in this repository | Unverified. Excluded by the PCB antenna size |
| 2.4 GHz | nRF24L01 (`nrf24-sniffer.yaml`): continuous-RPD scan 2400-2483 MHz with IDLE/PRESS windows, then 1 Mbps raw sniff and per-button majority voting | **CONFIRMED 2026-10-05.** Scan: ch 29 = 2429 MHz rises only while pressing (z=6), weaker 2409/2441 MHz. Sniff on 2429 MHz with the vent off: 210 structured packets pressing vs 17 hands-off. Protocol fully decoded (below) |
| 862-871 MHz | CC1101 RSSI sweep (`vent-868-sniffer.yaml`), 46 ch x 200 kHz, 42 sweeps/s, timed IDLE/PRESS windows | No remote-correlated activity (2026-10-04). Ambient 868.8-869.2 MHz traffic at -60..-86 dBm was received equally in IDLE and PRESS windows, which proves the 868 MHz RX chain works |
| Infrared | Ruled out: the remote has no IR LED and carries a PCB antenna | Not IR |

**Remote PCB evidence (photos in `vent/`):** Generalplus GPM8F3732B LCD MCU, an unmarked SSOP16 RF
chip with a 12.000 MHz crystal and a ~2 cm inverted-F PCB antenna. A quarter-wave on FR4 is ~2 cm at
2.4 GHz but ~5 cm at 868 MHz and ~10 cm at 433 MHz, so the antenna alone points to 2.4 GHz. SSOP16 +
12 MHz matches the LT8900/LT8910/LT8920/PL1167 GFSK family (1 Mbps default, $f = 2402 + ch$ MHz), the
same family as MiLight remotes, which the nRF24L01 can sniff and emulate.

**Decoding tools:** `u1u2-spi-sniffer.yaml` (ESP32-C3, listen-only SPI slave on the remote's U1->U2 bus)
prints one decoded block per press with the exact FIFO bytes and the computed on-air CRC - this is the
ground truth. `nrf24-sniffer.yaml` BUTTON mode (`sniff_ch: "29"`) confirms it over the air: it finds the
sync word in the raw 1 Mbps capture and logs frames whose CRC verifies ("radio CRC OK").
Reference encoder with self-test: `vent/vent_protocol.py`.

## Radio Protocol (fully decoded 2026-10-05)

Source: U1->U2 SPI capture of all 9 buttons (35 presses, every checksum OK), cross-checked by 6
CRC-valid frames received over the air by the nRF24. `vent/vent_protocol.py` reproduces all 16 distinct
captured frames byte for byte, CRC included.

### Physical layer (LT8920 registers written by U1 at power-up)

| Item | Value |
|---|---|
| Chip | U1 Generalplus MCU -> U2 LT8920 (SSOP16, 12 MHz crystal) |
| Modulation / rate | GFSK 1 Mbps (r44 = 0100 default), NRZ, no FEC, no scrambling, no auto-ack (TX only) |
| Channels | Hops LT8920 ch **6, 26, 62, 78** = 2408 / 2428 / 2464 / 2480 MHz ($f = 2402 + ch$), every packet on the next channel |
| Per press | ~40 identical packets over ~250 ms (10 rounds of the 4 channels). Nothing is sent while the remote is OFF (only POWER transmits then); holding a button does not repeat |
| Framing (r32 = 4800) | 3-byte preamble, 32-bit sync word, 4-bit trailer, then length byte + payload + CRC |
| Sync word | r36 = `0516`, r39 = `1982` (r37 `0001` / r38 `5A5A` written but unused in 32-bit mode). On air: bytes `16 05 82 19` |
| CRC (r41 = B000) | CRC on, length byte on, seed `00`: CRC-16/KERMIT (reflected poly `0x8408`, init `0000`) over length byte + payload, sent low byte first |
| Bit order | Every byte LSB first on air |

The remote's crystal sits about +1 MHz high: an nRF24 tuned to 2429 MHz receives ch 26 far better than
one tuned to 2428 MHz.

### Frame (FIFO bytes written by U1, then the hardware CRC)

| Byte | Value | Meaning |
|---|---|---|
| 0 | `09` | Length byte (9 payload bytes) |
| 1-5 | `5F 18 02 00 0E` | Remote ID / address, constant. Presumably what the vent learns when pairing (*unconfirmed*) |
| 6 | flags | bit 7 = power ON, bit 6 = rain detection on, bit 5 = lid closing, bit 4 = lid opening, bits 3-0 = 0 |
| 7 | `CF` | Constant |
| 8 | fan | bit 7 = direction OUT (1) / IN (0), bits 3-0 = fan level 0-10 (x10 %) |
| 9 | sum | `(byte0 + ... + byte8) & 0xFF` - computed by U1 |
| 10-11 | CRC | CRC-16/KERMIT of bytes 0-9, low byte first - added by the LT8920 |

### Button semantics (all absolute - the vent is a stateless receiver)

The remote keeps the LCD state and every press transmits the **whole** new state; nothing is a relative
"toggle" or "+1" command.

| Button | Effect on the transmitted state (observed) |
|---|---|
| POWER | OFF -> ON sends `flags 80` (rain off, lid stop). ON -> OFF sends `flags 20` (OFF + closing) |
| + / - | Fan level +1 / -1; at 10 further `+` presses resend level 10, at 0 `-` resends 0 |
| FAN | Level 0 <-> last level (7 in the test) |
| IN / OUT | Direction bit 0 / 1; repeated presses resend the same frame |
| UP | Alternates opening (`bit 4`) / stop |
| DOWN | Alternates closing (`bit 5`) / stop |
| RAIN SENSOR | Toggles `bit 6` and keeps the current lid bits (captured with closing still set: `E0` / `A0`) |
| any button while OFF | No transmission at all |

### Captured frames (FIFO bytes + on-air CRC)

| State | Frame |
|---|---|
| ON, fan 0, OUT (base) | `09 5F 18 02 00 0E 80 CF 80 5F 9B A1` |
| OFF | `09 5F 18 02 00 0E 20 CF 80 FF AC A6` |
| ON, fan 1..10 | `09 5F 18 02 00 0E 80 CF 8n sum CRC` - see `CAPTURED` in `vent/vent_protocol.py` |
| ON, fan 10 (100 %) | `09 5F 18 02 00 0E 80 CF 8A 69 5E 08` |
| ON, fan 0, IN | `09 5F 18 02 00 0E 80 CF 00 DF 5F A9` |
| ON, lid opening | `09 5F 18 02 00 0E 90 CF 80 6F B9 53` |
| ON, lid closing | `09 5F 18 02 00 0E A0 CF 80 7F CA 0F` |
| ON, rain on + closing | `09 5F 18 02 00 0E E0 CF 80 BF 71 DF` |

The earlier nRF24-only decode (before the SPI capture) had a 3-bit framing offset, treated byte 3 (`02`)
as noise and folded the header into a CRC seed `0x4052`; this table supersedes it.

### Encoder

```python
def crc16_kermit(data, crc=0):
    for x in data:
        crc ^= x
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc

def air_frame(power, fan_level, fan_out=True, opening=False, closing=False, rain=False):
    frame = [9, 0x5F, 0x18, 0x02, 0x00, 0x0E,
             power << 7 | rain << 6 | closing << 5 | opening << 4, 0xCF, fan_out << 7 | fan_level]
    frame.append(sum(frame) & 0xFF)
    c = crc16_kermit(frame)
    return frame + [c & 0xFF, c >> 8]
```

To transmit with an LT8920 / LT8900 module: copy U1's register setup (sync word, r32, r41 = B000), write
bytes 0-9 to the FIFO (the chip appends the CRC) and send the frame ~10x on each of ch 6/26/62/78.
With an nRF24L01 the whole bit stream (preamble, sync, trailer, frame, CRC, all LSB first) has to be
built in software, as openmili does for PL1167 remotes.

### Open points

- Test on the vent: does it accept a replayed / synthesised frame, and does it need all 4 channels?
- Whether the vent needs this remote ID (bytes 1-5) or accepts any ID after pairing.
- Combined states not yet captured (e.g. rain on with lid stopped, IN with fan > 0) - the encoder
  predicts them, a capture would confirm.

## Historical: 868 MHz Test Procedure

Retained as a record; the remote turned out to be 2.4 GHz.

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

## Integration Options

| Approach | Effort | Reliability | Invasiveness |
|---|---|---|---|
| **ESP32 + nRF24L01 emulating the LT89xx packet** (as openmili does for MiLight/PL1167) | Medium | High, full absolute state, no feedback | None |
| **ESP32 + LT8920 module** (native chip, needs sync word/CRC setup from the SPI capture) | Medium | High | None |
| **Wire to PCB button pads** | Medium | High | Low - solder only, leave PCB intact |
| **Replace control board** | High | Very high (full PWM control) | High - invasive |

**Recommended path (implemented, not yet tested on the vent):** `esphome/config-esp/vent-remote.yaml`
(ESP32-C3 + nRF24L01, same wiring as the sniffer). The nRF24 runs in ShockBurst-compatible mode
(no auto-ack, no packet control field, no CRC) with a 3-byte `55 55 55` address that extends the
preamble; its 17-byte payload carries the LT8920 sync word, trailer, frame and CRC bit for bit
(`vent_protocol.h`, host-tested against the captured frames and the raw over-the-air bits). Each
command is sent like the remote: 10 rounds over ch 6/26/62/78. Because every packet carries the
complete state, HA sets power, fan level, direction, lid and rain detection directly. The original
remote keeps working; its LCD will just not reflect changes made from HA (and vice versa).

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

Superseded EV1527 draft (the real `vent-remote.yaml` is now the nRF24 emulator):

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

## Home Assistant Integration

Flash `vent-remote.yaml` (static IP 10.129.28.204) and add it in HA via the ESPHome integration. It
creates these entities (all show the last *commanded* state - the vent sends no feedback):

| Entity | Function |
|---|---|
| `switch.roof_vent_power` | ON = flags `80`, OFF = flags `20` (exactly the remote's frames) |
| `fan.roof_vent_fan` | Speed 1-10 (10 % steps), off = level 0; direction forward = OUT, reverse = IN |
| `cover.roof_vent_lid` | Open / close / stop (opening / closing bit) |
| `switch.roof_vent_rain_sensor` | Rain detection enabled |
| `button.roof_vent_resend` | Repeat the last state |
| `binary_sensor.roof_vent_radio_ok` | nRF24 answered on SPI at boot |

Any command except power OFF also switches power on (the remote does not transmit while OFF).
Commands in the first 5 s after an ESP boot are ignored so entity restores cannot move the vent.

Dashboard card:

```yaml
type: entities
title: Roof Vent
entities:
  - switch.roof_vent_power
  - fan.roof_vent_fan
  - cover.roof_vent_lid
  - switch.roof_vent_rain_sensor
  - button.roof_vent_resend
```

First test with the vent: watch `esphome logs /config/vent-remote.yaml`; every command logs
`TX <frame>`, which must equal the matching frame in `vent/vent_protocol.py`. If the vent ignores it,
press Resend, then try `channel_offset: "1"` (the original remote's crystal sits ~+1 MHz high), then
`tx_rounds: "20"`. To check the transmitter without the vent, run `nrf24-sniffer.yaml` on a second
nRF24 board: it should log `radio CRC OK` with the same frame.

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
- **Range**: the remote itself uses a low PA setting; an nRF24 at 0 dBm covers a van interior. Use a
  PA+LNA nRF24 module (own 3.3 V LDO) only if the vent sits behind metal.
- **Interference**: The 433 MHz band is shared (door openers, tyre sensors, weather stations).
  The `repeat: 5` transmit count and EV1527 address matching at the receiver side make false
  triggers extremely unlikely.
