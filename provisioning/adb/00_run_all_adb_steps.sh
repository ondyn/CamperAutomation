#!/usr/bin/env bash
set -euo pipefail

# USB phase orchestrator: runs all ADB provisioning steps in sequence with unified logging.
# Usage:
#   ./provisioning/adb/00_run_all_adb_steps.sh [OPTIONS]
# 
# Options:
#   --skip-debloat    Skip Xiaomi Mi11 debloat step
#   --skip-hotspot     Skip hotspot boot script setup (step 4)
#   --help             Show this message

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${ROOT_DIR}/provisioning/logs"
ORCHESTRATOR_LOG="${LOG_DIR}/usb-provision-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"

SKIP_HOTSPOT=0
SKIP_DEBLOAT=0
for arg in "$@"; do
  case "$arg" in
    --skip-hotspot) SKIP_HOTSPOT=1 ;;
    --skip-debloat) SKIP_DEBLOAT=1 ;;
    --help) echo "Usage: $0 [--skip-debloat] [--skip-hotspot] [--help]"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

log_header() {
  printf '\n=== %s ===\n' "$1" | tee -a "${ORCHESTRATOR_LOG}"
}

log() {
  printf '%s\n' "$1" | tee -a "${ORCHESTRATOR_LOG}"
}

warn() {
  printf 'WARNING: %s\n' "$1" | tee -a "${ORCHESTRATOR_LOG}"
}

fail() {
  echo "FATAL ERROR: $1" | tee -a "${ORCHESTRATOR_LOG}" >&2
  exit 1
}

{
  echo "USB Provisioning Orchestrator"
  echo "Started: $(date)"
  echo "Log: ${ORCHESTRATOR_LOG}"
  echo "Root dir: ${ROOT_DIR}"
  echo "Skip debloat: ${SKIP_DEBLOAT}"
  echo "Skip hotspot: ${SKIP_HOTSPOT}"
} | tee "${ORCHESTRATOR_LOG}"

# Step 1: Check phone
log_header "Step 1: Check phone"
if bash "${ROOT_DIR}/provisioning/adb/01_check_phone.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
  log "✓ Phone check succeeded"
else
  fail "Phone check failed (see log for details)"
fi

# Step 2: Download APKs
log_header "Step 2: Download APKs"
if bash "${ROOT_DIR}/provisioning/adb/02_download_apks.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
  log "✓ APK download succeeded"
else
  fail "APK download failed - check network and GitHub API access"
fi

# Step 3: Install APKs
log_header "Step 3: Install APKs"
if bash "${ROOT_DIR}/provisioning/adb/03_install_apks.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
  log "✓ APK installation succeeded"
else
  log "⚠ APK installation encountered errors (see above)"
  log "  This is usually because the phone user needs to approve the installation."
  log "  Please check the phone screen and approve any installation prompts, then retry:"
  log "  bash ${ROOT_DIR}/provisioning/adb/03_install_apks.sh"
fi

# Step 3b: Launch Termux:Boot once so Android registers it for future boot events.
# Without this step Termux:Boot silently does nothing on the first reboot.
log_header "Step 3b: Launch Termux:Boot activity (required once after install)"
if adb shell am start -n com.termux.boot/.BootActivity >> "${ORCHESTRATOR_LOG}" 2>&1; then
  sleep 2
  log "✓ Termux:Boot activity launched"
else
  warn "Could not launch Termux:Boot activity via ADB (app may not be installed yet)"
  log "  Manual fix: open Termux:Boot from the phone app drawer at least once before first reboot"
fi

# Exempt Termux and Termux:Boot from battery optimization / Doze.
if adb shell cmd deviceidle whitelist +com.termux >> "${ORCHESTRATOR_LOG}" 2>&1 && \
   adb shell cmd deviceidle whitelist +com.termux.boot >> "${ORCHESTRATOR_LOG}" 2>&1; then
  log "✓ Termux and Termux:Boot added to Doze whitelist"
else
  warn "cmd deviceidle whitelist failed — add Termux and Termux:Boot to battery exemption manually:"
  log "  Settings > Apps > Manage apps > Termux > Battery saver > No restrictions"
  log "  Settings > Apps > Manage apps > Termux:Boot > Battery saver > No restrictions"
fi

# Step 4: Debloat (optional, recommended for HA-dedicated device)
if [ "${SKIP_DEBLOAT}" -eq 0 ]; then
  log_header "Step 4: Remove Xiaomi/MIUI bloatware"
  if bash "${ROOT_DIR}/provisioning/adb/06_remove_bloatware_mi11.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
    log "✓ Debloat step completed"
  else
    warn "Debloat step reported failures (some protected packages may resist removal)"
    log "  Review details in: ${ORCHESTRATOR_LOG}"
  fi
else
  log_header "Step 4: Remove Xiaomi/MIUI bloatware (SKIPPED)"
fi

# Step 5: Push Termux bootstrap script to phone shared storage.
log_header "Step 5: Push Termux bootstrap script"
if bash "${ROOT_DIR}/provisioning/adb/03b_push_termux_bootstrap.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
  log "✓ Termux bootstrap script delivered (preferred: ~/bootstrap_termux.sh)"
else
  warn "Failed to push bootstrap script automatically"
  log "  Manual fallback: adb push provisioning/termux/bootstrap_termux.sh /sdcard/Download/bootstrap_termux.sh"
fi

# Step 6: Setup hotspot boot (optional)
if [ "${SKIP_HOTSPOT}" -eq 0 ]; then
  log_header "Step 6: Setup hotspot autostart"
  if bash "${ROOT_DIR}/provisioning/adb/04_setup_hotspot_boot_magisk.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
    log "✓ Hotspot boot setup succeeded"
  else
    warn "Hotspot boot setup did not complete automatically"
    log "  Review the script output in: ${ORCHESTRATOR_LOG}"
    log "  On some Xiaomi builds, adb-shell root cannot write /data/adb/service.d even when Magisk is present."
    log "  In that case, run the printed Termux fallback command on the phone, then reboot."
  fi
else
  log_header "Step 6: Setup hotspot autostart (SKIPPED)"
fi

{
  echo
  echo "=== USB Provisioning Complete ==="
  echo "Completed: $(date)"
  echo
  echo "Next steps:"
  echo "0. If APK install was blocked on Xiaomi: enable Developer options -> Install via USB,"
  echo "   and sign in/confirm Xiaomi account when MIUI asks."
  echo "1. Open Termux on the phone and run: termux-setup-storage"
  echo "   Approve the Android storage permission prompt. Shared-storage fallbacks depend on this."
echo "2. Also open Termux:Boot from the phone app drawer (at least once — if ADB launch above failed)."
echo "   This is REQUIRED for auto-start on subsequent reboots."
echo "3. Use Magisk to grant su permissions if prompted"
echo "4. In Termux, run: bash ~/bootstrap_termux.sh"
echo "5. If a fallback script was staged in /sdcard/Download, access it from Termux via ~/storage/downloads/"
echo "6. From laptop: PHONE_HOST=<IP> PHONE_USER=<user> provisioning/ssh/10_install_homeassistant_core.sh"
echo "7. Install HACS: PHONE_HOST=<IP> PHONE_USER=<user> provisioning/ssh/15_install_hacs.sh"
echo "8. Validate with: provisioning/ssh/20_post_install_checks.sh"
} | tee -a "${ORCHESTRATOR_LOG}"
