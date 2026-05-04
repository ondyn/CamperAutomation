#!/usr/bin/env bash
set -euo pipefail

# Sets up Tailscale userspace-networking VPN on the Termux phone.
#
# Usage:
#   ./provisioning/ssh/40_setup_tailscale.sh [--authkey TSKEY-xxx-...]
#   PHONE_HOST=192.168.1.224 PHONE_USER=u0_a264 ./provisioning/ssh/40_setup_tailscale.sh
#   PHONE_HOST=192.168.1.224 PHONE_USER=u0_a264 ./provisioning/ssh/40_setup_tailscale.sh --authkey TSKEY-xxx-...
#
# Without --authkey the script prints a Tailscale auth URL for browser-based login.
# With --authkey the script authenticates non-interactively (use a reusable auth key
# generated at https://login.tailscale.com/admin/settings/keys).
#
# After this script succeeds, Tailscale will start automatically on every boot
# via bootstrap_services.sh (start_vpn()).  The Tailscale IP can be found with:
#   ~/vpn/tailscale --socket $PREFIX/var/run/tailscale/tailscaled.sock status

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
AUTHKEY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)
      AUTHKEY="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--authkey TSKEY-xxx-...]" >&2
      exit 1
      ;;
  esac
done

# --------------------------------------------------------------------------
# Auto-detect helpers (same pattern as 10_install_homeassistant_core.sh)
# --------------------------------------------------------------------------

auto_detect_phone_host_adb() {
  local host=""
  host="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell getprop dhcp.ap.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan1 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 route 2>/dev/null | awk '/wlan/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 | tr -d '\r' || true)"
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

# --------------------------------------------------------------------------
# Resolve phone host/user
# --------------------------------------------------------------------------

if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST..."
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb is not available for auto-detection." >&2
    echo "Set PHONE_HOST manually, e.g. PHONE_HOST=192.168.1.224" >&2
    exit 1
  fi
  PHONE_HOST="$(auto_detect_phone_host_adb)"
  if [ -z "${PHONE_HOST}" ]; then
    echo "ERROR: Could not auto-detect PHONE_HOST via ADB." >&2
    echo "Check: adb devices && adb shell ip -4 addr show wlan0" >&2
    echo "Or run with manual host: PHONE_HOST=<PHONE_IP> $0" >&2
    exit 1
  fi
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER=""
  if command -v adb >/dev/null 2>&1; then
    PHONE_USER="$(auto_detect_phone_user_adb || true)"
  fi
  if [ -n "${PHONE_USER}" ]; then
    echo "Detected PHONE_USER=${PHONE_USER}"
  else
    echo "ERROR: Could not auto-detect PHONE_USER." >&2
    echo "Set manually: PHONE_USER=u0_aNNN $0" >&2
    exit 1
  fi
fi

: "${PHONE_HOST?Set PHONE_HOST to phone IP/hostname}"
: "${PHONE_USER?Set PHONE_USER to Termux username, e.g. u0_a123}"

# --------------------------------------------------------------------------
# SSH multiplexing setup
# --------------------------------------------------------------------------

SSH_OPTS=(
  -p "${SSH_PORT}"
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="/tmp/cm-tailscale-%C"
)

cleanup_ssh_mux() {
  ssh "${SSH_OPTS[@]}" -O exit "${PHONE_USER}@${PHONE_HOST}" >/dev/null 2>&1 || true
}
trap cleanup_ssh_mux EXIT

echo "Connecting to ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."
ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'true'

# --------------------------------------------------------------------------
# Remote installation
# --------------------------------------------------------------------------
# Pass AUTHKEY safely — use env var injection rather than shell interpolation
# to avoid any risk of shell injection via key characters.
# --------------------------------------------------------------------------

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" \
  "TAILSCALE_AUTHKEY=$(printf '%s' "${AUTHKEY}" | base64) bash -s" <<'REMOTE_SETUP'
set -euo pipefail

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH TMPDIR="${PREFIX}/tmp"
mkdir -p "${TMPDIR}"

VPN_DIR="$HOME/vpn"
TAILSCALED_BIN="${VPN_DIR}/tailscaled"
TAILSCALE_BIN="${VPN_DIR}/tailscale"
TAILSCALE_SOCKET="${PREFIX}/var/run/tailscale/tailscaled.sock"
TAILSCALE_STATE="${PREFIX}/var/lib/tailscale/tailscaled.state"
CACHE_DIR="$HOME/.cache/provisioning/tailscale"

# Decode AUTHKEY (passed as base64 to avoid shell quoting issues)
AUTHKEY="$(echo "${TAILSCALE_AUTHKEY:-}" | base64 -d 2>/dev/null || true)"

mkdir -p "${VPN_DIR}" "${CACHE_DIR}" "${HOME}/logs" \
  "${PREFIX}/var/run/tailscale" \
  "${PREFIX}/var/lib/tailscale"

# --------------------------------------------------------------------------
# Detect root availability (Magisk su)
# tailscaled needs CAP_NET_ADMIN to read the kernel routing table (netlinkrib).
# On Android/Termux this is denied unless we run tailscaled as root via su.
# --------------------------------------------------------------------------
HAS_ROOT=0
if command -v su >/dev/null 2>&1 && su -c 'true' >/dev/null 2>&1; then
  HAS_ROOT=1
  echo "Root (su) is available — tailscaled will be started as root"
else
  echo "WARNING: Root (su) not available — tailscaled will run as Termux user."
  echo "  On Android this usually fails with 'netlinkrib: permission denied'."
  echo "  Grant Termux root access in Magisk Manager and rerun this script."
fi

# --------------------------------------------------------------------------
# Detect phone architecture
# --------------------------------------------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64)  TS_ARCH="arm64" ;;
  armv7l|armv8l) TS_ARCH="arm" ;;
  x86_64)   TS_ARCH="amd64" ;;
  i686)     TS_ARCH="386" ;;
  *)
    echo "ERROR: Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac
echo "Detected arch: ${ARCH} -> Tailscale arch: ${TS_ARCH}"

# --------------------------------------------------------------------------
# Check if binaries are already installed (and usable)
# --------------------------------------------------------------------------
if [ -x "${TAILSCALED_BIN}" ] && [ -x "${TAILSCALE_BIN}" ]; then
  INSTALLED_VERSION="$("${TAILSCALE_BIN}" version 2>/dev/null | head -n1 | awk '{print $1}' || true)"
  if [ -n "${INSTALLED_VERSION}" ]; then
    echo "Tailscale ${INSTALLED_VERSION} already installed at ${VPN_DIR} — skipping download"
    SKIP_DOWNLOAD=1
  fi
fi
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"

# --------------------------------------------------------------------------
# Download latest stable tarball
# --------------------------------------------------------------------------
if [ "${SKIP_DOWNLOAD}" = "0" ]; then
  echo "Fetching latest Tailscale release info..."
  TS_META=$(curl -sf --retry 3 --retry-delay 2 "https://pkgs.tailscale.com/stable/?mode=json")
  TS_TARBALL=$(printf '%s' "${TS_META}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['Tarballs']['${TS_ARCH}'])")
  TS_VERSION=$(printf '%s' "${TS_META}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['Tarballs']['${TS_ARCH}'].split('_')[1])")
  DOWNLOAD_URL="https://pkgs.tailscale.com/stable/${TS_TARBALL}"
  TARBALL_PATH="${CACHE_DIR}/${TS_TARBALL}"

  echo "Downloading Tailscale ${TS_VERSION} (${TS_ARCH})..."
  curl -Lf --retry 3 --retry-delay 2 -o "${TARBALL_PATH}" "${DOWNLOAD_URL}"

  echo "Extracting binaries..."
  EXTRACT_DIR="${CACHE_DIR}/extract"
  rm -rf "${EXTRACT_DIR}"
  mkdir -p "${EXTRACT_DIR}"
  tar -xzf "${TARBALL_PATH}" -C "${EXTRACT_DIR}" --strip-components=1

  # Copy binaries to ~/vpn/
  cp "${EXTRACT_DIR}/tailscaled" "${TAILSCALED_BIN}"
  cp "${EXTRACT_DIR}/tailscale"  "${TAILSCALE_BIN}"
  chmod +x "${TAILSCALED_BIN}" "${TAILSCALE_BIN}"
  rm -rf "${EXTRACT_DIR}"
  echo "Installed: ${TAILSCALED_BIN} and ${TAILSCALE_BIN}"
fi

# --------------------------------------------------------------------------
# Start tailscaled (if not already running)
# --------------------------------------------------------------------------
if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "tailscaled is already running"
  # Ensure socket is accessible by Termux user (may have been started as root previously)
  if [ "${HAS_ROOT}" = "1" ] && [ -S "${TAILSCALE_SOCKET}" ]; then
    su -c "chmod 666 ${TAILSCALE_SOCKET}" >/dev/null 2>&1 || true
  fi
else
  # Remove any stale socket from a previous failed start
  rm -f "${TAILSCALE_SOCKET}"

  echo "Starting tailscaled (userspace-networking, root=${HAS_ROOT})..."
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "nohup ${TAILSCALED_BIN} -tun userspace-networking --state=${TAILSCALE_STATE} -socket ${TAILSCALE_SOCKET} >> ${HOME}/logs/tailscaled.log 2>&1 &"
  else
    nohup "${TAILSCALED_BIN}" \
      -tun userspace-networking \
      --state="${TAILSCALE_STATE}" \
      -socket "${TAILSCALE_SOCKET}" \
      >"${HOME}/logs/tailscaled.log" 2>&1 &
  fi

  echo "Waiting for tailscaled socket..."
  for i in $(seq 1 20); do
    if [ -S "${TAILSCALE_SOCKET}" ]; then
      echo "tailscaled socket is ready (${i}s)"
      break
    fi
    sleep 1
  done
  if [ ! -S "${TAILSCALE_SOCKET}" ]; then
    echo "ERROR: tailscaled socket did not appear after 20s" >&2
    echo "Check: cat ${HOME}/logs/tailscaled.log" >&2
    cat "${HOME}/logs/tailscaled.log" >&2 || true
    exit 1
  fi

  # Make socket world-rw so Termux user can run tailscale CLI without root.
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "chmod 666 ${TAILSCALE_SOCKET}" >/dev/null 2>&1 || true
  fi
fi

# --------------------------------------------------------------------------
# Set tailscale operator so Termux user can run tailscale CLI without root
# after provisioning (e.g. manual status checks). Persisted in state file.
# --------------------------------------------------------------------------
if [ "${HAS_ROOT}" = "1" ]; then
  CURRENT_USER="$(id -nu 2>/dev/null || true)"
  if [ -n "${CURRENT_USER}" ]; then
    su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} set --operator=${CURRENT_USER}" >/dev/null 2>&1 \
      && echo "Set tailscale operator to ${CURRENT_USER}" \
      || echo "(tailscale set --operator may not be supported in this version)"
  fi
fi

# --------------------------------------------------------------------------
# Check if already authenticated
# --------------------------------------------------------------------------
TS_STATUS=$("${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status --json 2>/dev/null || echo '{}')
BACKEND_STATE=$(printf '%s' "${TS_STATUS}" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")

echo "Tailscale backend state: ${BACKEND_STATE}"

if [ "${BACKEND_STATE}" = "Running" ]; then
  echo "Tailscale is already authenticated and connected."
elif [ -n "${AUTHKEY}" ]; then
  # --------------------------------------------------------------------------
  # Authenticate with pre-auth key (non-interactive).
  # Must run via su when tailscaled is root-owned (Android netlinkrib workaround).
  # Note: auth key briefly visible in device process list; rotate key after setup.
  # --------------------------------------------------------------------------
  echo "Authenticating with auth key..."
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} up --authkey=${AUTHKEY} --accept-dns=false --accept-routes"
  else
    "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" up \
      --authkey="${AUTHKEY}" \
      --accept-dns=false \
      --accept-routes
  fi
  echo "Authentication with auth key complete."
else
  # --------------------------------------------------------------------------
  # Interactive browser-based auth.
  # Run tailscale up in the foreground — the auth URL prints directly to the
  # terminal. Script blocks here until you complete login in the browser.
  # Must run via su when tailscaled is root-owned.
  # --------------------------------------------------------------------------
  echo ""
  echo "=========================================================="
  echo "  TAILSCALE AUTHENTICATION REQUIRED"
  echo "  The auth URL will appear on the next line."
  echo "  Open it in a browser, log in, and this script will continue."
  echo "=========================================================="
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} up --accept-dns=false --accept-routes" || true
  else
    "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" up \
      --accept-dns=false \
      --accept-routes || true
  fi
  echo "tailscale up completed."
fi

# --------------------------------------------------------------------------
# Final status
# --------------------------------------------------------------------------
echo ""
echo "--- Tailscale status ---"
"${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status || true
echo "--- end status ---"
echo ""

FINAL_STATE=$("${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status --json 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" \
  2>/dev/null || echo "Unknown")

TAILSCALE_IP=$("${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" ip -4 2>/dev/null | head -1 || true)

if [ "${FINAL_STATE}" = "Running" ]; then
  echo "Tailscale is connected."
  echo "Tailscale IPv4: ${TAILSCALE_IP:-<not yet assigned>}"
  echo ""
  echo "Home Assistant Companion connection URL (when on Tailscale):"
  echo "  http://${TAILSCALE_IP:-<tailscale-ip>}:8123"
else
  echo "WARNING: Tailscale state is '${FINAL_STATE}'."
  echo "If auth URL was shown above, complete browser auth then rerun this script or run on phone:"
  echo "  ~/vpn/tailscale --socket \$PREFIX/var/run/tailscale/tailscaled.sock status"
fi

echo ""
echo "Tailscale will auto-start on next boot via ~/scripts/bootstrap_services.sh."
echo "To check after reboot: ssh -p 8022 ... 'cat ~/logs/bootstrap.log | grep VPN'"
REMOTE_SETUP

echo ""
echo "Setup script completed. Check output above for Tailscale status and IP."
