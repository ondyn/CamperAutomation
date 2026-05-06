#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

# DNS on Android/Termux can be flaky during early startup.
# Keep a resolver file in Termux prefix and point c-ares to that file instead
# of forcing hardcoded upstream resolvers.
RESOLV_CONF="${PREFIX}/etc/resolv.conf"
export CARES_RESOLVCONF="${RESOLV_CONF}"
unset CARES_SERVERS
export RES_OPTIONS="timeout:2 attempts:2"

HOME_DIR="/data/data/com.termux/files/home"
VENV_ACTIVATE="${HOME_DIR}/.venv/bin/activate"
HASS_BIN="${HOME_DIR}/.venv/bin/hass"
LOG_DIR="${HOME_DIR}/logs"
RUN_LOG="${LOG_DIR}/hass-runner.log"

DEFAULT_ROOT_CONFIG="${HOME_DIR}/.suroot/.homeassistant"
DEFAULT_USER_CONFIG="${HOME_DIR}/.homeassistant"
HASS_CONFIG_DIR="${HASS_CONFIG_DIR:-${DEFAULT_ROOT_CONFIG}}"

detect_default_gateway() {
	local gateway
	gateway=""

	if command -v ip >/dev/null 2>&1; then
		gateway="$(ip route 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)"
	fi
	if [ -z "${gateway}" ] && [ -x /system/bin/ip ]; then
		gateway="$(/system/bin/ip route 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' || true)"
	fi
	if [ -z "${gateway}" ] && command -v python3 >/dev/null 2>&1; then
		gateway="$(python3 -c "import socket,struct; gw='';
for line in open('/proc/net/route', 'r', encoding='utf-8', errors='ignore').read().splitlines()[1:]:
    parts=line.split()
    if len(parts) > 2 and parts[1] == '00000000':
        gw=socket.inet_ntoa(struct.pack('<L', int(parts[2], 16)))
        break
print(gw)" 2>/dev/null || true)"
	fi
	printf '%s\n' "${gateway}"
}

ensure_dns_resolvers() {
	local target_dir
	local tmp_file
	local gateway

	target_dir="$(dirname "${RESOLV_CONF}")"
	mkdir -p "${target_dir}"
	tmp_file="${RESOLV_CONF}.tmp"
	gateway="$(detect_default_gateway || true)"

	{
		if [ -n "${gateway}" ]; then
			printf 'nameserver %s\n' "${gateway}"
		fi
		printf '%s\n' \
		  'nameserver 1.1.1.1' \
		  'nameserver 8.8.8.8' \
		  'nameserver 9.9.9.9' \
		  'options timeout:2 attempts:2'
	} >"${tmp_file}"

	if [ ! -f "${RESOLV_CONF}" ] || ! cmp -s "${tmp_file}" "${RESOLV_CONF}"; then
		mv "${tmp_file}" "${RESOLV_CONF}"
	else
		rm -f "${tmp_file}"
	fi
}

mkdir -p "${LOG_DIR}"
ensure_dns_resolvers

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

# Patch aiohttp AsyncResolver.resolve to use loop.getaddrinfo() (libc) instead
# of aiodns/c-ares which fails on Android due to socket restrictions on Termux
# app UIDs. HA 2026.x uses HassAsyncDNSResolver->AsyncDualMDNSResolver->AsyncResolver
# for all non-.local hostnames. Replacing AsyncResolver.resolve at the class level
# fixes the entire resolver chain without breaking any HA imports.
SITE_PKG="$(${HOME_DIR}/.venv/bin/python -c 'import site; print(site.getsitepackages()[0])')" 2>/dev/null
if [ -n "${SITE_PKG}" ] && [ -d "${SITE_PKG}" ]; then
	cat > "${SITE_PKG}/sitecustomize.py" <<'SC_EOF'
import sys
try:
    import asyncio
    import socket
    from aiohttp.resolver import AsyncResolver, ResolveResult

    async def _termux_resolve(self, host, port=0, family=socket.AF_INET):
        loop = asyncio.get_running_loop()
        infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM, family=family)
        if not infos:
            raise OSError(None, "getaddrinfo returned empty result for " + host)
        _flags = socket.AI_NUMERICHOST | socket.AI_NUMERICSERV
        return [
            ResolveResult(hostname=host, host=i[4][0], port=i[4][1],
                          family=i[0], proto=i[2], flags=_flags)
            for i in infos
        ]

    AsyncResolver.resolve = _termux_resolve
except Exception:
    import traceback
    traceback.print_exc(file=sys.stderr)
SC_EOF
	log "aiohttp AsyncResolver.resolve patch installed at ${SITE_PKG}/sitecustomize.py"
fi

# --ignore-os-check: Android returns sys.platform=="linux" but HA's validate_os
# still rejects it; this flag bypasses the check safely on Termux.
# --skip-pip: keep startup deterministic and avoid runtime dependency installs,
# which are fragile on Android/Termux and can fail on uv/pip backend specifics.
exec "${HASS_BIN}" --ignore-os-check --skip-pip -c "${HASS_CONFIG_DIR}" >>"${RUN_LOG}" 2>&1
