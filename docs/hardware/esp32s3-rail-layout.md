# ESP32-S3 One-Rail Board Placement (minimum jumper length)

This plan is based on photos in [hw](../../hw) and the active pin map in [docs/hardware/esp32s3-wiring-guide.md](esp32s3-wiring-guide.md).

## 1) Recommended left-to-right order on the rail

1. Input board (8-channel isolation board)
2. Terminal adapter with ESP32-S3-DevKitC-1 inserted
3. Output board (4-channel MOS board)
4. LIN converter (TJA1021 board)
5. Mobile charger P-MOS switch
6. LM2596 step-down (12V -> 5V)

Why this order:
- The terminal adapter stays central (most signal wires terminate there).
- Input board is immediately adjacent to minimize the dense input harness.
- Output + LIN + charger switch are on the other side, matching GPIO17/18/16 area and keeping noisy switched power away from high-impedance inputs.
- Step-down is at the edge near 12V feed and power distribution.

## 2) Orientation rule (important)

- Rotate each board so its *logic/control terminals* face the terminal adapter.
- Keep high-current/power terminals facing outward (away from the adapter).

Practical side selection from your photos:
- Input board: side labeled `IN1..IN8` faces adapter.
- Output board: side labeled `IN1..IN4` faces adapter.
- LIN board: side labeled `TX SLP RX GND` faces adapter.
- Charger switch: side labeled `Signal + / Signal -` faces adapter.
- Step-down: place so `OUT+ / OUT-` are easiest to bus to adapter 5V/GND.

## 3) Terminal adapter screw labels used in this plan

Use the silkscreen labels on the terminal-adapter board as truth (for example `17`, `18`, `16`, `7`, `19`, `38`, `47`, `1`, `2`, `6`, `20`, `5Vin`, `3V3`, `GND`).

Do not use strapping/risky pins for field wiring changes: `0`, `3`, `45`, `46`.

## 4) Exact adapter -> board wiring (internal harness)

### A) LIN converter

- Adapter screw `17` -> LIN board `RX` (logic side)
- Adapter screw `18` -> LIN board `TX` (logic side)
- Adapter screw `3V3` -> LIN board `SLP` (tie high; if your board wants control, route via spare GPIO later)
- Adapter screw `GND` -> LIN board `GND` (logic side)

LIN power/bus side (outward):
- 12V rail -> LIN board `VIN`
- Chassis/signal ground -> LIN board `GND`
- Truma LIN wire -> LIN board `LIN`
- `INH` optional (normally unused)

### B) Mobile charger P-MOS switch

Control side (toward adapter):
- Adapter screw `16` -> switch board `Signal Positive`
- Adapter screw `GND` -> switch board `Signal Negative`

Power side:
- Step-down `OUT+` -> switch board `DC+`
- Step-down `OUT-` -> switch board `DC-`
- switch board `OUT+` / `OUT-` -> phone charger input

### C) Output board control side (`IN1..IN4`)

Recommended channel assignment to match current ESPHome config:
- Adapter screw `38` -> Output board `IN1` (EBL30 ON pulse)
- Adapter screw `19` -> Output board `IN2` (EBL30 OFF pulse)
- Adapter screw `7` -> Output board `IN3` (Gas valve heater)
- Adapter screw `47` -> Output board `IN4` (Water pump)
- Adapter screw `GND` -> Output board control `GND`

Note: `INx`/`GND` exact screw positions depend on that board revision; follow its `IN1..IN4` silkscreen and keep one shared control ground.

### D) Input board control side (`IN1..IN8`)

Use the channels for binary inputs currently in config:
- Adapter screw `1` -> Input board `IN1` (Gas bottle primary/secondary)
- Adapter screw `2` -> Input board `IN2` (12V supply present)
- Adapter screw `6` -> Input board `IN3` (Mains 230V connected)
- Adapter screw `20` -> Input board `IN4` (Engine running D+)
- Adapter screw `4` -> Input board `IN5` (PIR)
- Adapter screw `5` -> Input board `IN6` (Rain; only if used as digital threshold)
- Adapter screw `GND` -> Input board control `G`

If rain is used as analog (`GPIO5` ADC), route rain sensor AO directly to adapter screw `5` (do not pass through optocoupler channel).

### E) 5V distribution from step-down

- 12V feed -> step-down `IN+`
- 12V ground -> step-down `IN-`
- step-down `OUT+` -> adapter screw `5Vin`
- step-down `OUT-` -> adapter screw `GND`

Then fan out 5V/GND from adapter or a PCT-218 power node to:
- Input board supply side (as needed by that board)
- Output board supply side (as needed by that board)
- Charger switch `DC+` / `DC-`

## 5) Harnessing with your 8-pin quick connectors

Recommended bundles:

- Quick-connector bundle QC-A (adapter -> input board):
  - `IN1`, `IN2`, `IN3`, `IN4`, `IN5`, `IN6`, `GND`, spare
- Quick-connector bundle QC-B (adapter -> output board):
  - `IN1`, `IN2`, `IN3`, `IN4`, `GND`, spare, spare, spare
- Keep LIN and charger control as separate short 2-4 wire looms.

## 6) Should you repin ESP32 for shorter wiring?

For this one-row hardware set, repinning is not required to get short internal wiring.

Current pin map is already constrained by:
- boot-safe pin usage,
- LIN UART on GPIO17/18,
- existing automations/entities,
- reserved flash/PSRAM/strap pins.

So: keep software pin map as-is, optimize by board placement and harness grouping.

## 7) Installation checks before power-on

1. Verify no external load is connected to adapter screws `0`, `3`, `45`, `46`.
2. Verify step-down output is adjusted to 5.0V before connecting ESP board.
3. Verify all board grounds are common.
4. Verify LIN logic side is 3.3V-compatible.
5. Boot with only internal interconnects first; then add external sensor/load harnesses.
