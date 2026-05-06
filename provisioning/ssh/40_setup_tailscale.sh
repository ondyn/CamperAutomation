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
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"

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
  -F /dev/null
  -p "${SSH_PORT}"
  -o ClearAllForwardings=yes
  -o ForwardAgent=no
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="/tmp/cm-tailscale-%C"
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=6
)

SSH_TRANSPORT=(ssh)
if [ -n "${SSH_PASSWORD}" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required for password-based provisioning SSH flow." >&2
    exit 1
  fi
  SSH_TRANSPORT=(sshpass -p "${SSH_PASSWORD}" ssh)
  SSH_OPTS+=(
    -o PubkeyAuthentication=no
    -o PreferredAuthentications=password
    -o NumberOfPasswordPrompts=1
  )
fi

cleanup_ssh_mux() {
  "${SSH_TRANSPORT[@]}" "${SSH_OPTS[@]}" -O exit "${PHONE_USER}@${PHONE_HOST}" >/dev/null 2>&1 || true
}
trap cleanup_ssh_mux EXIT

echo "Connecting to ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."
"${SSH_TRANSPORT[@]}" "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'true'

# --------------------------------------------------------------------------
# Remote installation
# --------------------------------------------------------------------------
# Pass AUTHKEY safely — use env var injection rather than shell interpolation
# to avoid any risk of shell injection via key characters.
# --------------------------------------------------------------------------

"${SSH_TRANSPORT[@]}" "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" \
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
  elif [ -S "${TAILSCALE_SOCKET}" ] || pgrep -x tailscaled >/dev/null 2>&1; then
    echo "tailscaled already running (socket present) — skipping download"
    SKIP_DOWNLOAD=1
  fi
fi
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"

# --------------------------------------------------------------------------
# Download static binaries from Tailscale official repository
# For Android/Termux, we download the static PIE binaries directly
# --------------------------------------------------------------------------
if [ "${SKIP_DOWNLOAD}" = "0" ]; then
  # Stop any running tailscaled first to avoid 'Text file busy' when overwriting the binary
  if [ -S "${TAILSCALE_SOCKET}" ] || pgrep -x tailscaled >/dev/null 2>&1; then
    echo "Stopping running tailscaled before binary update..."
    if [ "${HAS_ROOT}" = "1" ]; then
      su -c 'pkill tailscaled 2>/dev/null || kill $(pgrep tailscaled 2>/dev/null) 2>/dev/null || true' >/dev/null 2>&1 || true
    else
      pkill tailscaled >/dev/null 2>&1 || true
    fi
    rm -f "${TAILSCALE_SOCKET}"
    sleep 2
  fi

  echo "Fetching latest Tailscale release info..."
  TS_META=$(curl -sf --retry 3 --retry-delay 2 "https://pkgs.tailscale.com/stable/?mode=json")
  TS_VERSION=$(printf '%s' "${TS_META}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d['Tarballs']['${TS_ARCH}'].split('_')[1])")
  
  echo "Tailscale version: ${TS_VERSION}"

  # Try installing via Termux package manager first (more reliable for PIE binaries)
  echo "Attempting to install via Termux package manager..."
  if pkg install -y tailscale >/dev/null 2>&1; then
    echo "✓ Tailscale installed via package manager"
    # Copy binaries to ~/vpn/ for consistency
    mkdir -p ~/vpn
    cp "$PREFIX/bin/tailscaled" ~/vpn/tailscaled
    cp "$PREFIX/bin/tailscale" ~/vpn/tailscale
    chmod +x ~/vpn/tail*
  else
    echo "Package manager unavailable, downloading static binaries..."
    # Map architecture to Tailscale download naming convention
    case "${TS_ARCH}" in
      arm64)   DL_ARCH="arm64" ;;
      arm)     DL_ARCH="arm" ;;
      amd64)   DL_ARCH="amd64" ;;
      386)     DL_ARCH="386" ;;
      *)
        echo "ERROR: Tailscale does not support architecture: ${TS_ARCH}" >&2
        exit 1
        ;;
    esac

    mkdir -p "${CACHE_DIR}"
    
    # Download from Tailscale official pkgs.tailscale.com
    # As of 2024, these are typically statically-linked but may not be PIE
    TS_TARBALL=$(printf '%s' "${TS_META}" | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print(d['Tarballs']['${TS_ARCH}'])")
    DOWNLOAD_URL="https://pkgs.tailscale.com/stable/${TS_TARBALL}"
    TARBALL_PATH="${CACHE_DIR}/${TS_TARBALL}"

    echo "Downloading from: ${DOWNLOAD_URL}"
    curl -Lf --retry 3 --retry-delay 2 -o "${TARBALL_PATH}" "${DOWNLOAD_URL}"

    echo "Extracting binaries..."
    EXTRACT_DIR="${CACHE_DIR}/extract"
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"
    tar -xzf "${TARBALL_PATH}" -C "${EXTRACT_DIR}" --strip-components=1

    # Copy binaries locally to ~/vpn/
    mkdir -p ~/vpn
    cp "${EXTRACT_DIR}/tailscaled" ~/vpn/tailscaled
    cp "${EXTRACT_DIR}/tailscale"  ~/vpn/tailscale
    chmod +x ~/vpn/tailscaled ~/vpn/tailscale
    
    rm -rf "${EXTRACT_DIR}"
    echo "Installed: ~/vpn/tailscaled and ~/vpn/tailscale (via tarball)"
  fi
  
  # Verify binaries are valid ELF executables (tailscaled daemon won't respond to -version)
  echo "Verifying binary integrity..."
  
  TAILSCALED_INFO=$(file "${TAILSCALED_BIN}" 2>/dev/null || echo "")
  TAILSCALE_INFO=$(file "${TAILSCALE_BIN}" 2>/dev/null || echo "")
  
  if ! echo "${TAILSCALED_INFO}" | grep -q "ELF.*executable"; then
    echo "ERROR: tailscaled binary appears to be corrupted or wrong type" >&2
    echo "       File info: ${TAILSCALED_INFO}" >&2
    exit 1
  fi
  
  if ! echo "${TAILSCALE_INFO}" | grep -q "ELF.*executable"; then
    echo "ERROR: tailscale binary appears to be corrupted or wrong type" >&2
    echo "       File info: ${TAILSCALE_INFO}" >&2
    exit 1
  fi
  
  echo "✓ Binary integrity verified"
  echo "  tailscaled: ${TAILSCALED_INFO}"
  echo "  tailscale:  ${TAILSCALE_INFO}"
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
    # Check for PIE/ELF compatibility issue
    if grep -q "unexpected e_type: 2" "${HOME}/logs/tailscaled.log" 2>/dev/null; then
      echo ""
      echo "=========================================================="
      echo "⚠  VPN SETUP INCOMPLETE - Non-PIE Binary"
      echo "=========================================================="
      echo ""
      echo "The Tailscale binary on this device is non-PIE, which"
      echo "requires Android root access (Magisk) to run."
      echo ""
      echo "Next steps to fix this:"
      echo "  1. Ensure Magisk is installed on your device"
      echo "  2. grant Termux root access in Magisk Manager"
      echo "  3. Rerun the provisioning script"
      echo ""
      echo "For now, you can still access Home Assistant via:"
      echo "  • ADB port forward: adb forward tcp:8123 tcp:8123"
      echo "  • Direct LAN if on same network"
      echo ""
      echo "Proceeding with remaining provisioning steps..."
    else
      echo "ERROR: tailscaled socket did not appear after 20s" >&2
      echo "Check: cat ${HOME}/logs/tailscaled.log" >&2
      cat "${HOME}/logs/tailscaled.log" >&2 || true
      exit 1
    fi
  fi

  # Make socket world-rw so Termux user can run tailscale CLI without root.
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "chmod 666 ${TAILSCALE_SOCKET}" >/dev/null 2>&1 || true
  fi
fi

# --------------------------------------------------------------------------
# Check if already authenticated
# --------------------------------------------------------------------------
check_tailscale_auth() {
  "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status --json 2>/dev/null || echo '{}'
}

TS_STATUS=$(check_tailscale_auth)
BACKEND_STATE=$(printf '%s' "${TS_STATUS}" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")

echo "Tailscale backend state: ${BACKEND_STATE}"

if [ "${BACKEND_STATE}" = "Running" ]; then
  echo "✓ Tailscale is already authenticated and connected."
elif [ -n "${AUTHKEY}" ]; then
  # --------------------------------------------------------------------------
  # Authenticate with pre-auth key (non-interactive).
  # Must run via su when tailscaled is root-owned (Android netlinkrib workaround).
  # Note: auth key briefly visible in device process list; rotate key after setup.
  # --------------------------------------------------------------------------
  echo "Authenticating with provided auth key..."
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} up --authkey=${AUTHKEY} --accept-dns=false --accept-routes" >/dev/null 2>&1
  else
    "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" up \
      --authkey="${AUTHKEY}" \
      --accept-dns=false \
      --accept-routes >/dev/null 2>&1 || true
  fi
  
  # Wait for authentication to complete
  sleep 2
  TS_STATUS=$(check_tailscale_auth)
  BACKEND_STATE=$(printf '%s' "${TS_STATUS}" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")
  
  if [ "${BACKEND_STATE}" = "Running" ]; then
    echo "✓ Successfully authenticated with auth key"
  else
    echo "WARNING: Auth key authentication may not have completed. State: ${BACKEND_STATE}"
  fi
else
  # --------------------------------------------------------------------------
  # Interactive browser-based auth (first-time setup).
  # Show auth URL and wait for browser confirmation before continuing.
  # Must run via su when tailscaled is root-owned.
  # --------------------------------------------------------------------------
  echo ""
  echo "=========================================================="
  echo "  TAILSCALE AUTHENTICATION REQUIRED"
  echo "=========================================================="
  echo ""
  
  # Run tailscale up in the background so it prints the auth URL immediately
  # and releases the SSH session. The blocking wait-for-browser is replaced
  # by the polling loop below.
  AUTH_OUTPUT=$(mktemp)
  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} up --accept-dns=false --accept-routes" >"${AUTH_OUTPUT}" 2>&1 &
  else
    "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" up \
      --accept-dns=false \
      --accept-routes >"${AUTH_OUTPUT}" 2>&1 &
  fi
  UP_PID=$!
  # Give tailscale up a few seconds to print the auth URL then kill it;
  # authentication state is tracked via `tailscale status` polling below.
  sleep 5
  kill "${UP_PID}" 2>/dev/null || true
  wait "${UP_PID}" 2>/dev/null || true
  
  # Check if authentication succeeded immediately (Success message in output)
  if grep -q "Success" "${AUTH_OUTPUT}" 2>/dev/null; then
    # Authentication was immediate - daemon already authenticated
    echo ""
    echo "✓ Tailscale authenticated successfully!"
    rm -f "${AUTH_OUTPUT}"
  else
    # Authentication requires browser - show URL and wait for confirmation
    AUTH_URL=$(grep -oP 'https://[^ ]+' "${AUTH_OUTPUT}" | head -1 || true)
    rm -f "${AUTH_OUTPUT}"
    
    if [ -n "${AUTH_URL}" ]; then
      echo ""
      echo "=========================================================="
      echo "AUTHENTICATION URL:"
      echo "${AUTH_URL}"
      echo "=========================================================="
      echo ""
      echo "1. Copy the URL above and open it in your browser"
      echo "2. Log in with your Tailscale account"
      echo "3. Approve the device"
      echo ""
      
      # Poll for authentication completion (up to 60 seconds)
      echo "Waiting for browser authentication..."
      POLL_COUNT=0
      MAX_POLLS=60
      
      while [ ${POLL_COUNT} -lt ${MAX_POLLS} ]; do
        sleep 1
        TS_STATUS=$(check_tailscale_auth)
        BACKEND_STATE=$(printf '%s' "${TS_STATUS}" | python3 -c \
          "import json,sys; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" 2>/dev/null || echo "Unknown")
        
        if [ "${BACKEND_STATE}" = "Running" ]; then
          echo "✓ Authentication confirmed from browser!"
          break
        fi
        
        POLL_COUNT=$((POLL_COUNT + 1))
        if [ $((POLL_COUNT % 10)) -eq 0 ]; then
          echo "  Still waiting... (${POLL_COUNT}s elapsed)"
        fi
      done
      
      if [ "${BACKEND_STATE}" != "Running" ]; then
        echo "⚠ Authentication not confirmed after ${MAX_POLLS}s"
        echo "  Check the log: tail -f ~/logs/tailscaled.log"
      fi
    else
      echo "⚠ Could not extract authentication URL from output"
      echo "  Try running manually:"
      echo "  ${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} up"
      fi
    fi
  fi

  # --------------------------------------------------------------------------
  # Set tailscale operator so Termux user can run tailscale CLI without root
  # after provisioning (e.g. manual status checks). Only run after auth succeeds.
  # --------------------------------------------------------------------------
  if [ "${HAS_ROOT}" = "1" ]; then
    CURRENT_USER="$(id -nu 2>/dev/null || true)"
    if [ -n "${CURRENT_USER}" ]; then
      su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} set --operator=${CURRENT_USER}" >/dev/null 2>&1 \
        && echo "Set tailscale operator to ${CURRENT_USER}" \
        || echo "(tailscale set --operator may not be supported or auth incomplete)"
    fi
  fi

  # --------------------------------------------------------------------------
  # Final status report
  # --------------------------------------------------------------------------
  echo ""
  echo "=========================================================="
  echo "Final Tailscale Status:"
  echo "=========================================================="

  if [ "${HAS_ROOT}" = "1" ]; then
    su -c "${TAILSCALE_BIN} --socket ${TAILSCALE_SOCKET} status" || true
  else
    "${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status || true
  fi

  FINAL_STATE=$("${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" status --json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('BackendState','Unknown'))" \
    2>/dev/null || echo "Unknown")

  TAILSCALE_IP=$("${TAILSCALE_BIN}" --socket "${TAILSCALE_SOCKET}" ip -4 2>/dev/null | head -1 || true)

  echo ""
  if [ "${FINAL_STATE}" = "Running" ] && [ -n "${TAILSCALE_IP}" ]; then
    echo "✓ Tailscale is connected!"
    echo "  Tailscale IPv4: ${TAILSCALE_IP}"
    echo ""
    echo "  Home Assistant Companion URL:"
    echo "  http://${TAILSCALE_IP}:8123"
  else
    echo "⚠ Tailscale state: ${FINAL_STATE}"
    if [ -z "${TAILSCALE_IP}" ]; then
      echo "  (IP address not yet assigned)"
    fi
    echo ""
    echo "  To check status: ${TAILSCALE_BIN} --socket \$PREFIX/var/run/tailscale/tailscaled.sock status"
    echo "  To view logs: tail -f ~/logs/tailscaled.log"
  fi

  echo ""
  echo "Tailscale will auto-start on next boot via ~/scripts/bootstrap_services.sh."
  echo "To check after reboot: ssh -p 8022 ... 'cat ~/logs/bootstrap.log | grep VPN'"
  echo ""
  echo "Setup script completed. Check output above for Tailscale status and IP."

REMOTE_SETUP
