#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock

LOG_DIR="/data/data/com.termux/files/home/logs"
LOG_FILE="${LOG_DIR}/bootstrap.log"
HASS_SCRIPT="/data/data/com.termux/files/home/scripts/hass.sh"
TAILSCALED_BIN="/data/data/com.termux/files/home/vpn/tailscaled"
TAILSCALE_BIN="/data/data/com.termux/files/home/vpn/tailscale"
TAILSCALE_SOCKET="$PREFIX/var/run/tailscale/tailscaled.sock"
TAILSCALE_STATE="$PREFIX/var/lib/tailscale/tailscaled.state"

mkdir -p "${LOG_DIR}"

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
  if pgrep -f "tailscaled.*userspace-networking" >/dev/null 2>&1; then
    log "VPN: tailscaled is already running"
  else
    log "VPN: starting tailscaled"
    nohup sudo "${TAILSCALED_BIN}" -tun userspace-networking --state="${TAILSCALE_STATE}" -socket "${TAILSCALE_SOCKET}" >>"${LOG_FILE}" 2>&1 &
  fi

  if wait_for_tailscale_socket; then
    log "VPN: tailscaled socket is ready"
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
  if pgrep -x sshd >/dev/null 2>&1; then
    log "SSH: sshd is already running"
  else
    log "SSH: starting sshd"
    sshd >>"${LOG_FILE}" 2>&1
  fi
}

start_hass() {
  if screen -ls | grep -q "[.]hass"; then
    log "HA: screen session hass already exists"
    return
  fi

  log "HA: starting Home Assistant in screen session 'hass'"
  screen -dmS hass sh "${HASS_SCRIPT}"

  if screen -ls | grep -q "[.]hass"; then
    log "HA: screen session started"
  else
    log "HA: failed to create screen session"
  fi
}

log "Bootstrap: begin"
start_vpn
start_ssh
start_hass
log "Bootstrap: complete"
