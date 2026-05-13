# Provisioning scripts

The `provisioning/` folder provides repeatable setup automation for Android + Termux.

## Structure

- `adb/`: run from laptop while phone is connected over USB.
- `ssh/`: run from laptop once Termux SSH is up.
- `termux/`: scripts executed inside Termux.
- `android/magisk-service/`: rooted Android boot scripts installed via Magisk.
- `apks/`: APK staging directory (intentionally empty in git).
- `logs/`: local execution logs.

## Typical flow

### Quick USB phase (orchestrated)

```sh
cd /Users/ondrejhnyk/Documents/CamperAutomation
./provisioning/adb/00_run_all_adb_steps.sh
```

SSH authentication policy for the orchestrator:

- `provisioning/adb/00_run_all_adb_steps.sh` is intentionally password-only for SSH phases.
- SSH key deployment and password disablement are intentionally manual in `provisioning/ssh/30_harden_ssh_key_auth.sh`.
- Do not reintroduce SSH key login toggles into the USB orchestrator.

Important Xiaomi/MIUI note:

- Enable `Install via USB` in Developer options before APK install.
- MIUI may require Xiaomi account login/verification during this toggle.
- If APK installs fail with `INSTALL_FAILED_USER_RESTRICTED`, this setting is usually the cause.

Or run individual steps:

1. USB phase (manual steps):
   - `provisioning/adb/01_check_phone.sh` – baseline device check
   - `provisioning/adb/02_download_apks.sh` – ABI-aware APK download
   - `provisioning/adb/03_install_apks.sh` – install apps via ADB
   - `provisioning/adb/06_remove_bloatware_mi11.sh` – strict Xiaomi Mi 11 debloat for HA-dedicated device
   - `provisioning/adb/03b_push_termux_bootstrap.sh` – push Termux bootstrap script to `/sdcard/Download`
   - `provisioning/adb/04_setup_hotspot_boot_magisk.sh` – hotspot autostart (Magisk)
   - `provisioning/adb/05_diagnose_hotspot.sh` – test which hotspot command works

2. Manual Termux bootstrap on phone (see `docs/setup/installation.md`).
   - Bootstrap script is automatically pushed by `provisioning/adb/03b_push_termux_bootstrap.sh`.
   - Preferred command in Termux: `bash ~/bootstrap_termux.sh`.
   - Bootstrap now enables `root` and `x11` repos and writes deterministic APT sources for main/root/x11 before the first `pkg update`.
   - Override mirror URLs if needed before running bootstrap, for example: `TERMUX_MAIN_REPO=<mirror-main> TERMUX_ROOT_REPO=<mirror-root> TERMUX_X11_REPO=<mirror-x11> bash ~/bootstrap_termux.sh`.

3. SSH phase (from laptop):
   - `provisioning/ssh/10_install_homeassistant_core.sh` – deploy HA core + boot scripts
   - `provisioning/ssh/15_install_hacs.sh` – install/update HACS in active HA config dir
   - `provisioning/ssh/16_install_ha_startup_requirements.sh` – install missing Python modules seen in HA startup logs
   - `provisioning/ssh/18_install_termux_tilt.sh` – deploy local `termux_tilt` custom integration to active HA config dir
   - `provisioning/ssh/20_post_install_checks.sh` – validate installation
   - `provisioning/ssh/30_harden_ssh_key_auth.sh` – manual step: SSH key auth + disable password

## Notes

- Phone-side configuration backup (HA config/database, Tailscale config, Termux startup config): `~/scripts/termux-backup.sh [target-dir]`
- Phone-side restore: `~/scripts/termux-restore.sh <backup-dir>`
- Full Termux snapshot backup over ADB (root/Magisk required): `provisioning/adb/09_backup_termux_full_adb.sh`
- Local backup download (single archive to `./backup` by default):
   - `PHONE_USER=<TERMUX_USER> provisioning/ssh/35_backup_termux_to_local.sh`
- Local restore upload + apply:
   - `PHONE_USER=<TERMUX_USER> provisioning/ssh/36_restore_termux_from_local.sh ./backup/<timestamp>.tar.gz`

- Root Xiaomi Mi11: <https://droidwin.com/how-to-root-xiaomi-eu-rom-via-magisk/>
- SSH via Tailscale: ssh -p 8022 u0_a284@<tailscale-ip>