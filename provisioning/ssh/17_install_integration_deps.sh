#!/usr/bin/env bash
set -euo pipefail

# Validate that Home Assistant can install integration dependencies dynamically
# (the runtime path used by config flows), and restart HA afterwards.
#
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/17_install_integration_deps.sh
#
# Optional variables:
#   SSH_PORT=8022
#   SSH_IDENTITY=~/.ssh/camper_automation_rsa
#   SSH_PASSWORD=secret
#   INTEGRATION_TEST_PKG=accuweather==5.0.0

auto_detect_phone_host_adb() {
	local host=""
	host="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
	[ -n "${host}" ] || host="$(adb shell getprop dhcp.ap.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
	[ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
	echo "${host}"
}

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

if [ -z "${PHONE_HOST:-}" ]; then
	echo "Auto-detecting PHONE_HOST..."
	PHONE_HOST="$(auto_detect_phone_host_adb)"
	[ -n "${PHONE_HOST}" ] || { echo "ERROR: Could not auto-detect PHONE_HOST" >&2; exit 1; }
	echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER:-}" ]; then
	echo "Auto-detecting PHONE_USER..."
	PHONE_USER="$(auto_detect_phone_user_adb || true)"
	[ -n "${PHONE_USER}" ] || { echo "ERROR: Could not auto-detect PHONE_USER" >&2; exit 1; }
	echo "Detected PHONE_USER=${PHONE_USER}"
fi

SSH_PORT="${SSH_PORT:-8022}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"
INTEGRATION_TEST_PKG="${INTEGRATION_TEST_PKG:-accuweather==5.0.0}"

SSH_ID_ARGS=()
if [ -f "${SSH_IDENTITY}" ] && [ -z "${SSH_PASSWORD}" ]; then
	SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
fi

SSH_TRANSPORT=(ssh)
SSH_AUTH_OPTS=()
if [ -n "${SSH_PASSWORD}" ]; then
	if ! command -v sshpass >/dev/null 2>&1; then
		echo "ERROR: sshpass is required for password-based provisioning SSH flow." >&2
		exit 1
	fi
	SSH_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" ssh)
	SSH_AUTH_OPTS=(
		-o PubkeyAuthentication=no
		-o PreferredAuthentications=password
		-o NumberOfPasswordPrompts=1
	)
fi

SSH_BASE=("${SSH_TRANSPORT[@]}" -F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new)
if [ ${#SSH_AUTH_OPTS[@]} -gt 0 ]; then
	SSH_BASE+=("${SSH_AUTH_OPTS[@]}")
fi
if [ ${#SSH_ID_ARGS[@]} -gt 0 ]; then
	SSH_BASE+=("${SSH_ID_ARGS[@]}")
fi
SSH_BASE+=("${PHONE_USER}@${PHONE_HOST}")

echo "Validating integration dependency install path on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."

"${SSH_BASE[@]}" "TEST_PKG='${INTEGRATION_TEST_PKG}' bash -s" <<'REMOTE_INSTALL'
set -euo pipefail

VENV_PY="$HOME/.venv/bin/python"
HASS_CTL="$HOME/scripts/hassctl.sh"
RUN_LOG="$HOME/logs/hass-runner.log"

if [ ! -x "$VENV_PY" ]; then
	echo "ERROR: missing HA venv at $VENV_PY" >&2
	exit 1
fi
if [ ! -x "$HASS_CTL" ]; then
	echo "ERROR: missing hassctl at $HASS_CTL" >&2
	exit 1
fi

echo "Checking Home Assistant launch arguments..."
if grep -q -- '--skip-pip' "$HOME/scripts/hass.sh"; then
	echo "ERROR: ~/scripts/hass.sh still contains --skip-pip" >&2
	exit 1
fi
if ! grep -q 'ANDROID_API_LEVEL' "$HOME/scripts/hass.sh"; then
	echo "ERROR: ~/scripts/hass.sh does not export ANDROID_API_LEVEL for runtime builds" >&2
	exit 1
fi

ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-}"
if [ -z "$ANDROID_API_LEVEL" ]; then
	ANDROID_API_LEVEL="$("$VENV_PY" - 2>/dev/null <<'PYEOF'
import sysconfig
print(sysconfig.get_config_var("ANDROID_API_LEVEL") or "")
PYEOF
	|| true)"
fi
if [ -z "$ANDROID_API_LEVEL" ]; then
	ANDROID_API_LEVEL="$(getprop ro.build.version.sdk 2>/dev/null || true)"
fi
if [ -n "$ANDROID_API_LEVEL" ]; then
	export ANDROID_API_LEVEL
	echo "Using ANDROID_API_LEVEL=${ANDROID_API_LEVEL}"
else
	echo "WARNING: could not determine ANDROID_API_LEVEL for test install"
fi

echo "Testing package resolver in HA venv with: ${TEST_PKG}"
"$VENV_PY" -m pip install --disable-pip-version-check --dry-run "$TEST_PKG"

echo "Restarting Home Assistant to ensure control path still works..."
"$HASS_CTL" restart
"$HASS_CTL" status

echo "Recent Home Assistant runner log tail:"
tail -n 40 "$RUN_LOG" || true

echo "Integration dependency validation completed successfully."
REMOTE_INSTALL

echo "Done. Integration dependency auto-install path is enabled and validated."
