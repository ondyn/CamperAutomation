# HymerTest Sensors Unavailable - Root Cause & Fix (2026-05-15)

## Problem Summary
After phone restart with hotspot enabled, HymerTest ESPHome sensors showed as "Unavailable" in Home Assistant with connection timeout error:
```
Can't connect to ESPHome API for hymertest @ 10.129.28.201: Timeout while connecting
```

## Root Cause Analysis  
**Primary Issue:** `iproute2` package was missing from Termux
- The Magisk boot script `/data/adb/service.d/80-hotspot-on-boot.sh` uses `ip` command to pin wlan1 to fixed subnet `10.129.28.1/24`
- Without `iproute2` installed, the `ip` command was unavailable
- The script silently failed to pin the subnet
- Android hotspot fell back to default subnet (likely `192.168.43.x` instead of expected `10.129.28.x`)
- ESPHome static IP config `10.129.28.201` became unreachable
- HA integration timeout followed

**Secondary Issue:** HA integration was hard-coded to static IP rather than using robust mDNS discovery

## Fixes Applied

### 1. ✅ Install iproute2 in Termux
```bash
apt install -y iproute2
```
Status: **COMPLETED** on 2026-05-15 11:50 UTC

### 2. ✅ Update HA Integration to Use mDNS Hostname
Changed HA config entry from:
- `"host":"10.129.28.201"` 
To:
- `"host":"hymertest.local"`

File: `~/.homeassistant/.storage/core.config_entries`

Status: **COMPLETED** - Backup saved to `core.config_entries.backup`

### 3. 🔄 ESPHome Config Updated (Optional but Recommended)
Added explicit mDNS service advertisement to `/config/esphome/config-esp/hymertest.yaml`:
```yaml
# Enable mDNS service advertisement for discovery
mdns:
  disabled: false
```

Note: mDNS is enabled by default in ESPHome, so existing firmware should already support this. However, explicit config is good practice.

## Validation Checklist

### Phase 1: Immediate Fix (No Reboot Required)
```bash
# SSH into phone and verify:

# 1. Check iproute2 is installed
pkg list-installed | grep iproute2
# Expected: iproute2 listed

# 2. Verify ip command is available
which ip
# Expected: /data/data/com.termux/usr/bin/ip

# 3. Check HA config was updated
grep -o '"host":"[^"]*"' ~/.homeassistant/.storage/core.config_entries | head -1
# Expected: "host":"hymertest.local"

# 4. Check HA logs for mDNS/hostname connection attempts
tail -50 ~/.homeassistant/home-assistant.log | grep -i hymertest
```

### Phase 2: Subnet Pinning Fix (Requires Phone Reboot)
To ensure hotspot is pinned to correct subnet on next boot:

```bash
adb shell # From laptop
su -c 'ls -l /data/adb/service.d/80-hotspot-on-boot.sh'
# Expected: Script exists in /data/adb/service.d/

# If script not there (still in fallback):
su -c 'mkdir -p /data/adb/service.d && cat /sdcard/Download/80-hotspot-on-boot.sh > /data/adb/service.d/80-hotspot-on-boot.sh && chmod 755 /data/adb/service.d/80-hotspot-on-boot.sh'
```

Then **reboot phone** so Magisk service runs boot script during startup.

After reboot, verify hotspot subnet:
```bash
# In Termux on phone:
cat /proc/net/dev | grep wlan1
# And check IP info (may need additional tools if ip command limited to root)
```

### Phase 3: Firmware Flash (If mDNS Still Not Working)
Pre-built updated firmware with explicit mDNS support pending Docker build fix.  
To compile and flash:
```bash
cd ~/CamperAutomation/esphome
docker-compose up -d esphome
# Wait for dashboard at localhost:8889
# Build hymertest.yaml via dashboard
# Flash to device via USB or OTA
```

## Expected Outcome After Reboot
1. **Phase 1** (no reboot): HA will attempt to resolve `hymertest.local` via mDNS
2. **Phase 2** (with reboot): Hotspot will be pinned to `10.129.28.1/24` subnet
3. **Phase 3** (firmware update): Explicit mDNS advertisement ensures reliable discovery

## Network Path Summary
```
Phone (Termux/HA) 
  ↓ (mDNS lookup)
ESPHome Device (hymertest.local)
  ↓ (WiFi connection to hotspot)
Hotspot (wlan1, pinned to 10.129.28.1/24)
  ↓ (API connection on port 6053, encrypted)
HA ESPHome Integration
```

## Files Modified
- `/data/data/com.termux/files/home/` → `iproute2` installed
- `~/.homeassistant/.storage/core.config_entries` → host changed from IP to hostname
- `/Users/ondrejhnyk/Documents/CamperAutomation/esphome/config-esp/hymertest.yaml` → mDNS explicitly enabled

## Prevention for Future Boots
After reboot validation passes, ensure:
1. Magisk boot script is in `/data/adb/service.d/` (not just fallback location)
2. iproute2 remains installed (persist in Termux setup docs)
3. mDNS remains enabled in all ESPHome configs
4. HA integrations use hostname discovery rather than static IPs when possible
