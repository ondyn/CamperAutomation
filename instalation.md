# Android + Termux + Home Assistant Core Installation (USB + SSH)

This document is a step-by-step process to automate installation as much as possible.

Flow:

1. USB + ADB phase from laptop.
2. Manual Magisk root phase (cannot be fully automated).
3. Minimal manual Termux first-run.
4. SSH phase from laptop for full provisioning.

---

## 1) Prerequisites on laptop

Install tools:

```sh
brew install android-platform-tools jq curl
```

Verify:

```sh
adb version
jq --version
```

Expected signal:

- `adb version` prints platform-tools version.
- `jq --version` prints version.

---

## 2) Prepare phone for USB provisioning

On phone:

1. Enable Developer options.
2. Enable USB debugging.
3. Connect by USB and accept RSA fingerprint prompt.
4. On Xiaomi/MIUI: enable `Install via USB` in Developer options.
5. On Xiaomi/MIUI: complete Xiaomi account login/verification if prompted while enabling `Install via USB`.

From laptop:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/01_check_phone.sh
```

Expected signal:

- Log file created in `provisioning/logs/` with model, SDK, ABI, lock state, root status.

---

## 3) Root phone with Magisk (manual checkpoint)

Use this guide:

- <https://droidwin.com/how-to-root-xiaomi-eu-rom-via-magisk/>

Why manual:

- Bootloader unlock, patched boot image flashing, and first Magisk grant are user-confirmed security actions and cannot be safely automated end-to-end.

After root is complete, verify:

```sh
adb shell su -v
```

Expected signal:

- A Magisk/su version is returned.

---

## 4) Run USB provisioning phase (orchestrated or step-by-step)

### Option A: Run all USB steps together

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/00_run_all_adb_steps.sh
```

This runs steps 4a–4e in sequence with unified logging.

### Option B: Run USB steps individually

#### 4a) Download correct APKs automatically (ABI-aware)

Script reads phone ABI/SDK and fetches latest compatible APKs:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/02_download_apks.sh
```

Downloads into `provisioning/apks/`:

- `termux.apk` (ABI-specific from Termux GitHub release)
- `termux-boot.apk`
- `magisk.apk`
- `home-assistant-companion.apk`

Notes:

- Termux package selection follows current Termux release assets from `termux/termux-app` and validates Android SDK >= 24.
- If you already rooted with another Magisk build, you can skip reinstalling Magisk APK.

---

### 4b) Install apps over ADB

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/03_install_apks.sh
```

Installs:

- Termux
- Termux:Boot
- Home Assistant Companion

Optional:

- If `provisioning/apks/automate.apk` exists, script installs Automate as well.

Important for Xiaomi/MIUI:

- If you see `INSTALL_FAILED_USER_RESTRICTED` or install cancel popups, enable `Install via USB` in Developer options.
- MIUI may require Xiaomi account sign-in/verification before allowing USB installs.

---

### 4c) Push Termux bootstrap script to phone storage

The orchestrator does this automatically. Manual command if needed:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/03b_push_termux_bootstrap.sh
```

This pushes `bootstrap_termux.sh` to:

- `/sdcard/Download/bootstrap_termux.sh`
- `/sdcard/Downloads/bootstrap_termux.sh`

Important:

- Open Termux once and run `termux-setup-storage` before relying on any `/sdcard` fallback path from inside Termux.
- In Termux, the same file is then available as `~/storage/downloads/bootstrap_termux.sh`.

---

### 4d) Configure hotspot autostart on rooted phone (Magisk service)

Install boot-time hotspot script:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/04_setup_hotspot_boot_magisk.sh
```

This installs:

- `/data/adb/service.d/80-hotspot-on-boot.sh`

If the script reports `Permission denied` while writing `/data/adb/service.d` from `adb shell`, that is a device-policy limitation on some Xiaomi/Magisk builds. In that case the script stages a fallback copy at `/sdcard/Download/80-hotspot-on-boot.sh` and prints an exact Termux command to run with `su` on the phone.

For that fallback to work from Termux, run `termux-setup-storage` first so `/sdcard/Download/` is visible as `~/storage/downloads/`.

Behavior:

- Waits for full boot.
- Tries `cmd wifi start-softap`.
- Falls back to `cmd connectivity tether start`.

Validation after reboot:

```sh
adb shell su -c "logcat -d | grep camperautomation-hotspot"
```

If your ROM blocks both commands, keep Automate as fallback.

---

### 4e) Diagnose hotspot support on your Xiaomi ROM (optional)

To test which hotspot control command works before relying on Magisk boot automation:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/05_diagnose_hotspot.sh
```

This probes all known hotspot commands on your device and reports which work. Use results to:

- Confirm Magisk service script will work, or
- Update the hotspot boot script with a working command, or
- Plan to use Automate as fallback.

---

## 5) First Termux run (minimal manual)

Before opening Termux, confirm USB app installation was allowed:

- Xiaomi/MIUI `Install via USB` is enabled.
- Xiaomi account sign-in/verification completed if MIUI requested it.

Open Termux once on phone and run:

```sh
termux-setup-storage
bash ~/bootstrap_termux.sh
```

Approve the Android storage permission prompt if shown. This is required for any provisioning fallback that stages files in `/sdcard/Download/`.

If that path fails, fallback:

```sh
bash /data/data/com.termux/files/home/bootstrap_termux.sh
```

If you want to run from shared storage, initialize storage first:

```sh
termux-setup-storage
bash ~/storage/downloads/bootstrap_termux.sh
```

Note: `/sdcard/Download/bootstrap_termux.sh` can be inaccessible in Termux until storage permission is granted.

The USB orchestrator now pushes this file automatically in step `4c`.

What script does:

- package update/upgrade
- install core dependencies (`openssh`, `python`, `uv`, `git`, native libs)
- asks for `passwd` to enable SSH login
- starts `sshd` and verifies it is running

Expected signal:

- `sshd` running and password set.

---

## 6) SSH phase: deploy boot scripts + install Home Assistant Core

Find Termux username on phone:

```sh
whoami
```

Then from laptop:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
PHONE_HOST=<PHONE_IP_OR_HOSTNAME> PHONE_USER=<TERMUX_USER> ./provisioning/ssh/10_install_homeassistant_core.sh
```

This script:

- copies `boot/00-bootstrap` to `~/.termux/boot/00-bootstrap`
- copies `scripts/bootstrap_services.sh` and `scripts/hass.sh`
- creates `~/.venv`
- clones `https://github.com/ondyn/hass-core.git` branch `without-uv`
- runs translations develop + `pip install .`

---

## 7) Post-install validation

From laptop:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
PHONE_HOST=<PHONE_IP_OR_HOSTNAME> PHONE_USER=<TERMUX_USER> ./provisioning/ssh/20_post_install_checks.sh
```

On phone (SSH):

```sh
screen -dmS hass sh ~/scripts/hass.sh
screen -ls
tail -n 100 ~/.homeassistant/home-assistant.log
tail -n 100 ~/logs/bootstrap.log
```

Success criteria:

- `screen -ls` contains `.hass`
- bootstrap log shows VPN -> SSH -> HA sequence
- Home Assistant Companion can connect over VPN

---

## 8) SSH hardening: key-based auth only (optional but recommended)

After Home Assistant is running, disable password-based SSH login and use key-based auth:

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
PHONE_HOST=<IP> PHONE_USER=<user> ./provisioning/ssh/30_harden_ssh_key_auth.sh
```

What this does:

- Generates SSH key pair on laptop (or uses existing key).
- Deploys public key to phone `~/.ssh/authorized_keys`.
- Disables password authentication in SSH server.
- Provides safe fallback login method if hotspot fails.

Security benefits:

- No password transmitted over network even on VPN.
- Key rotation is easier than password management.
- Reduces attack surface if VPN is ever breached.

---

## 9) Tailscale VPN setup

Tailscale provides a stable, encrypted tunnel so the Home Assistant Companion app can reach the van from any network.

### 9a) Create a Tailscale account and auth key

1. Sign up at <https://login.tailscale.com>.
2. Go to **Settings → Keys** → **Generate auth key**.
3. Recommended: enable **Reusable** and set an expiry. Copy the `TSKEY-...` value.

### 9b) Install Tailscale and connect the phone

With a pre-auth key (non-interactive, recommended for automation):

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
PHONE_HOST=<PHONE_IP> PHONE_USER=<TERMUX_USER> \
  ./provisioning/ssh/40_setup_tailscale.sh --authkey TSKEY-xxx-...
```

Or without an auth key (browser login):

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
PHONE_HOST=<PHONE_IP> PHONE_USER=<TERMUX_USER> \
  ./provisioning/ssh/40_setup_tailscale.sh
```

The script will print an auth URL — open it in a browser to complete login.

What the script does:

- Detects phone CPU architecture (`aarch64` → arm64, etc.)
- Downloads the latest Tailscale stable tarball from `pkgs.tailscale.com/stable/`
- Installs `tailscale` and `tailscaled` binaries to `~/vpn/` (expected by `bootstrap_services.sh`)
- Creates Tailscale state and socket directories
- Starts `tailscaled` with `userspace-networking` (required on Android — no TUN kernel module needed)
- Authenticates and prints the assigned Tailscale IP

### 9c) Verify connection

On phone (SSH):

```sh
~/vpn/tailscale --socket $PREFIX/var/run/tailscale/tailscaled.sock status
~/vpn/tailscale --socket $PREFIX/var/run/tailscale/tailscaled.sock ip -4
```

From laptop (after joining the same Tailscale network):

```sh
curl -s http://<TAILSCALE_IP>:8123
```

Expected signal:

- `tailscale status` lists the phone as a connected peer.
- Home Assistant Companion can reach `http://<TAILSCALE_IP>:8123` from outside the van hotspot.

### 9d) Boot autostart

`bootstrap_services.sh` already includes `start_vpn()` which starts `tailscaled` on every boot.
No additional configuration is needed — the binaries being present at `~/vpn/` is sufficient.

To verify after reboot:

```sh
ssh -p 8022 <TERMUX_USER>@<PHONE_IP> 'grep VPN ~/logs/bootstrap.log | tail -5'
```

---

## 10) File/folder structure for provisioning assets

```text
provisioning/
  adb/
    00_run_all_adb_steps.sh (orchestrator – runs steps 1-5)
    01_check_phone.sh
    02_download_apks.sh
    03_install_apks.sh
    03b_push_termux_bootstrap.sh
    04_setup_hotspot_boot_magisk.sh
    05_diagnose_hotspot.sh
  android/
    magisk-service/
      80-hotspot-on-boot.sh
  apks/
    .gitkeep
    README.md
  logs/
    .gitkeep
  ssh/
    10_install_homeassistant_core.sh
    20_post_install_checks.sh
    30_harden_ssh_key_auth.sh
    40_setup_tailscale.sh
  termux/
    bootstrap_termux.sh
```

---

## Operational notes

- Keep only one active Termux boot entrypoint: `~/.termux/boot/00-bootstrap`.
- Legacy wrappers in `boot/vpn`, `boot/ssh`, and `boot/hass` should stay unused to avoid duplicate starts.
- Do not mutate Home Assistant `.storage` files during boot.
- Use hostname-based ESPHome endpoint config where possible (for example `esphymer.local`).
