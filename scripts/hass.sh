#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

# DNS on Android/Termux can be flaky during early startup; pin resolvers for
# libraries using c-ares (aiodns) and for libc resolver behavior.
export CARES_SERVERS="1.1.1.1,8.8.8.8,9.9.9.9"
export RES_OPTIONS="timeout:2 attempts:2"

HOME_DIR="/data/data/com.termux/files/home"
VENV_ACTIVATE="${HOME_DIR}/.venv/bin/activate"
HASS_BIN="${HOME_DIR}/.venv/bin/hass"
LOG_DIR="${HOME_DIR}/logs"
RUN_LOG="${LOG_DIR}/hass-runner.log"

DEFAULT_ROOT_CONFIG="${HOME_DIR}/.suroot/.homeassistant"
DEFAULT_USER_CONFIG="${HOME_DIR}/.homeassistant"
HASS_CONFIG_DIR="${HASS_CONFIG_DIR:-${DEFAULT_ROOT_CONFIG}}"

mkdir -p "${LOG_DIR}"

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"${RUN_LOG}"
}

if [ ! -f "${VENV_ACTIVATE}" ]; then
	log "ERROR: missing venv activate script at ${VENV_ACTIVATE}"
	exit 1
fi

. "${VENV_ACTIVATE}"

if [ ! -d "${HASS_CONFIG_DIR}" ] || [ ! -w "${HASS_CONFIG_DIR}" ]; then
	HASS_CONFIG_DIR="${DEFAULT_USER_CONFIG}"
fi
mkdir -p "${HASS_CONFIG_DIR}"

if [ ! -x "${HASS_BIN}" ]; then
	log "ERROR: hass executable not found at ${HASS_BIN}"
	exit 1
fi

log "Starting Home Assistant with config ${HASS_CONFIG_DIR}"
# --ignore-os-check: Android returns sys.platform=="linux" but HA's validate_os
# still rejects it; this flag bypasses the check safely on Termux.
# --skip-pip: keep startup deterministic and avoid runtime dependency installs,
# which are fragile on Android/Termux and can fail on uv/pip backend specifics.
exec "${HASS_BIN}" --ignore-os-check --skip-pip -c "${HASS_CONFIG_DIR}" >>"${RUN_LOG}" 2>&1
