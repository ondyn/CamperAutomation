#!/usr/bin/env bash
# fix-espidf.sh — applied at container startup via docker-compose entrypoint override.
#
# Problem 1: duplicate source file basenames inside the efuse component, e.g.
#   efuse/<variant>/esp_efuse_fields.c  AND  efuse/src/esp_efuse_fields.c
#   efuse/<variant>/esp_efuse_utility.c AND  efuse/src/esp_efuse_utility.c
# PlatformIO flattens object names, so CMake reports "Multiple ways to build the
# same target". Fix: rename the chip-specific copies, then update sources.cmake.
# Applies to every esp32* variant dir, since the collision is not chip specific.
#
# Problem 2 (ESP-IDF 5.5.x only): system_time.c in two components:
#   components/esp_system/system_time.c
#   components/esp_timer/src/system_time.c
# Fix: rename the esp_timer copy and update its CMakeLists.txt.
#
# ESP-IDF 6.0.x reorganised esp_timer so problem 2 is a no-op there.
# Both fixes are idempotent — safe to run on every container start.

set -euo pipefail

EFUSE_FIX_FILES=(
  "esp_efuse_fields.c"
  "esp_efuse_utility.c"
)

fix_efuse_dir() {
  local base="$1"
  local changed=0

  for dir in "${base}"/components/efuse/esp32*; do
    [[ -d "$dir" ]] || continue
    local cmake="${dir}/sources.cmake"
    [[ -f "$cmake" ]] || continue

    local variant
    variant="$(basename "$dir")"

    for old in "${EFUSE_FIX_FILES[@]}"; do
      # esp_efuse_fields.c -> esp32s3_efuse_fields.c
      local new="${variant}_${old#esp_}"
      if [[ -f "${dir}/${old}" ]]; then
        mv "${dir}/${old}" "${dir}/${new}"
        sed -i "s/\"${old}\"/\"${new}\"/g" "$cmake"
        echo "[fix-espidf] Renamed ${dir}/${old} -> ${new}"
        changed=1
      fi
    done
  done

  if [[ $changed -eq 1 ]]; then
    # Clear stale pioenvs build dirs so ninja regenerates from renamed files.
    # The dirs are inside esphome_data (/config/.esphome/build) which is a
    # separate volume from the framework packages, so they may be out of sync
    # after a framework volume wipe.
    rm -rf /config/.esphome/build/*/Makefile \
           /config/.esphome/build/*/.pioenvs \
           2>/dev/null || true
    echo "[fix-espidf] Build caches cleared (pioenvs removed)."
  fi
}

fix_system_time_dir() {
  local base="$1"
  local src="${base}/components/esp_timer/src/system_time.c"
  local dst="${base}/components/esp_timer/src/esp_timer_system_time.c"
  local cmake="${base}/components/esp_timer/CMakeLists.txt"

  if [[ ! -f "$src" ]]; then
    return 0
  fi

  mv "$src" "$dst"
  echo "[fix-espidf] Renamed ${src} -> esp_timer_system_time.c"

  # Replace the bare filename reference in CMakeLists.txt
  sed -i "s|src/system_time\.c|src/esp_timer_system_time.c|g" "$cmake"
  echo "[fix-espidf] Updated ${cmake}"

  rm -rf /config/.esphome/build/*/Makefile \
         /config/.esphome/build/*/.pioenvs \
         2>/dev/null || true
  echo "[fix-espidf] Build caches cleared (pioenvs removed)."
}

# Fix both possible package locations (esphome_platformio volume and esphome_data volume)
fix_efuse_dir "/root/.platformio/packages/framework-espidf"
fix_efuse_dir "/config/.esphome/platformio/packages/framework-espidf"

fix_system_time_dir "/root/.platformio/packages/framework-espidf"
fix_system_time_dir "/config/.esphome/platformio/packages/framework-espidf"

echo "[fix-espidf] Done."

# Hand off to the real ESPHome entrypoint
exec /entrypoint.sh "$@"
