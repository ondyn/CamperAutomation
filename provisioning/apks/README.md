# APK staging folder

This folder is intentionally tracked so installer scripts can cache APK files.

Expected files (created by scripts in `provisioning/adb/`):

- `magisk.apk`
- `termux.apk`
- `termux-boot.apk`
- `home-assistant-companion.apk`

Optional:

- `automate.apk`

Do not commit proprietary APK binaries. Keep only this README and `.gitkeep` in git.
