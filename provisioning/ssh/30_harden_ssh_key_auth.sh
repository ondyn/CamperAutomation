#!/usr/bin/env bash
set -euo pipefail

# SSH hardening: configure key-based auth only and disable password auth.
# Run after provisioning/ssh/10_install_homeassistant_core.sh completes.
#
# Usage:
#   PHONE_HOST=<IP> PHONE_USER=<user> ./provisioning/ssh/30_harden_ssh_key_auth.sh [OPTIONS]
# Or (auto-detect):
#   ./provisioning/ssh/30_harden_ssh_key_auth.sh [OPTIONS]
#
# Options:
#   --key-name <name>   Use existing SSH key (default: camper_automation_rsa)
#   --generate          Generate new key if it doesn't exist (default: yes)
#   --skip-password-disable  Do not disable password auth (default: disabled)

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

# Auto-detect PHONE_HOST if not set
if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST..."
  if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb is not available for auto-detection." >&2
    exit 1
  fi
  PHONE_HOST="$(auto_detect_phone_host_adb)"
  if [ -z "${PHONE_HOST}" ]; then
    echo "ERROR: Could not auto-detect PHONE_HOST via ADB." >&2
    exit 1
  fi
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

# Auto-detect PHONE_USER if not set
if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER=""
  if command -v adb >/dev/null 2>&1; then
    PHONE_USER="$(auto_detect_phone_user_adb || true)"
  fi
  if [ -n "${PHONE_USER}" ]; then
    echo "Detected PHONE_USER=${PHONE_USER} (from ADB package UID)"
  else
    echo "ERROR: Could not auto-detect PHONE_USER from ADB package metadata." >&2
    exit 1
  fi
fi

: "${PHONE_HOST:?Set PHONE_HOST}"
: "${PHONE_USER:?Set PHONE_USER}"

SSH_PORT="${SSH_PORT:-8022}"
SSH_KEY_NAME="${SSH_KEY_NAME:-camper_automation_rsa}"
SSH_IDENTITY="${SSH_IDENTITY:-${HOME}/.ssh/camper_automation_rsa}"
SKIP_PASSWORD_DISABLE=0
GENERATE_KEY=1

for arg in "$@"; do
  case "$arg" in
    --key-name) shift; SSH_KEY_NAME="$1" ;;
    --generate-key) GENERATE_KEY=1 ;;
    --skip-password-disable) SKIP_PASSWORD_DISABLE=1 ;;
    --help) echo "Usage: PHONE_HOST=<ip> PHONE_USER=<user> $0 [--key-name name] [--skip-password-disable]"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

SSH_KEY_DIR="${HOME}/.ssh"
SSH_KEY_PRIV="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
SSH_KEY_PUB="${SSH_KEY_PRIV}.pub"

SSH_ID_ARGS=()
[ -f "${SSH_IDENTITY}" ] && SSH_ID_ARGS=(-i "${SSH_IDENTITY}")
SSH_BASE=(ssh -F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new "${SSH_ID_ARGS[@]}" "${PHONE_USER}@${PHONE_HOST}")
SCP_CMD=(scp -F /dev/null -P "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no "${SSH_ID_ARGS[@]}")

echo "=== SSH Key-Based Authentication Hardening ==="
echo "Phone host: ${PHONE_HOST}"
echo "Phone user: ${PHONE_USER}"
echo "SSH port: ${SSH_PORT}"
echo "SSH key name: ${SSH_KEY_NAME}"
echo

# Generate SSH key if needed
if [ ! -f "${SSH_KEY_PRIV}" ] && [ "${GENERATE_KEY}" -eq 1 ]; then
  echo "Generating new SSH key: ${SSH_KEY_PRIV}"
  mkdir -p "${SSH_KEY_DIR}"
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PRIV}" -N "" -C "camper-automation@$(date +%Y%m%d)"
  chmod 600 "${SSH_KEY_PRIV}"
  chmod 644 "${SSH_KEY_PUB}"
  echo "✓ SSH key generated"
  echo
elif [ ! -f "${SSH_KEY_PRIV}" ]; then
  echo "ERROR: SSH key not found at ${SSH_KEY_PRIV}" >&2
  exit 1
else
  echo "✓ Using existing SSH key: ${SSH_KEY_PRIV}"
  echo
fi

# Deploy public key to phone
echo "Deploying public key to phone..."
"${SSH_BASE[@]}" 'mkdir -p ~/.ssh' || {
  echo "ERROR: Failed to create ~/.ssh on phone" >&2
  exit 1
}

# Copy public key
cat "${SSH_KEY_PUB}" | "${SSH_BASE[@]}" 'cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' || {
  echo "ERROR: Failed to deploy public key" >&2
  exit 1
}
echo "✓ Public key deployed to ~/.ssh/authorized_keys"
echo

# Test key-based login
echo "Testing key-based login..."
if "${SSH_BASE[@]}" -i "${SSH_KEY_PRIV}" 'echo OK' >/dev/null 2>&1; then
  echo "✓ Key-based login works"
else
  echo "WARNING: Key-based login test failed. Check auth setup." >&2
fi
echo

# Optionally disable password auth
if [ "${SKIP_PASSWORD_DISABLE}" -eq 0 ]; then
  echo "Hardening SSH server: disabling password authentication..."
  
  "${SSH_BASE[@]}" 'bash -s' <<'EOF'
set -e
SSHD_CONFIG="$HOME/.termux/sshd_config"

if [ ! -f "$SSHD_CONFIG" ]; then
  mkdir -p "$HOME/.termux"
  printf '%s\n' \
    '# Custom SSH daemon config for Termux' \
    'Port 8022' \
    'PasswordAuthentication no' \
    'PubkeyAuthentication yes' \
    'X11Forwarding no' \
    'PrintMotd no' \
    'Subsystem sftp /usr/libexec/sftp-server' \
    > "$SSHD_CONFIG"
  chmod 600 "$SSHD_CONFIG"
  echo "SSH hardening config written to $SSHD_CONFIG"
else
  if ! grep -q "PasswordAuthentication no" "$SSHD_CONFIG"; then
    echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    echo "Added PasswordAuthentication no to $SSHD_CONFIG"
  else
    echo "PasswordAuthentication already set in $SSHD_CONFIG"
  fi
fi
EOF
  
  echo "✓ SSH server hardened: password auth disabled"
  echo "  (Note: sshd restart required on phone for changes to take effect)"
else
  echo "Skipping password auth disabling (--skip-password-disable specified)"
fi
echo

# Summary
cat <<EOF
=== SSH Hardening Summary ===

✓ SSH key pair: ${SSH_KEY_PRIV}
✓ Public key deployed to phone
✓ Key-based authentication ready

Next steps:
1. On phone, restart SSH if needed:
   - Kill current sshd: pkill sshd
   - Start new sshd: sshd
2. Test login from laptop:
   ssh -i ${SSH_KEY_PRIV} -p ${SSH_PORT} ${PHONE_USER}@${PHONE_HOST}
3. Remove password from phone when confident:
   passwd -d (or unset password in Termux settings)

Security notes:
- Keep ${SSH_KEY_PRIV} safe (it's your remote access key)
- Backup the key to a secure location
- Use SSH config to simplify future logins:
  
  Host camper
    HostName ${PHONE_HOST}
    User ${PHONE_USER}
    Port ${SSH_PORT}
    IdentityFile ${SSH_KEY_PRIV}
    StrictHostKeyChecking accept-new
EOF
