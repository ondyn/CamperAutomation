#!/usr/bin/env bash
set -euo pipefail

# USB phase orchestrator: runs all ADB provisioning steps in sequence with unified logging.
# Usage:
#   ./provisioning/adb/00_run_all_adb_steps.sh [OPTIONS]
# 
# Options:
#   --skip-hotspot     Skip hotspot boot script setup (step 4)
#   --help             Show this message

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${ROOT_DIR}/provisioning/logs"
ORCHESTRATOR_LOG="${LOG_DIR}/usb-provision-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"

SKIP_HOTSPOT=0
for arg in "$@"; do
  case "$arg" in
    --skip-hotspot) SKIP_HOTSPOT=1 ;;
    --help) echo "Usage: $0 [--skip-hotspot] [--help]"; exit 0 ;;
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

# Step 4: Push Termux bootstrap script to phone shared storage.
log_header "Step 4: Push Termux bootstrap script"
if bash "${ROOT_DIR}/provisioning/adb/03b_push_termux_bootstrap.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
  log "✓ Termux bootstrap script delivered (preferred: ~/bootstrap_termux.sh)"
else
  warn "Failed to push bootstrap script automatically"
  log "  Manual fallback: adb push provisioning/termux/bootstrap_termux.sh /sdcard/Download/bootstrap_termux.sh"
fi

# Step 5: Setup hotspot boot (optional)
if [ "${SKIP_HOTSPOT}" -eq 0 ]; then
  log_header "Step 5: Setup hotspot autostart"
  if bash "${ROOT_DIR}/provisioning/adb/04_setup_hotspot_boot_magisk.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
    log "✓ Hotspot boot setup succeeded"
  else
    warn "Hotspot boot setup was skipped (requires Magisk root which may not be installed yet)"
    log "  Run this later after Magisk is installed: bash ${ROOT_DIR}/provisioning/adb/04_setup_hotspot_boot_magisk.sh"
  fi
else
  log_header "Step 5: Setup hotspot autostart (SKIPPED)"
fi

{
  echo
  echo "=== USB Provisioning Complete ==="
  echo "Completed: $(date)"
  echo
  echo "Next steps:"
  echo "0. If APK install was blocked on Xiaomi: enable Developer options -> Install via USB,"
  echo "   and sign in/confirm Xiaomi account when MIUI asks."
  echo "1. Use Magisk to grant su permissions if prompted"
  echo "2. Open Termux on the phone and run: bash ~/bootstrap_termux.sh"
  echo "3. From laptop: PHONE_HOST=<IP> PHONE_USER=<user> provisioning/ssh/10_install_homeassistant_core.sh"
  echo "4. Validate with: provisioning/ssh/20_post_install_checks.sh"
} | tee -a "${ORCHESTRATOR_LOG}"
