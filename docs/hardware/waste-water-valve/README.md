# Waste-water valve: ESP32-C3 and TMC2209

This is a **prototype to be commissioned, not a verified installation**. It uses
a second ESP32-C3 Super Mini, a TMC2209 UART stepper driver and a four-wire
bipolar motor to turn a valve with hard stops at both ends. See the
[connection schematic](wiring.md) before buying parts or connecting power.

The firmware is [waste-water-valve.yaml](../../../esphome/config-esp/waste-water-valve.yaml),
with its [controller](../../../esphome/config-esp/waste_valve_logic.h) and
[TMC2209 interface](../../../esphome/config-esp/waste_valve_esphome.h). It
uses the existing ESPHome 2026.8.1 / ESP-IDF setup; it is not an Arduino IDE
sketch and it does not depend on a downloaded third-party component.

## Important limitations

- **StallGuard measures motor load, not valve position.** A blockage, frozen
  valve, loose coupling, missed steps or incorrect tuning can be mistaken for
  an end stop. An open circuit is not reliably detected in StealthChop. Even a
  reported `Closed` does not prove a seal or that the shaft moved. Do not use
  this as the only protection against an unintended discharge. Add independent
  position switches or an encoder where position must be confirmed.
- If DIAG fails to signal an end, the motor can continue pushing against the
  hard stop until the pulse or time limit. With the example settings, a normal
  90-degree move permits up to 108 degrees of commanded travel; during homing
  from an unknown starting position, considerably more of that travel could
  be commanded against the closed stop. Use an appropriate torque-limited
  coupling or independent hardware cutoff; do not rely on the valve stop to
  tolerate this indefinitely.
- Each homing attempt and open/close command starts with at least four motor
  full steps in SpreadCycle to check open-load flags before StealthChop.
  **StallGuard does not detect a jam during this part**: with the example motor it moves or pushes
  for at least 7.2 degrees, and can reach the bounded `release_steps` limit
  (9 degrees with the example settings) before the check. The test is diagnostic,
  not a guaranteed cable-integrity check; a coil could also disconnect after
  it. The TMC datasheet warns that an open coil during StealthChop standstill
  auto-tuning can overcurrent the other coil. Secure and inspect both coil
  circuits and use protection appropriate to the motor.
- On every boot, once commissioned, the motor first moves **toward open** for
  up to `release_steps` before seeking closed. With the example settings this
  is about **9 degrees**, and wastewater may escape. If it hits the open stop
  during this release, it can push into the stop until DIAG is detected or the
  bounded release ends. The user has accepted this startup behavior; keep a
  manual downstream cap/shutoff and suitable containment. Reboots, firmware
  updates and power restoration all cause a fresh homing attempt.
- The motor is **disabled at rest and on faults**. The valve/coupling must not
  back-drive when the motor is unpowered. If it can move independently, the
  last inferred position is no longer reliable.
- The driver is an **MKS TMC2209 V2.0** (0.11 Ω sense resistors, on-board EN
  pull-up, DIAG on a separate bottom pad; see [wiring.md](wiring.md)). The
  motor model, phase current, coil resistance, torque and exact direction are
  **not yet known**. Do not assume the defaults are safe or usable for them.
  The 12–14 V vehicle supply
  needs an automotive-rated protected power stage; a capacitor or generic
  hobby buck alone is not vehicle-transient protection.

## Behavior

The checked-in configuration has `commissioned: "false"`: the driver is
disabled and commands report `Not commissioned`. After the hardware has been
identified, wired, and bench-tested as below, set it to `"true"` and flash
again. On every subsequent boot the controller:

1. Disables the driver, checks EN feedback, verifies the TMC2209 UART identity,
   writes and verifies its settings and clears the expected power-on reset.
   It waits for DIAG to clear before enabling; a stuck DIAG is a fault.
2. Selects SpreadCycle, verifies the EN command/feedback path (with or without
   a STOP interlock) and sends at least 64 of the requested 16-microstep pulses toward open. It
   checks the open-load flags while moving, disables the motor and selects
   StealthChop. A failed check, or reaching the release limit before a moving
   sample is taken, is a fault, not a homing result.
3. Waits 200 ms at run current for initial StealthChop regulation, then
   completes the bounded movement toward open. The motor is disabled for
   300 ms before homing.
   A detected stall during this release also ends the release; it is **not**
   taken as a confirmed open position.
4. Seeks closed, stopping on DIAG. A stall before `min_home_steps`, a driver
   fault, an interlock opening, a timeout, or reaching the travel limit without
   a stall produces `Unknown` and a latched fault. An accepted home stall is
   reported as **inferred** `Closed`.

Open and close then move from the last inferred end toward the other end.
They run the same SpreadCycle check in the commanded direction, and count
those pulses toward the travel limit.
DIAG is accepted as the end only after at least `min_travel_percent` of the
nominal stroke; at `max_travel_percent` without a stall the motor is disabled
and the position becomes unknown. This window rejects some early jams, not
all jams. There is also a per-phase time limit. `Stop` during motion disables
the motor and invalidates position; commands cannot reverse a movement in progress.
After a fault, inspect the mechanism and use **Home Retry**. No motion is
restarted automatically after a fault until another reboot or Home Retry.
Loss of Wi-Fi or Home Assistant does not itself restart the node or reverse
an in-progress local move.

TMC2209 resets after homing, charge-pump undervoltage, overheating/prewarning, short flags,
UART/CRC errors and, during motion, open-load flags are treated as faults.
The idle driver is checked approximately once a second; an unexpected reset
invalidates the inferred position and requires homing.
Short DIAG pulses are captured using a software GPIO interrupt and handled by
the main loop; a missing pulse-counter update for 500 ms is treated as a fault.
Verify pulse capture on the actual board. A blocked UART read can delay the
software response, so retain the independent EN interlock.
Open-load flags are only informative in StealthChop and can flicker or fail to
detect a disconnected coil; they are **not** a substitute for checking wiring.
The physical EN interlock also works without Wi-Fi or working firmware, but
is not a safety-rated emergency-stop system.

## Settings to determine

Edit the substitutions at the top of the ESPHome YAML **before** setting
`commissioned` to true:

| Setting | Initial example | Determine from the actual assembly |
|---|---:|---|
| `direction_inverted` | `false` | On a disconnected motor/fixture, verify that the release turns toward valve open. Reverse if needed. |
| `travel_steps` | `800` | Full steps/rev × 16 microsteps × motor revolutions per valve revolution × 90/360. Set the coupling/gear ratio actually used. |
| `release_steps` | `80` | A bounded opening that gives enough motion to approach closed with useful StallGuard readings. Must exceed 64 microsteps for the coil check and be less than half the stroke. |
| `min_home_steps` | `16` | Rejects an immediate false stall during a home seek. Must be less than the release distance; tune for the real speed and load. |
| `min_travel_percent` / `max_travel_percent` | `80` / `120` | Accept a normal end stall only in this pulse window; the latter also limits a missing-DIAG move. Tighten only after measuring repeatability. |
| `stepper_speed` / `stepper_acceleration` | `600` / `6000` | Microsteps/s and microsteps/s². Confirm StallGuard works at the actual speed and load; don't increase blindly. |
| `tmc_address` | `0` | MS1/MS2 address straps: both wired to GND gives address 0 (the MKS V2.0 has no strap resistors). |
| `sense_resistance` | `0.11` ohm | MKS V2.0 R6/R7 are marked `R110` (0.11 Ω). Re-check if you swap the board; this firmware uses external sensing and VSENSE=1. |
| `run_current` | `0.35` A RMS | Set below **both** the identified motor and module continuous ratings, including cooling. The code rejects values above 1.2 A and rounds down to a representable current. |
| `stall_threshold` | `50` | Raw `SGTHRS`, 0–255. A higher number is more sensitive. Tune using the real motor, speed, supply and valve. |

For the example 1.8-degree motor, 200 × 16 / 4 = 800 microsteps per quarter
turn. At 600 microsteps/s this is only 11.25 motor RPM: it may be too slow for
reliable StallGuard on a particular motor. StealthChop's automatic tuning can
also require more motion than a quarter-turn provides. The 200 ms standstill
helps its first tuning phase; it does not guarantee the moving tuning phase or
an adequate StallGuard signal. If the running and stalled readings cannot be
separated reliably across the actual operating range, fit physical end switches
or an encoder rather than assuming this implementation will work.

The firmware sets 16 microsteps, uses SpreadCycle for the initial open-load
check and StealthChop for StallGuard, and uses external current sensing and
UART current control. The module's VREF potentiometer is **not** the current
limit in this configuration. `IHOLD` equals `IRUN` while enabled to allow
initial tuning, but EN is switched off once movement ends. Calculated current
is nominal: confirm it with suitable measurement equipment, resistor tolerance,
module documentation and temperature. Don't measure motor phase current by
putting a multimeter in series with the battery.

## Commissioning

1. Identify the motor. Verify phase current, step angle, coil pairs and the
   limits of the motor, coupling and valve. On the MKS TMC2209 V2.0, confirm
   the DIAG bottom pad and whether R8 is fitted as described in
   [wiring.md](wiring.md).
2. Install and test the protected power stage, fuses, normally-closed EN
   interlock and EN feedback as described in [wiring.md](wiring.md). With
   motor and logic power off, connect the two measured coil pairs. Never
   connect or disconnect a motor while the driver is powered.
3. Flash with `commissioned: "false"`. Check EN is physically HIGH at reset
   and while idle; opening the interlock must force EN HIGH. With supplies
   safely off, isolate the ESP control line, then verify the on-board 20 kΩ
   pull-up also holds EN HIGH with driver VDD (VIO) and VM present. Verify the
   VIO/VM protection handles a loss of ESP power. All digital signals must be
   3.3 V. No movement should occur. A USB-powered ESP must not leave the driver
   VIO or its inputs powered without its required VM supply.
4. In a contained bench setup, disconnect the valve coupling, remove anything
   the motor can catch and set the verified settings. Set `commissioned` to
   true and flash. **The motor starts automatically on that boot.** The short
   release must turn in the valve-open direction; if it is wrong, stop,
   de-energize and change `direction_inverted`. With a free motor the closed
   seek is expected to reach the travel limit and fault; if it instead reports
   `Closed`, stop and investigate the false stall before proceeding.
5. Have a qualified technician verify the open-load diagnostic for each coil
   on a protected motor fixture. Do not deliberately operate with a coil
   disconnected unless independent phase-current protection suitable for the
   motor is in place: if the diagnostic misses the open circuit, the firmware
   will automatically enter StealthChop. Open-load flags are not a safety-rated
   continuity test, and a passing check does not guarantee both coils will
   remain connected.
6. Use a protected, torque-limited test fixture with known end stops to tune
   `stall_threshold`, speed and current. Do not hold the rotating shaft by
   hand. The `StallGuard Result` sensor samples during motion; lower values
   generally indicate more load and DIAG is asserted when
   `SG_RESULT <= 2 * SGTHRS`. The displayed sample may not be the exact
   value at the stop. Adjust the threshold so normal running stays above the
   trigger while stop contact reliably triggers it; repeat with realistic
   loads, temperature and protected supply voltages. The available separation
   may be insufficient.
7. With the downstream drain safely contained, install the coupling and
   repeatedly verify boot from both ends and intermediate positions, then
   open and close. Check both actual end stops, travel counts, torque, driver
   and motor temperature. Verify the motor stays disabled at rest. Test a
   deliberately early obstruction, missing DIAG, open interlock, disconnected
   UART and a stopped movement: each must leave position `Unknown`, motor
   disabled and an explanatory fault. Restore power normally and retest.

If a boot from an already-closed or already-open valve fails, leave it in
fault and investigate; don't bypass the limit or raise current indiscriminately.
These tests establish behavior for the tested assembly, not leak-tightness or
functional-safety certification.

## ESPHome and Home Assistant

Put `enc_key`, `ota_pwd`, `wifi_ssid`, `wifi_password` and `ap_pwd` in the
existing ignored `esphome/config-esp/secrets.yaml`. From the repository root:

```sh
cd esphome
docker compose run --rm esphome config /config/waste-water-valve.yaml
docker compose run --rm esphome compile /config/waste-water-valve.yaml
```

Use the ESPHome dashboard to install the firmware built with **your** secrets,
initially via USB and then via OTA. On macOS, the container may not have direct
USB access; download the factory image from the dashboard and use a local
ESPHome-supported flasher. Follow the USB/VM sequencing precautions in the
wiring guide. Do not flash a validation build made with dummy secrets.

Add the discovered ESPHome device in Home Assistant. It exposes **Open**,
**Close**, **Stop**, **Home Retry**, **Position**, **Fault**, **Position
Inferred**, and **StallGuard Result**. The position text is the authoritative
software status: `Homing`, `Opening`, `Closing`, `Open`, `Closed`, or
`Unknown`. `Position Inferred` means the last stop was inferred, not physically
verified. The status sensor reports `Unknown` after a fault or stop.

For a single open/close/stop card with an actual unknown state, copy
[waste_water_valve_template.yaml](../../../hass-config/waste_water_valve_template.yaml)
to the active Home Assistant configuration directory. If there is no existing
`template:` key in `configuration.yaml`, add:

```yaml
template: !include waste_water_valve_template.yaml
```

On this project's Termux installation the active directory is typically
`/data/data/com.termux/files/home/.suroot/.homeassistant` or
`/data/data/com.termux/files/home/.homeassistant`; confirm which one the running
instance uses. If `template:` already exists, merge the list item into its existing include
instead of adding a duplicate key. Verify the ESPHome entity IDs in Developer
Tools; change the sensor/button IDs in the example if HA assigned different
ones. Check the HA configuration and reload template entities or restart HA.
The card is a Home Assistant **cover** used as a valve control; the direct
ESPHome buttons and position/fault sensors work without the template. The
wrapper deliberately does not optimistically claim a position. It becomes
unavailable if the ESPHome position sensor is unavailable and unknown during
homing or a fault.

## Stop, recovery and rollback

Open the physical STOP contact to disable the driver independently of the
ESP and network. A software Stop or latched fault does **not** prevent the
next reboot from attempting homing. If needed, use the manual downstream
shutoff/cap and contain wastewater before inspecting the valve.

To leave the controller disabled across reboots, open the STOP contact, change
`commissioned` back to `"false"`, rebuild and flash using the normal supply
sequencing. Confirm EN remains HIGH and the fault reports `Not commissioned`.
After an unexpected fault, inspect power, wiring and the mechanism before
using Home Retry; it initiates another bounded opening followed by homing.
Disconnect and discharge supplies in the order described in the wiring guide
before rewiring. The physical STOP contact does not isolate electrical power.

## Software tests

These are simulations, not a hardware test. From the repository root:

```sh
clang++ -std=c++17 -Wall -Wextra -Werror -pedantic \
  esphome/tests/waste_valve_test.cpp -o /tmp/waste-valve-test
/tmp/waste-valve-test
clang++ -std=c++17 -Wall -Wextra -Werror -pedantic -I esphome/tests/stubs \
  esphome/tests/waste_valve_driver_test.cpp -o /tmp/waste-valve-driver-test
/tmp/waste-valve-driver-test
```

References: [TMC2209 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/TMC2209_datasheet_rev1.09.pdf),
[MKS TMC2209 V2.0 schematic and pinout](https://github.com/makerbase-mks/MKS-StepStick-Driver/tree/master/MKS%20TMC2209/MKS%20TMC2209%20V2.0_001),
[Watterott TMC2209 pinout](https://learn.watterott.com/silentstepstick/pinconfig/tmc2209/),
and [power sequencing](https://learn.watterott.com/silentstepstick/pinconfig/).
