#!/usr/bin/env bash
set -euo pipefail

# USB phase orchestrator: runs all ADB provisioning steps in sequence with unified logging.
# Maintainer note: keep this orchestrator password-only for SSH auth.
# SSH key provisioning and password disablement must stay in provisioning/ssh/30_harden_ssh_key_auth.sh.
# Usage:
#   ./provisioning/adb/00_run_all_adb_steps.sh [OPTIONS]
# 
# Options:
#   --skip-debloat    Skip Xiaomi Mi11 debloat step
#   --skip-hotspot    Skip hotspot boot script setup
#   --skip-bootstrap  Skip running bootstrap_termux.sh via ADB
#   --skip-ha         Skip Home Assistant Core installation
#   --skip-hacs       Skip HACS installation
#   --skip-termux-tilt Skip termux_tilt custom integration deployment
#   --skip-tailscale  Skip Tailscale installation
#   --skip-post-checks Skip post-install validation
#   --tailscale-authkey <key>  Use non-interactive Tailscale auth
#   --help             Show this message

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${ROOT_DIR}/provisioning/logs"
ORCHESTRATOR_LOG="${LOG_DIR}/usb-provision-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"

# Load .env from repo root for secrets (SSH_PWD, etc.)
if [ -f "${ROOT_DIR}/.env" ]; then
  # shellcheck disable=SC1091
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

SKIP_HOTSPOT=0
SKIP_DEBLOAT=0
SKIP_BOOTSTRAP=0
SKIP_HA=0
SKIP_HACS=0
SKIP_TERMUX_TILT=0
SKIP_TAILSCALE=0
SKIP_POST_CHECKS=0
TAILSCALE_AUTHKEY=""
SSH_PORT="${SSH_PORT:-8022}"
TERMUX_BASE_PATH=""
PROVISION_SSH_PASSWORD="${PROVISION_SSH_PASSWORD:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-hotspot) SKIP_HOTSPOT=1 ;;
    --skip-debloat) SKIP_DEBLOAT=1 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1 ;;
    --skip-ha) SKIP_HA=1 ;;
    --skip-hacs) SKIP_HACS=1 ;;
    --skip-termux-tilt) SKIP_TERMUX_TILT=1 ;;
    --skip-tailscale) SKIP_TAILSCALE=1 ;;
    --skip-post-checks) SKIP_POST_CHECKS=1 ;;
    --tailscale-authkey)
      shift
      TAILSCALE_AUTHKEY="${1:-}"
      if [ -z "${TAILSCALE_AUTHKEY}" ]; then
        echo "Missing value for --tailscale-authkey" >&2
        exit 1
      fi
      ;;
    --help)
      echo "Usage: $0 [--skip-debloat] [--skip-hotspot] [--skip-bootstrap] [--skip-ha] [--skip-hacs] [--skip-termux-tilt] [--skip-tailscale] [--skip-post-checks] [--tailscale-authkey <key>] [--help]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

auto_detect_phone_user_adb() {
  local pkg_uid app_uid
  pkg_uid=$(adb shell dumpsys package com.termux 2>/dev/null | tr -d '\r' | awk -F= '/userId=/{print $2; exit}') || true
  if [[ -n "${pkg_uid:-}" && "${pkg_uid}" =~ ^[0-9]+$ && "${pkg_uid}" -ge 10000 ]]; then
    app_uid=$((pkg_uid - 10000))
    echo "u0_a${app_uid}"
    return 0
  fi
  return 1
}

launch_termux_app() {
  adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >> "${ORCHESTRATOR_LOG}" 2>&1 || true
}

resolve_termux_base_path() {
  TERMUX_BASE_PATH="$(adb shell run-as com.termux pwd 2>/dev/null | tr -d '\r' | head -n1 || true)"
  if [ -z "${TERMUX_BASE_PATH}" ]; then
    TERMUX_BASE_PATH="/data/data/com.termux"
  fi
}

ensure_termux_runtime_ready() {
  local termux_bash
  resolve_termux_base_path
  termux_bash="${TERMUX_BASE_PATH}/files/usr/bin/bash"

  if adb shell "run-as com.termux test -x '${termux_bash}'" >/dev/null 2>&1; then
    return 0
  fi

  log "Termux runtime not initialized yet; launching Termux and waiting for first-run setup..."
  launch_termux_app

  for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if adb shell "run-as com.termux test -x '${termux_bash}'" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  warn "Termux runtime still not ready (missing ${termux_bash})."
  warn "Open Termux once on the phone, wait for initial package extraction, then rerun."
  return 1
}

run_bootstrap_via_adb() {
  local termux_bash termux_bootstrap
  adb wait-for-device
  if ! ensure_termux_runtime_ready; then
    return 1
  fi

  termux_bash="${TERMUX_BASE_PATH}/files/usr/bin/bash"
  termux_bootstrap="${TERMUX_BASE_PATH}/files/home/bootstrap_termux.sh"

  if [ -z "${PROVISION_SSH_PASSWORD}" ]; then
    PROVISION_SSH_PASSWORD="${SSH_PWD:-}"
  fi
  if [ -z "${PROVISION_SSH_PASSWORD}" ]; then
    echo "ERROR: SSH_PWD is not set in .env and PROVISION_SSH_PASSWORD is not provided." >&2
    exit 1
  fi

  # Clear any stale host key before bootstrap generates a fresh SSH server key.
  # accept-new only accepts truly-new keys; a changed key (fresh reinstall) will
  # be rejected unless the old fingerprint is removed first.
  ssh-keygen -R "[127.0.0.1]:${SSH_PORT}" >> "${ORCHESTRATOR_LOG}" 2>&1 || true

  adb shell "run-as com.termux env TERMUX_SSH_PASSWORD='${PROVISION_SSH_PASSWORD}' '${termux_bash}' '${termux_bootstrap}'" >> "${ORCHESTRATOR_LOG}" 2>&1
}

# Read the SSH password that bootstrap wrote to the phone credentials file.
# Used when --skip-bootstrap is set but no PROVISION_SSH_PASSWORD was supplied.
read_phone_ssh_password() {
  local cred_file="/data/data/com.termux/files/home/logs/bootstrap-credentials.txt"
  adb shell "run-as com.termux cat '${cred_file}'" 2>/dev/null \
    | tr -d '\r' | awk -F= '/^ssh_password/{print $2}' | head -1
}

prepare_local_ssh_tunnel() {
  adb forward --remove "tcp:${SSH_PORT}" >/dev/null 2>&1 || true
  adb forward "tcp:${SSH_PORT}" "tcp:${SSH_PORT}" >> "${ORCHESTRATOR_LOG}" 2>&1
}

stop_stale_device_sshd() {
  local pids

  if ! adb shell su -c 'true' >/dev/null 2>&1; then
    warn "Magisk su is not available from ADB; skipping stale sshd cleanup."
    return 0
  fi

  pids="$(adb shell su -c "ss -lntp 2>/dev/null | sed -n 's/.*users:((\"sshd\",pid=\\([0-9][0-9]*\\),.*/\\1/p' | sort -u" 2>/dev/null | tr -d '\r' | xargs || true)"
  if [ -n "${pids}" ]; then
    log "Stopping stale sshd pid(s): ${pids}"
    adb shell su -c "kill ${pids} 2>/dev/null || true" >> "${ORCHESTRATOR_LOG}" 2>&1 || true
  else
    log "No stale sshd listeners found."
  fi
}

wait_for_local_ssh() {
  local tries=0
  while [ "${tries}" -lt 20 ]; do
    if nc -z 127.0.0.1 "${SSH_PORT}" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done
  return 1
}

run_ssh_phase() {
  local label="$1"
  shift
  local -a phase_env
  phase_env=(PHONE_HOST=127.0.0.1 PHONE_USER="${PHONE_USER}" SSH_PORT="${SSH_PORT}")
  if [ -n "${PROVISION_SSH_PASSWORD}" ]; then
    phase_env+=(SSH_PASSWORD="${PROVISION_SSH_PASSWORD}")
  fi
  log_header "${label}"
  if env "${phase_env[@]}" "$@" >> "${ORCHESTRATOR_LOG}" 2>&1; then
    log "✓ ${label} succeeded"
  else
    fail "${label} failed (see log for details)"
  fi
}

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
  echo "Skip bootstrap: ${SKIP_BOOTSTRAP}"
  echo "Skip Home Assistant: ${SKIP_HA}"
  echo "Skip HACS: ${SKIP_HACS}"
  echo "Skip termux_tilt install: ${SKIP_TERMUX_TILT}"
  echo "Skip Tailscale: ${SKIP_TAILSCALE}"
  echo "Skip post checks: ${SKIP_POST_CHECKS}"
  echo "SSH auth mode for orchestrator: password-only"
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

PHONE_USER="$(auto_detect_phone_user_adb || true)"
if [ -z "${PHONE_USER}" ]; then
  fail "Could not auto-detect PHONE_USER from ADB package metadata"
fi
log "Detected PHONE_USER=${PHONE_USER}"
log "Note: 00_run_all_adb_steps.sh intentionally uses password-based SSH only."
log "      Manual SSH key hardening is separate: provisioning/ssh/30_harden_ssh_key_auth.sh"

if [ "${SKIP_BOOTSTRAP}" -eq 0 ]; then
  log_header "Step 7: Stop stale device sshd listeners"
  stop_stale_device_sshd
  log "✓ Cleared stale sshd listeners before bootstrap"

  log_header "Step 8: Run bootstrap_termux.sh via ADB"
  if run_bootstrap_via_adb; then
    log "✓ Termux bootstrap completed via ADB"
    log "Provisioning SSH password for ${PHONE_USER}: ${PROVISION_SSH_PASSWORD}"
    log "Phone copy: /data/data/com.termux/files/home/logs/bootstrap-credentials.txt"
  else
    fail "bootstrap_termux.sh failed via ADB"
  fi

  log_header "Step 9: Establish localhost SSH tunnel through ADB"
  prepare_local_ssh_tunnel
  if wait_for_local_ssh; then
    log "✓ SSH is reachable on localhost:${SSH_PORT} through adb forward"
  else
    fail "SSH did not become reachable on localhost:${SSH_PORT}"
  fi
else
  log_header "Step 7-9: Bootstrap and SSH tunnel (SKIPPED)"
  # Recover SSH password from phone credentials if not supplied by caller.
  if [ -z "${PROVISION_SSH_PASSWORD}" ]; then
    PROVISION_SSH_PASSWORD="$(read_phone_ssh_password || true)"
    if [ -n "${PROVISION_SSH_PASSWORD}" ]; then
      log "Recovered SSH password from phone credentials file"
    else
      fail "PROVISION_SSH_PASSWORD is empty and could not be read from phone.\n       Set it explicitly: PROVISION_SSH_PASSWORD=<pass> $0 --skip-bootstrap ..."
    fi
  fi
  if [ "${SKIP_HA}" -eq 0 ] || [ "${SKIP_TAILSCALE}" -eq 0 ] || [ "${SKIP_HACS}" -eq 0 ] || [ "${SKIP_TERMUX_TILT}" -eq 0 ] || [ "${SKIP_POST_CHECKS}" -eq 0 ]; then
    prepare_local_ssh_tunnel
    if wait_for_local_ssh; then
      log "✓ Reused existing SSH service on localhost:${SSH_PORT} through adb forward"
    else
      fail "SSH is required for the remaining steps but was not reachable on localhost:${SSH_PORT}"
    fi
  fi
fi

if [ "${SKIP_HA}" -eq 0 ]; then
  run_ssh_phase "Step 10: Install Home Assistant Core" bash "${ROOT_DIR}/provisioning/ssh/10_install_homeassistant_core.sh"
  run_ssh_phase "Step 11: Install HA startup requirements" bash "${ROOT_DIR}/provisioning/ssh/16_install_ha_startup_requirements.sh"
else
  log_header "Step 10-11: Home Assistant installation (SKIPPED)"
fi

if [ "${SKIP_TAILSCALE}" -eq 0 ]; then
  if [ -n "${TAILSCALE_AUTHKEY}" ]; then
    log_header "Step 12: Install and authenticate Tailscale"
    if env PHONE_HOST=127.0.0.1 PHONE_USER="${PHONE_USER}" SSH_PORT="${SSH_PORT}" SSH_PASSWORD="${PROVISION_SSH_PASSWORD}" bash "${ROOT_DIR}/provisioning/ssh/40_setup_tailscale.sh" --authkey "${TAILSCALE_AUTHKEY}" >> "${ORCHESTRATOR_LOG}" 2>&1; then
      log "✓ Step 12: Install and authenticate Tailscale succeeded"
    else
      warn "Step 12 failed; continuing without Tailscale."
      log "  See log for details: ${ORCHESTRATOR_LOG}"
      log "  Tailscale can be retried later with: PHONE_HOST=127.0.0.1 PHONE_USER=${PHONE_USER} SSH_PORT=${SSH_PORT} provisioning/ssh/40_setup_tailscale.sh"
    fi
  else
    log_header "Step 12: Install Tailscale"
    if env PHONE_HOST=127.0.0.1 PHONE_USER="${PHONE_USER}" SSH_PORT="${SSH_PORT}" SSH_PASSWORD="${PROVISION_SSH_PASSWORD}" bash "${ROOT_DIR}/provisioning/ssh/40_setup_tailscale.sh" >> "${ORCHESTRATOR_LOG}" 2>&1; then
      log "✓ Step 12: Install Tailscale succeeded"
    else
      warn "Step 12 failed; continuing without Tailscale."
      log "  See log for details: ${ORCHESTRATOR_LOG}"
      log "  Tailscale can be retried later with: PHONE_HOST=127.0.0.1 PHONE_USER=${PHONE_USER} SSH_PORT=${SSH_PORT} provisioning/ssh/40_setup_tailscale.sh"
    fi
  fi
else
  log_header "Step 12: Tailscale installation (SKIPPED)"
fi

if [ "${SKIP_HACS}" -eq 0 ]; then
  run_ssh_phase "Step 13: Install HACS" bash "${ROOT_DIR}/provisioning/ssh/15_install_hacs.sh"
else
  log_header "Step 13: HACS installation (SKIPPED)"
fi

if [ "${SKIP_TERMUX_TILT}" -eq 0 ]; then
  run_ssh_phase "Step 14: Install termux_tilt custom integration" bash "${ROOT_DIR}/provisioning/ssh/18_install_termux_tilt.sh"
else
  log_header "Step 14: termux_tilt custom integration (SKIPPED)"
fi

if [ "${SKIP_POST_CHECKS}" -eq 0 ]; then
  run_ssh_phase "Step 15: Run post-install checks" bash "${ROOT_DIR}/provisioning/ssh/20_post_install_checks.sh"
else
  log_header "Step 15: Post-install checks (SKIPPED)"
fi

if [ "${SKIP_HA}" -eq 0 ]; then
  run_ssh_phase "Step 16: Restart Home Assistant" bash "${ROOT_DIR}/provisioning/ssh/25_restart_homeassistant.sh"
else
  log_header "Step 16: Restart Home Assistant (SKIPPED - HA install skipped)"
fi

{
  echo
  echo "=== USB Provisioning Complete ==="
  echo "Completed: $(date)"
  echo
  echo "Next steps:"
  echo "0. If APK install was blocked on Xiaomi: enable Developer options -> Install via USB,"
  echo "   and sign in/confirm Xiaomi account when MIUI asks."
  echo "1. If Android showed a storage permission dialog for Termux, approve it on the phone."
  echo "2. Also open Termux:Boot from the phone app drawer once if the ADB launch above failed."
  echo "3. Use Magisk to grant su permissions if prompted during Tailscale or Home Assistant setup."
  echo "4. Log file: ${ORCHESTRATOR_LOG}"
  echo "5. SSH endpoint during USB provisioning: ssh -p ${SSH_PORT} ${PHONE_USER}@127.0.0.1"
  echo "   Password: ${PROVISION_SSH_PASSWORD}"
  echo "6. Optional manual hardening after provisioning: provisioning/ssh/30_harden_ssh_key_auth.sh"
} | tee -a "${ORCHESTRATOR_LOG}"
