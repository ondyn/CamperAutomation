# Simax 3D NEMA 17 17HS4401 Waste Valve – Implementation Guide

## Quick Facts

| Spec | Value |
|------|-------|
| **Motor** | Simax 3D NEMA 17 17HS4401 |
| **Holding Torque** | 42–43 N·cm @ 1.7 A peak |
| **Recommended Current** | 1.2 A RMS (running) |
| **Operating Pattern** | Infrequent (~once per 2 days max) |
| **Configuration Approach** | High torque during movement, deenergized idle for power saving |

---

## Implementation Files

### Configuration
**[esphome/config-esp/waste-water-valve.yaml](../../esphome/config-esp/waste-water-valve.yaml)**
```yaml
run_current: "1.2"          # A RMS; strong torque for reliable actuation
```

### Specifications & Technical Reference
**[NEMA17-17HS4401-SPECIFICATIONS.md](./NEMA17-17HS4401-SPECIFICATIONS.md)**
- Motor electrical & mechanical specs
- Current limiting calculations
- Torque availability at operating current
- Wiring pinout and verification
- Driver compatibility

### Commissioning & Testing
**[COMMISSIONING-GUIDE-17HS4401.md](./COMMISSIONING-GUIDE-17HS4401.md)**
- Pre-power checklist
- First power-up procedure (15–20 minutes)
- Homing validation
- StallGuard tuning
- Troubleshooting reference

### Code Helper
**[waste_valve_17hs4401_current_limits.h](../../esphome/config-esp/waste_valve_17hs4401_current_limits.h)**
- C++ current profile definitions
- TMC2209 register calculation helper
- Optional firmware enhancements

---

## Why 1.2 A (Not Lower)?

**Operating Context:** Valve opens ~once per 2 days (discrete 2–4 second pulse)

**Decision:**
- **1.7 A peak rated** → 1.2 A RMS is mid-range safe operation
- **~35 N·cm available torque** vs ~4–5 N·cm waste valve load → **7:1 safety margin**
- **Thermal:** Discrete pulses cause no overheating; motor stays cool
- **Reliability:** Higher current simplifies tuning, less sensitive to mechanical variations
- **Practical:** Valve reliability > battery power optimization for infrequent operation

---

## First Time Power-Up

### Pre-Power (5 min)
1. Read [COMMISSIONING-GUIDE-17HS4401.md](./COMMISSIONING-GUIDE-17HS4401.md)
2. Verify motor coil pairs with ohmmeter (~1.5 Ω each)
3. Check wiring against [wiring.md](./wiring.md)

### Power-Up (10 min)
1. Apply 12 V with **STOP switch OPEN** (motor disabled)
   - ESP32-C3 boots; UART output appears
2. **Close STOP switch** (enable motor)
   - Motor ready for command
3. Click **"Home Retry"** button in ESPHome dashboard
   - Motor travels ~10% toward open
   - Closes until stall detected
   - Position updates to "CLOSED"
4. Test **Open/Close/Stop** buttons
   - Verify smooth travel
   - Monitor motor temperature (warm ≈ OK)

### Tuning (5–10 min if needed)
1. Watch `StallGuard Result` sensor during homing
2. If no stall edges detected: **Lower** `stall_threshold` (50 → 30)
3. If false stalls: **Raise** `stall_threshold` (50 → 70)
4. Iterate until reliable homing

**Total:** 15–20 minutes to operational system

---

## Configuration Parameters

```yaml
# Motor current (1.2 A RMS provides ~35 N·cm torque)
run_current: "1.2"        # Strong torque; discrete operation

# Motion control
stepper_speed: "600"      # steps/s (37.5 RPM full-step equiv.)
stepper_acceleration: "6000"  # Smooth ramp

# Homing
stall_threshold: "50"     # Start here; tune during commissioning (20–80 range)
travel_steps: "800"       # Adjust to actual valve range after commissioning
```

---

## Expected Performance

| Scenario | Duration | Current | Status |
|----------|----------|---------|--------|
| Valve open (smooth travel) | 2–4 s | 1.2 A RMS | Smooth acceleration/deceleration |
| Valve close + homing | 3–5 s | 1.2 A → stall detect | Reliable closure with position confirmation |
| Idle (between operations) | — | ~0 A | Motor off (EN HIGH); no power |

---

## Wiring Reference

See [wiring.md](./wiring.md) for MKS TMC2209 V2.0 detailed pinout.

**Quick ESP32-C3 → Driver connections:**
- GPIO0 → STEP
- GPIO1 → DIR
- GPIO3 → STOP switch → EN (default) or direct EN (no-STOP variant)
- GPIO4 → UART TX (1 kΩ resistor)
- GPIO5 → UART RX (direct)
- GPIO6 → DIAG (stall detection)
- GPIO7 → EN feedback
- GND → Common ground

No-STOP wiring details and risks: [wiring.md](./wiring.md).

**Motor coils:**
- Coil A → Driver 1A/1B
- Coil B → Driver 2A/2B

---

## Troubleshooting

| Symptom | Quick Fix |
|---------|-----------|
| Motor hums, no movement | Verify coil wiring with ohmmeter (~1.5 Ω each) |
| Homing never completes | Lower stall_threshold (50 → 30); watch StallGuard Result sensor |
| False stalls during movement | Raise stall_threshold (50 → 70) |
| Motor overheats | Check mechanical friction; reduce current if thermal margin needed |
| STOP switch doesn't stop (if fitted) | Verify GPIO3 → STOP → EN continuity |

**Full troubleshooting:** See [COMMISSIONING-GUIDE-17HS4401.md](./COMMISSIONING-GUIDE-17HS4401.md)

---

## Next Steps

1. ✓ Read this page
2. ✓ Review [COMMISSIONING-GUIDE-17HS4401.md](./COMMISSIONING-GUIDE-17HS4401.md)
3. → Verify motor coils with ohmmeter
4. → Flash firmware with updated YAML
5. → Commission: Pre-power checklist → Power-up → Homing → Tuning
6. → Document final tuning values (stall_threshold, travel_steps)

---

**Ready to commission?** Start with [COMMISSIONING-GUIDE-17HS4401.md](./COMMISSIONING-GUIDE-17HS4401.md).

**Need technical specs?** See [NEMA17-17HS4401-SPECIFICATIONS.md](./NEMA17-17HS4401-SPECIFICATIONS.md).

**Wiring help?** See [wiring.md](./wiring.md).
