#!/data/data/com.termux/files/usr/bin/sh
set -eu

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

HOME_DIR="/data/data/com.termux/files/home"
HASS_SCRIPT="${HOME_DIR}/scripts/hass.sh"
HASS_BIN="${HOME_DIR}/.venv/bin/hass"
LOG_DIR="${HOME_DIR}/logs"
RUN_LOG="${LOG_DIR}/hass-runner.log"
SESSION_NAME="hass"
HTTP_URL="http://127.0.0.1:8123/"
RESOLV_CONF="${PREFIX}/etc/resolv.conf"
DNS_WAIT_SECONDS="${DNS_WAIT_SECONDS:-12}"
HASS_CONFIG_PATTERN="${HOME_DIR}/.homeassistant"

mkdir -p "${LOG_DIR}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"${RUN_LOG}"
}

ensure_dns_resolvers() {
  local target_dir
  local tmp_file

  target_dir="$(dirname "${RESOLV_CONF}")"
  mkdir -p "${target_dir}"
  tmp_file="${RESOLV_CONF}.tmp"

  cat >"${tmp_file}" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
options timeout:2 attempts:2
EOF

  if [ ! -f "${RESOLV_CONF}" ] || ! cmp -s "${tmp_file}" "${RESOLV_CONF}"; then
    mv "${tmp_file}" "${RESOLV_CONF}"
    log "hassctl: wrote resolver config to ${RESOLV_CONF}"
  else
    rm -f "${tmp_file}"
  fi
}

dns_ready() {
  python3 -c "import socket; socket.getaddrinfo('github.com', 443); socket.getaddrinfo('api.github.com', 443)" >/dev/null 2>&1
}

wait_for_dns() {
  local i
  i=0
  while [ "$i" -lt "${DNS_WAIT_SECONDS}" ]; do
    if dns_ready; then
      log "hassctl: DNS probe succeeded for github.com"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  log "hassctl: DNS probe failed for github.com after ${DNS_WAIT_SECONDS}s"
  return 1
}

has_screen_session() {
  screen -ls 2>/dev/null | grep -q "[.]${SESSION_NAME}"
}

has_hass_process() {
  pgrep -f "${HASS_BIN} --ignore-os-check --skip-pip -c ${HASS_CONFIG_PATTERN}" >/dev/null 2>&1
}

list_hass_processes() {
  pgrep -a -f "${HASS_BIN} --ignore-os-check --skip-pip -c ${HASS_CONFIG_PATTERN}" || true
}

wait_for_exit() {
  i=0
  while [ "$i" -lt 20 ]; do
    if ! has_screen_session && ! has_hass_process; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_for_http() {
  i=0
  while [ "$i" -lt 60 ]; do
    if command -v curl >/dev/null 2>&1; then
      code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "${HTTP_URL}" || true)"
      case "$code" in
        200|401|403)
          return 0
          ;;
      esac
    elif has_hass_process; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

start_hass() {
  if [ ! -x "${HASS_SCRIPT}" ]; then
    echo "ERROR: missing executable ${HASS_SCRIPT}" >&2
    exit 1
  fi

  ensure_dns_resolvers
  wait_for_dns || true

  screen -wipe >/dev/null 2>&1 || true

  if has_hass_process; then
    echo "Home Assistant is already running."
    return 0
  fi

  if has_screen_session; then
    echo "Removing stale screen session .${SESSION_NAME}."
    screen -S "${SESSION_NAME}" -X quit >/dev/null 2>&1 || true
    wait_for_exit || true
  fi

  log "hassctl: starting Home Assistant"
  screen -dmS "${SESSION_NAME}" sh "${HASS_SCRIPT}"

  if wait_for_http; then
    echo "Home Assistant started."
    return 0
  fi

  echo "ERROR: Home Assistant did not become ready in time." >&2
  echo "Check ${RUN_LOG} for details." >&2
  exit 1
}

stop_hass() {
  if has_screen_session; then
    log "hassctl: stopping Home Assistant screen session"
    screen -S "${SESSION_NAME}" -X quit >/dev/null 2>&1 || true
  fi

  if has_hass_process; then
    log "hassctl: terminating remaining Home Assistant process"
    pkill -TERM -f "${HASS_BIN} --ignore-os-check --skip-pip -c ${HASS_CONFIG_PATTERN}" >/dev/null 2>&1 || true
  fi

  if wait_for_exit; then
    echo "Home Assistant stopped."
    return 0
  fi

  if has_hass_process; then
    log "hassctl: forcing remaining Home Assistant process to exit"
    pkill -KILL -f "${HASS_BIN} --ignore-os-check --skip-pip -c ${HASS_CONFIG_PATTERN}" >/dev/null 2>&1 || true
  fi
  screen -wipe >/dev/null 2>&1 || true

  if wait_for_exit; then
    echo "Home Assistant stopped."
    return 0
  fi

  echo "ERROR: Home Assistant did not stop cleanly." >&2
  echo "Check ${RUN_LOG} for details." >&2
  list_hass_processes >&2
  exit 1
}

status_hass() {
  if has_hass_process; then
    echo "status: running"
    list_hass_processes
  elif has_screen_session; then
    echo "status: stale-screen"
  else
    echo "status: stopped"
  fi
}

usage() {
  echo "Usage: $0 {start|stop|restart|status}" >&2
}

case "${1:-}" in
  start)
    start_hass
    ;;
  stop)
    stop_hass
    ;;
  restart)
    stop_hass || true
    start_hass
    ;;
  status)
    status_hass
    ;;
  *)
    usage
    exit 1
    ;;
esac