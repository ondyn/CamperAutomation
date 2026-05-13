#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

LOG_DIR="/data/data/com.termux/files/home/logs"
LOG_FILE="${LOG_DIR}/bootstrap.log"
HASS_SCRIPT="/data/data/com.termux/files/home/scripts/hass.sh"
HASS_CTL="/data/data/com.termux/files/home/scripts/hassctl.sh"
TAILSCALED_BIN="/data/data/com.termux/files/home/vpn/tailscaled"
TAILSCALE_BIN="/data/data/com.termux/files/home/vpn/tailscale"
TAILSCALE_SOCKET="$PREFIX/var/run/tailscale/tailscaled.sock"
TAILSCALE_STATE="$PREFIX/var/lib/tailscale/tailscaled.state"

mkdir -p "${LOG_DIR}"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "${LOG_FILE}"
}

wait_for_tailscale_socket() {
  i=0
  while [ "$i" -lt 20 ]; do
    if [ -S "${TAILSCALE_SOCKET}" ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

start_vpn() {
  if [ ! -x "${TAILSCALED_BIN}" ] || [ ! -x "${TAILSCALE_BIN}" ]; then
    log "VPN: tailscale binaries not found at ${TAILSCALED_BIN} and ${TAILSCALE_BIN}; skipping"
    return
  fi

  # tailscaled needs CAP_NET_ADMIN to read the kernel routing table (netlinkrib).
  # On Android/Termux this permission is denied unless we run as root via Magisk su.
  VPN_HAS_ROOT=0
  if command_exists su && su -c 'true' >/dev/null 2>&1; then
    VPN_HAS_ROOT=1
    log "VPN: root (su) available"
  fi

  if pgrep -x tailscaled >/dev/null 2>&1; then
    log "VPN: tailscaled is already running"
  else
    log "VPN: starting tailscaled (root=${VPN_HAS_ROOT})"
    mkdir -p "${LOG_DIR}"
    if [ "${VPN_HAS_ROOT}" = "1" ]; then
      su -c "nohup ${TAILSCALED_BIN} -tun userspace-networking --state=${TAILSCALE_STATE} -socket ${TAILSCALE_SOCKET} >> ${LOG_FILE} 2>&1 &"
    else
      nohup "${TAILSCALED_BIN}" -tun userspace-networking --state="${TAILSCALE_STATE}" -socket "${TAILSCALE_SOCKET}" >>"${LOG_FILE}" 2>&1 &
    fi
  fi

  if wait_for_tailscale_socket; then
    log "VPN: tailscaled socket is ready"
    # Make socket world-rw so Termux user can run tailscale CLI without root.
    if [ "${VPN_HAS_ROOT}" = "1" ]; then
      su -c "chmod 666 ${TAILSCALE_SOCKET}" >/dev/null 2>&1 || true
    fi
    if "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status >/dev/null 2>&1; then
      log "VPN: tailscale status command succeeded"
    else
      log "VPN: tailscale daemon is up but not authenticated yet (run tailscale up manually when needed)"
    fi
  else
    log "VPN: tailscaled socket did not become ready in time"
  fi
}

start_ssh() {
  if ! command_exists sshd; then
    log "SSH: sshd binary not found in PATH; skipping"
    return
  fi

  if pgrep -x sshd >/dev/null 2>&1; then
    log "SSH: sshd is already running"
  else
    log "SSH: starting sshd"
    if sshd >>"${LOG_FILE}" 2>&1; then
      log "SSH: sshd started"
    else
      log "SSH: sshd failed to start"
    fi
  fi
}

ensure_hotspot() {
  # Backup hotspot trigger: runs after Magisk service.d fires.
  # Needed because service.d sometimes doesn't log or execute reliably on MIUI.
  # Calls the same service.d script directly under root so logic is centralised.
  if ! command_exists su || ! su -c 'true' >/dev/null 2>&1; then
    log "Hotspot: root not available, skipping"
    return
  fi

  # wlan1 = AP interface when hotspot is active
  if su -c 'ip link show wlan1' >/dev/null 2>&1; then
    log "Hotspot: already active (wlan1 up)"
    return
  fi

  SERVICE_SCRIPT="/data/adb/service.d/80-hotspot-on-boot.sh"
  if su -c "test -x \"${SERVICE_SCRIPT}\"" >/dev/null 2>&1; then
    log "Hotspot: wlan1 not found, running boot script..."
    su -c "${SERVICE_SCRIPT}" >>"${LOG_FILE}" 2>&1 &
    log "Hotspot: start triggered (background)"
  else
    log "Hotspot: boot script not found at ${SERVICE_SCRIPT}"
  fi
}

start_hass() {
  if [ -x "${HASS_CTL}" ]; then
    log "HA: starting via hassctl"
    if "${HASS_CTL}" start >>"${LOG_FILE}" 2>&1; then
      log "HA: hassctl start succeeded"
    else
      log "HA: hassctl start failed (check ~/logs/hass-runner.log)"
    fi
    return
  fi

  if ! command_exists screen; then
    log "HA: screen binary not found; cannot start supervised session"
    return
  fi
  if [ ! -x "${HASS_SCRIPT}" ]; then
    log "HA: hass script is missing or not executable at ${HASS_SCRIPT}"
    return
  fi

  screen -wipe >/dev/null 2>&1 || true

  if screen -ls | grep -q "[.]hass"; then
    log "HA: screen session hass already exists"
    return
  fi

  log "HA: starting Home Assistant in screen session 'hass'"
  screen -dmS hass sh "${HASS_SCRIPT}"

  i=0
  while [ "$i" -lt 8 ]; do
    if screen -ls | grep -q "[.]hass"; then
      log "HA: screen session started"
      return
    fi
    i=$((i + 1))
    sleep 1
  done

  log "HA: failed to create screen session (check ~/logs/hass-runner.log)"
}

log "Bootstrap: begin"
ensure_hotspot
start_vpn
start_ssh
start_hass
log "Bootstrap: complete"
