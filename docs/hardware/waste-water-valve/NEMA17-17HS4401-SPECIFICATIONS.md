# Simax 3D NEMA 17 Stepper Motor 17HS4401 – Specifications & Configuration

## Motor Specifications

### Physical Characteristics
| Parameter | Value | Unit |
|-----------|-------|------|
| **Model** | 17HS4401 (Simax 3D variant) | — |
| **Type** | NEMA 17 Bipolar Stepper | — |
| **Body Length** | 40 mm | — |
| **Flange Size** | 42 × 42 mm (NEMA 17 standard) | — |
| **Shaft Diameter** | Ø5 mm | — |
| **Shaft Length** | 20 mm | — |
| **Mounting** | 4-hole pattern (M3 screws, 0.5 N·m max torque) | — |
| **Lead Wire Length** | 100–300 mm (4-wire pigtail) | — |
| **Mass** | ~250–280 g | — |
| **Rotor Inertia** | ~54 g·cm² | — |
| **Insulation Class** | B (max winding temp 130 °C) | — |

---

## Electrical Characteristics

### Winding & Resistance
| Parameter | Value | Notes |
|-----------|-------|-------|
| **Number of Phases** | 2 (bipolar) | Dual coils, 4 wire terminals |
| **Step Angle (full step)** | 1.8° | 200 steps per revolution |
| **Phase Resistance** | 1.5–2.8 Ω per phase | Varies by variant; typical ~1.65 Ω |
| **Inductance** | 2.8 mH per phase | ±20% tolerance; affects microstepping smoothness |
| **Rated Current (max)** | 1.7 A per phase | Peak; typical RMS ~0.8–1.0 A steady |
| **Phase Voltage (nominal)** | 2.6–2.8 V RDC | At rated current |
| **Supply Voltage Range** | 3.5–12 V | Recommended 5–12 V for vehicle use |

### Holding & Dynamic Torque
| Parameter | Value | Speed | Notes |
|-----------|-------|-------|-------|
| **Holding Torque** | 42–43 N·cm (0.42–0.43 N·m) | Stationary (0 RPM) | With 1.7 A per phase, energized, unmoving |
| **Pull-in Torque** | ~0.20 N·m | ≤ 300 RPM (half-step) | Max torque before losing sync without acceleration |
| **Dynamic Torque** | ~0.35 N·m @ 100 RPM | Full speed range varies | Decreases with speed |
| **Detent Torque** | ~0.22 N·m | Motor unpowered | Residual magnetic resistance |

### Thermal & Operating Conditions
| Parameter | Value | |
|-----------|-------|---|
| **Max Winding Temperature Rise** | 80 °C above ambient | At rated current, continuous |
| **Operating Temperature Range** | –20 °C to +80 °C | Storage: –30 °C to +60 °C |
| **Humidity** | 5–95% non-condensing | — |
| **Dielectric Strength** | 500 V AC / 1 min | — |

---

## 4-Wire Pinout (Standard Color Coding)

### Wire Pairs (Coil Assignment)
The 17HS4401 uses a standard 4-wire configuration with two independent coils:

| Coil | Wire 1 | Wire 2 | Resistance | Color (Common) |
|------|--------|--------|-----------|---|
| **A** (1A/1B on driver) | A+ | A− | ~1.5 Ω | Red / Green |
| **B** (2A/2B on driver) | B+ | B− | ~1.5 Ω | Blue / Black |

**Verification Method:**
- Use an ohmmeter to measure resistance between wire pairs.
- Each coil pair reads ~1.5 Ω (Simax variant may be ~2.5 Ω).
- Between different coils: open circuit (no connection).
- Wire color coding **varies by manufacturer**; always verify with an ohmmeter.

---

## Driver Compatibility & Configuration

### Recommended Driver: MKS TMC2209 V2.0
The current build uses the **MKS TMC2209 V2.0**, which is **fully compatible** with the 17HS4401:

| Aspect | TMC2209 Rating | Motor Requirement | Status |
|--------|---|---|---|
| **Supply Voltage (VM)** | 4.75–29 V | 3.5–12 V | ✓ Compatible (use 12 V) |
| **Peak Current per Phase** | Up to 2 A | 1.7 A max | ✓ Safe (current limiting recommended) |
| **Microstepping** | Up to 1/256 | 1/16 recommended | ✓ Supported |
| **UART Control** | Full SPI/UART | Yes | ✓ Enabled in firmware |
| **Stall Detection (StallGuard4)** | Built-in | Supported (tuning needed) | ✓ Enabled in firmware |

### Current Limiting & Operating Point
- **Operating current:** 1.2 A RMS (valve operates infrequently, ~once per 2 days)
- **Holding current:** 0.5 A RMS (minimal standby since operation is discrete)
- **Rationale:** Rather than power-saving optimization, prioritize **reliable torque** for infrequent but critical operations
- **Expected holding torque at 1.2 A:** ~35 N·cm (waste valve load ~4–5 N·cm → 7:1 safety margin)
- **Thermal performance:** 1.2 A on discrete 2–4 second pulses causes negligible heating; well below motor limits

### Bipolar Stepper Driver Operation
The TMC2209 drives the 17HS4401 in **bipolar mode**:
- **STEP signal:** One pulse = one microstep (1/16 microstepping)
- **DIR signal:** Direction selection (forward = open, reverse = close, or inverted)
- **EN (Enable):** Active-LOW; pull to GND to energize, HIGH/open to deenergize
- **Current limiting:** Controlled via UART register `IRUN` (running) and `IHOLD` (holding)
- **Microstepping:** 1/16 is smooth and recommended for valve travel

---

## Recommended Configuration Parameters

### ESPHome YAML Substitutions (Updated for 17HS4401)

```yaml
substitutions:
  commissioned: "false"
  direction_inverted: "false"
  travel_steps: "800"              # 200 full steps × 4 microsteps = 800; tune to actual valve range
  release_steps: "80"              # ~10% margin for homing safety
  min_home_steps: "16"             # Minimum 1 full step for stall detection
  min_travel_percent: "80"         # Allow 80–120% overshoot detection
  max_travel_percent: "120"
  phase_timeout_ms: "15000"        # 15 s total phase timeout for full travel + homing
  stepper_speed: "600"             # steps/s; 600 = 3 rev/s (prudent for waste valve)
  stepper_acceleration: "6000"     # steps/s²; smooth acceleration
  
  # TMC2209 V2.0 Configuration
  tmc_address: "0"                 # MS1/MS2 both tied to GND
  stall_threshold: "50"            # TCOOLTHRS trigger; tune on commissioning
  sense_resistance: "0.11"         # MKS V2.0 onboard sense resistors (R6/R7)
  run_current: "1.2"               # A RMS; reliable torque for infrequent valve operation
```

### Firmware Current Limits (IRUN / IHOLD)

For TMC2209 UART control, current is set via 5-bit `IRUN` and `IHOLD` registers:
- **IRUN = 0–31** (0x00–0x1F), maps to 0–max_current
- **Calculation:** `IRUN_value = (desired_RMS_current / 2.0) × 31`

| Desired Current | Register Value | Notes |
|---|---|---|
| 1.2 A (running) | ~19 | Recommended for 17HS4401 in this waste valve |
| 1.7 A (peak) | 26+ | Use only for brief heavy load; causes heat |

**Example UART Write (pseudocode):**
```c
// Set IRUN=19 (~1.2 A RMS), IHOLD=19 while enabled
uint32_t ihold_irun = (0x13 << 8) | (0x13);
write_register(TMC2209_ADDR_IHOLD_IRUN, ihold_irun);
```

---

## Performance Expectations

### Speed & Acceleration
| Scenario | Speed | Acceleration | Duration | Notes |
|----------|-------|--------------|----------|-------|
| **Smooth Full Open** | 600 steps/s | 6000 steps/s² | ~2–4 s | Full travel at 800 steps |
| **Smooth Full Close** | 600 steps/s | 6000 steps/s² | ~2–4 s | From open to stall detection |
| **Home from Mid-Travel** | 600 steps/s | 6000 steps/s² | ~1–2 s | Release + homing sequence |
| **Homing (slow stall detect)** | 200 steps/s | 2000 steps/s² | ~500 ms | Reduced speed for reliable stall |

### Power Consumption (Approximate)
| State | Current @ 12 V | Power | Duration | Notes |
|-------|---|---|---|---|
| **Idle (deenergized)** | ~0 mA | ~0 W | Continuous | EN = HIGH; motor unpowered |
| **Moving (IRUN = 1.2 A)** | ~90–120 mA | ~1.08–1.44 W | 2–4 s per stroke | Peak during acceleration |

### Torque Available vs. Speed
At 1.2 A RMS (IRUN=19):
- **0–100 RPM:** ~30 N·cm torque (sufficient for waste valve gravity + friction)
- **100–300 RPM:** ~20 N·cm torque (still adequate)
- **300+ RPM:** ~10 N·cm torque (less safety margin; not recommended)

**Recommendation:** Use 600 steps/s max for 1/16 microstepping (60 RPM full-step equivalent), leaving healthy torque margin.

---

## Commissioning Checklist

### Pre-Power Verification
- [ ] Coil pairs identified with ohmmeter (each ~1.5 Ω)
- [ ] Coil wires assigned to 1A/1B and 2A/2B on TMC2209
- [ ] Motor supply (12 V) protection installed (fuse, TVS, bulk capacitor)
- [ ] ESP32-C3 power sequenced correctly (VM before VDD)
- [ ] UART TX wired through 1 kΩ resistor; RX direct
- [ ] MS1/MS2 tied to GND; EN wired through STOP switch
- [ ] DIAG line connected to GPIO6
- [ ] `commissioned: "false"` in YAML

### Initial Power-Up
1. **With STOP switch open** (motor disabled), apply 12 V
   - LED/indicators light on ESP32-C3
   - UART debug output shows initialization
2. **Close STOP switch** carefully (enable motor)
   - Motor hums (you may hear mild coil vibration)
   - No movement yet (homing not started until firmware command)
3. **Issue "Home Retry" button** in ESPHome dashboard
   - Valve travels toward open end slightly (release_steps)
   - Then slowly closes (toward valve stop) until stall detected
   - Position updates to "Closed" when homing complete

### Tuning StallGuard Threshold
- **TCOOLTHRS (stall_threshold):** Adjust 20–80 until reliable stall detection
  - Too low: false stalls
  - Too high: motor stalls but firmware doesn't see it
- Commissioning log shows `StallGuard Result` sensor; adjust and re-test

---

## Alternative Drivers

If not using TMC2209, verify compatibility:

| Driver | Voltage | Max Current | Microstepping | UART/SPI | Stall Detection | Notes |
|--------|---------|---|---|---|---|---|
| **A4988** | 8–35 V | 2 A peak | 1/16 | No | No | Requires external logic; simpler |
| **DRV8825** | 6.5–45 V | 2.2 A | 1/32 | No | No | Similar to A4988 |
| **TMC2209** | 4.75–29 V | 2 A peak | 1/256 | Yes | StallGuard4 | **Recommended** (current build) |
| **TMC5160** | 5–34 V | 4 A peak | 1/256 | SPI | Yes | High-performance; overkill for this use |

---

## Datasheet Links & References

### Manufacturer Documentation
- **Simax 3D:** Check their product page for the exact 17HS4401 variant datasheet
- **Generic 17HS4401:** Multiple clones exist; verify DC resistance and inductance on your unit
- **Common Source:** Handsontec (17HS4401S), StepStick repositories

### Related Datasheets in Repository
- `docs/hardware/waste-water-valve/wiring.md` – MKS TMC2209 V2.0 wiring
- `esphome/config-esp/waste-water-valve.yaml` – Current firmware configuration
- `esphome/config-esp/waste_valve_tmc2209.h` – UART protocol implementation

---

## Troubleshooting

### Motor Hums but Doesn't Move
- **Cause:** Stall immediately (current too low, mechanical jam, or coil wiring)
- **Fix:** Increase `run_current` by 0.1 A increments; check mechanical engagement

### Unreliable Homing (stall not detected)
- **Cause:** `stall_threshold` too high or too low
- **Fix:** Watch `StallGuard Result` sensor; adjust TCOOLTHRS and re-home

### Motor Overheats Quickly
- **Cause:** `run_current` too high or duty cycle too long
- **Fix:** Lower to 0.7 A RMS; ensure `phase_timeout_ms` is reasonable

### Coil Resistance Differs from Spec
- **Cause:** Different Simax 3D variant or worn motor
- **Fix:** Recalculate `run_current` as: `desired_A = nominal_spec_A × (nominal_Ω / measured_Ω)`

---

## Safety Notes

⚠ **Waste Valve is Not an Emergency Stop**
- Stopping mid-travel leaves the valve open or closed; no intermediate "safe" position
- STOP switch disables motor power but does not provide certified emergency function
- For emergency dump, a separate solenoid or manual valve override is recommended

⚠ **Vehicle Power Transients**
- A 12 V camper battery can dip to 8 V during cranking or spike to 20 V on load dump
- Always use automotive-grade surge protection (TVS diode + bulk capacitor) at VM
- Monitor VDD sequencing: ensure VM rises before VDD, falls after VDD removal

⚠ **Connector Security**
- Four-wire pigtail connector is **not** keyed; always power down before disconnecting
- Pulling the connector hot can damage the driver or motor windings
- Strain-relieve all connections near the motor

---

## Configuration Summary: 17HS4401 Implementation

| Parameter | Value | Notes |
|-----------|-------|-------|
| **run_current** | 1.2 A RMS | Strong torque; valve operates infrequently (~2 days) |
| **stepper_speed** | 600 steps/s | 37.5 RPM full-step equivalent; smooth operation |
| **stepper_acceleration** | 6000 steps/s² | Smooth ramp; no shock loading |
| **travel_steps** | 800 (tune) | Adjust to actual valve range after commissioning |
| **stall_threshold** | 50 (tune 20–80) | Calibrate during first homing; watch StallGuard Result sensor |
| **phase_timeout_ms** | 15000 | 15 s total timeout for full cycle |

---

**Document Version:** 1.0  
**Motor Model:** Simax 3D NEMA 17 17HS4401  
**Driver:** MKS TMC2209 V2.0  
**Operating Mode:** Infrequent discrete operation (~once per 2 days)
