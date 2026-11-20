# Simax 3D 17HS4401 Waste Valve – Quick Reference & Commissioning

## Motor Specs at a Glance

| Spec | Value |
|------|-------|
| **Holding Torque** | 42–43 N·cm (300 oz-in) @ 1.7 A peak |
| **Step Angle** | 1.8° (200 steps/rev) full step |
| **Phase Resistance** | ~1.5–1.65 Ω per coil |
| **Rated Current** | 1.7 A peak per phase |
| **Supply Voltage** | 12 V vehicle battery (via protection stage) |
| **4-Wire Config** | Bipolar; coil pair resistance ~1.5 Ω each |

## Current Configuration in YAML

```yaml
run_current: "1.2"          # RMS current; strong reliable torque
stepper_speed: "600"        # steps/s (1/16 microstepping = ~3 RPM equivalent)
stepper_acceleration: "6000"  # steps/s²; smooth ramp
stall_threshold: "50"       # TCOOLTHRS; tune 20–80 during commissioning
```

### Why 1.2 A Instead of Lower Current?
- Motor rated for 1.7 A peak; 1.2 A RMS operates safely in mid-range
- Valve operates ~once per 2 days; **infrequent operation** (not continuous duty)
- **1.2 A provides ~35 N·cm torque** — strong margin for reliable actuation
- **Simplifies tuning:** Less risk of stall detection issues, more forgiving to load variations
- **Thermal:** Even at 1.2 A, motor stays cool (discrete 2–4 second pulses)

## Pre-Power Checklist

✓ **Motor windings verified with ohmmeter**
  - Coil A (1A–1B): ~1.5 Ω
  - Coil B (2A–2B): ~1.5 Ω
  - Between different coils: open circuit

✓ **Wiring correct**
  - 12 V → fuse → automotive protection → driver VM
  - Motor coils → driver 1A/1B and 2A/2B
  - UART TX (GPIO4) → 1 kΩ resistor → UART pin on driver
  - UART RX (GPIO5) → direct → UART pin on driver
  - EN line → STOP switch → driver EN pin
  - DIAG (bottom pad, 3rd from EN) → GPIO6

✓ **Power sequencing verified** (with meter)
  - VM before VDD rises ✓
  - VDD after VM falls ✓

✓ **`commissioned: "false"` in YAML**

## First Power-Up Steps

### 1. **Power On with STOP Switch Open**
```
[Apply 12 V with STOP open]
→ ESP32-C3 boots
→ UART console shows: "waste_valve: mode=FAULT (not commissioned)"
→ Motor unpowered (EN is HIGH via pull-up)
```

### 2. **Close STOP Switch** (carefully)
```
[Close switch to enable motor]
→ UART console: "motor enabled, homing on next command"
→ You may hear a subtle coil vibration (normal)
→ Motor is NOT moving yet; awaiting command
```

### 3. **Click "Home Retry" Button**
Open the ESPHome dashboard, find "Waste Water Valve" device → **Home Retry** button:
```
→ Motor travels ~10% toward open (release_steps = 80)
→ Then slowly closes (toward stall)
→ ESPHome logs show StallGuard edges
→ Position updates to "CLOSED" when stall detected
→ "Position Inferred" = true
```

**If homing fails:**
- Check UART output: `StallGuard Result` should show rising/falling edges
- If no stall edges: adjust `stall_threshold` (lower = earlier stall detection)
- If stall detected but position doesn't update: check firmware logic

### 4. **Test Open/Close**
- Click "Open" button → smooth travel toward open end
- Click "Close" button → smooth travel back to stall
- Click "Stop" button → motor stops mid-travel
- Verify smooth acceleration; no jerking

## Tuning Checklist

### Stall Threshold (TCOOLTHRS)
| Symptom | Action |
|---------|--------|
| No stall detected (homing never completes) | **Decrease** stall_threshold (e.g., 50 → 30) |
| False stalls (motor stops early, mid-travel) | **Increase** stall_threshold (e.g., 50 → 70) |
| Unreliable homing (sometimes works, sometimes doesn't) | Decrease by 5 and re-test |

**Method:**
1. Edit `waste-water-valve.yaml`, change `stall_threshold: "50"` to new value
2. Recompile and flash firmware
3. Close STOP switch, click "Home Retry"
4. Observe ESPHome console for `StallGuard Result` sensor; should show edges when motor stalls
5. Repeat until reliable

### Motor Speed & Acceleration
| Parameter | Meaning | Typical Range |
|-----------|---------|---|
| `stepper_speed` | Max step rate (1/16 microstepping) | 400–1000 steps/s |
| `stepper_acceleration` | Ramp rate | 4000–10000 steps/s² |

**Recommendation:** Leave at 600 / 6000 for waste valve. If motor stalls on startup, reduce `stepper_acceleration` to 3000.

### Travel Distance
- Edit `travel_steps: "800"` to match actual valve stroke
- Use "Open" button → monitor step count in logs
- Adjust until valve reaches full extension without binding
- Typical range: 600–1200 steps depending on waste valve model

## Normal Behavior

### At Rest (Stationary)
- Motor is **deenergized** (EN HIGH after movement)
- Position remains "CLOSED" or "OPEN"
- Current draw: ~0 mA from 12 V for the motor
- No active holding torque is required for this valve

### During Travel
- Motor accelerates for ~0.5 s, travels at max speed for ~1 s, decelerates for ~0.5 s
- Total travel time (both open and close): ~2–4 seconds
- Current draw during move: ~90 mA from 12 V
- Homing sequence (release + close + stall detection): ~3 s total

### Stall Detection (Homing)
- Motor slows as valve closes toward mechanical stop
- Load increases; coil current spikes; StallGuard detects congestion
- TMC2209 pulls DIAG line LOW (brief pulse)
- Firmware counts edges; when threshold crossed → homing complete
- Position saved to NVS (survives power loss)

## Wiring Summary (17HS4401 to MKS TMC2209 V2.0)

```
Motor (4-wire pigtail):
  Coil A (Red–Green)   → 1A, 1B on driver
  Coil B (Blue–Black)  → 2A, 2B on driver

ESP32-C3 Super Mini:
  GPIO0   → STEP
  GPIO1   → DIR
  GPIO3   → STOP switch → EN (with pull-up on board)
  GPIO4   → UART TX (1 kΩ resistor) → UART on driver
  GPIO5   → UART RX (direct) → UART on driver
  GPIO6   → DIAG (bottom pad on driver)
  GPIO7   → EN feedback (for fault detection)
  GND     → Driver GND, motor return

Power:
  12 V (protected) → Driver VM
  12 V (buck conv) → ESP 5V
  3.3V (ESP)       → Driver VDD
  Battery GND      → Common ground
```

## Common Issues & Fixes

| Issue | Likely Cause | Fix |
|-------|---|---|
| Motor hums but doesn't move | Stall immediately (mechanical jam or coil mismatch) | Check coil wiring; measure resistance; verify mechanical engagement |
| Homing never completes | TCOOLTHRS too high (stall never detected) | Reduce `stall_threshold` by 10; re-test |
| Motor stops mid-travel randomly | TCOOLTHRS too low (false stalls) | Increase `stall_threshold` by 5; re-test |
| Motor overheats after 30 s | run_current too high | Reduce to 0.7 A; check for mechanical friction |
| Coil resistance 2.5 Ω (not 1.5 Ω) | Different Simax 3D variant | Recalculate current: `new_A = 0.9 × (1.5 / 2.5) = 0.54 A` |
| STOP switch doesn't stop motor | GPIO3 not connected, or EN wiring broken | Verify GPIO3 → STOP → EN chain with meter |

## Test & Validation Commands (ESPHome YAML)

After commissioning, add these to validate performance:

```yaml
# Add to waste-water-valve.yaml for testing
# (Remove before final deployment to reduce memory usage)

button:
  # ...existing buttons...
  
  - platform: template
    name: "Test 100 Steps Open"
    icon: mdi:test-tube
    on_press:
      - stepper.set_target:
          id: valve_motor
          target: 100
      - delay: 2s
      - lambda: |-
          int pos = id(valve_motor).current_position;
          ESP_LOGI("test", "Reached position: %d steps", pos);
```

## Next Steps

1. **Commission the motor** using the checklist above
2. **Tune `stall_threshold`** during first homing tests
3. **Measure actual travel distance** and update `travel_steps` if needed
4. **Set `commissioned: "true"` in YAML** only after reliable operation confirmed
5. **Document your final settings** in this file for future reference

---

**Commissioning Date:** ___________  
**Final stall_threshold:** ___________  
**Final travel_steps:** ___________  
**Notes:** _________________________________________________________

---

For detailed specifications, see: [NEMA17-17HS4401-SPECIFICATIONS.md](./NEMA17-17HS4401-SPECIFICATIONS.md)
