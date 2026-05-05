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

2. Manual Termux bootstrap on phone (see `instalation.md`).
   - Bootstrap script is automatically pushed by `provisioning/adb/03b_push_termux_bootstrap.sh`.
   - Preferred command in Termux: `bash ~/bootstrap_termux.sh`.

3. SSH phase (from laptop):
   - `provisioning/ssh/10_install_homeassistant_core.sh` – deploy HA core + boot scripts
   - `provisioning/ssh/15_install_hacs.sh` – install/update HACS in active HA config dir
   - `provisioning/ssh/16_install_ha_startup_requirements.sh` – install missing Python modules seen in HA startup logs
   - `provisioning/ssh/20_post_install_checks.sh` – validate installation
   - `provisioning/ssh/30_harden_ssh_key_auth.sh` – SSH key auth + disable password

## Notes

- Root Xiaomi Mi11: <https://droidwin.com/how-to-root-xiaomi-eu-rom-via-magisk/>
