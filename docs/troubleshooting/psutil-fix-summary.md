# Python-psutil Package Unavailable - Root Cause and Fix

## Issue Summary
The provisioning pipeline failed at `provisioning/adb/03b_push_termux_bootstrap.sh` (Step 8) with:
```
E: Unable to locate package python-psutil
FATAL ERROR: bootstrap_termux.sh failed via ADB
```

## Root Cause
The Termux APT repository **no longer provides the `python-psutil` package** (previously locked at v7.2.2). This package was critical because:

1. **Home Assistant requires psutil** for system monitoring
2. **Upstream psutil (v7.x) does not support Android** due to platform limitations
3. **Termux provided a pre-built native version** to bypass the source build issue
4. **The package has been removed from official Termux repos** (likely due to maintenance burden)

Evidence:
- Lock file shows: `python-psutil=7.2.2` (no longer available)
- Mirror responds with `ok` but package not found in apt cache
- Current Termux repos verified lack this package

## Solution Implemented
Modified provisioning scripts to gracefully handle the missing package:

### 1. **Remove python-psutil from APT bootstraps** (provisioning/termux/bootstrap_termux.sh)
   - Removed `python-psutil` from `BASE_PACKAGES` array
   - Added inline comment explaining the removal
   - Allows bootstrap to complete without the unavailable package

### 2. **Add fallback pip installation** (provisioning/ssh/10_install_homeassistant_core.sh)
   - Check if psutil exists in system site-packages (for legacy installs)
   - Track whether found with `_psutil_found` flag
   - If not found, attempt `pip install psutil` with warning
   - Similar handling added for grpcio (for consistency)

### 3. **Improved resilience**
   - Scripts no longer fail if system packages aren't present
   - Allows pip/uv to attempt installation later
   - Includes clear warnings for troubleshooting

## Files Modified
1. `/Users/ondrejhnyk/Documents/CamperAutomation/provisioning/termux/bootstrap_termux.sh` (line ~104)
2. `/Users/ondrejhnyk/Documents/CamperAutomation/provisioning/ssh/10_install_homeassistant_core.sh` (lines ~328-345)

## Next Steps

### Option A: Full Rerun (Clean Slate)
```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/00_run_all_adb_steps.sh
```
Bootstrap will now skip python-psutil and proceed.

### Option B: Rerun from Bootstrap Step
If you want to retry just the bootstrap/SSH phases:
```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/00_run_all_adb_steps.sh --skip-debloat --skip-hotspot
```

### Option C: Manual SSH-Only Install (if APKs already installed)
If APKs are already on the phone:
```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/ssh/10_install_homeassistant_core.sh
```

## Verification
After running provisioning, verify Home Assistant can start:
```sh
ssh -p 8022 user@localhost
# Inside phone:
./hass.sh start
# Check Home Assistant is listening:
sleep 5 && netstat -tlnp | grep 8123
```

## Risk Assessment
**Low Risk**: Changes are additive (fallback handling) and backward compatible. If psutil somehow becomes available again via system packages, it will be used. If not, pip will attempt to install.

**Remaining Known Risk**: If no suitable psutil wheel is available for the platform, Home Assistant may still fail at runtime. This would manifest when trying to start HA, not during provisioning.

## Future Considerations
- Monitor Termux psutil availability
- Consider using a pre-built wheel repository
- Evaluate if a custom fork of psutil for Android is maintained elsewhere
- Add CI test to verify bootstrap works without system psutil
