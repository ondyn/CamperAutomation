#!/usr/bin/env bash
set -euo pipefail

# SSH hardening for Termux sshd: deploy SSH keys and install a managed sshd
# drop-in config that works for both LAN and Tailscale VPN clients.
#
# Tailscale runs in userspace-networking mode on the phone, so tailscaled
# proxies every inbound tailnet connection to 127.0.0.1:8022. sshd therefore
# sees ALL VPN peers as 127.0.0.1:
#   - source-IP filtering (Match Address / AllowUsers user@100.x) cannot work,
#     access control for VPN peers belongs in the Tailscale ACL;
#   - OpenSSH >= 9.8 PerSourcePenalties would penalise 127.0.0.1 for any one
#     peer's failed/aborted login and lock out every VPN client, so loopback
#     is exempted.
#
# Usage:
#   PHONE_HOST=<IP> PHONE_USER=<user> ./provisioning/ssh/30_harden_ssh_key_auth.sh [OPTIONS]
# Or (auto-detect via ADB):
#   ./provisioning/ssh/30_harden_ssh_key_auth.sh [OPTIONS]
#
# Options:
#   --key-name <name>     Laptop key in ~/.ssh to use/generate (default: camper_automation_rsa)
#   --pubkey <file>       Extra public key to authorize (repeatable, e.g. Pixel/Termux key)
#   --disable-password    Disable password auth (only applied if key login works)
#   --keep-password       Keep password auth enabled (default)
#   --no-restart          Do not restart sshd after writing config
#
# Environment:
#   SSH_PASSWORD          Password for initial login (uses sshpass) until the key is deployed

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

SSH_PORT="${SSH_PORT:-8022}"
SSH_KEY_NAME="${SSH_KEY_NAME:-camper_automation_rsa}"
SSH_PASSWORD="${SSH_PASSWORD:-${PROVISION_SSH_PASSWORD:-}}"
PASSWORD_AUTH="yes"
RESTART_SSHD=1
EXTRA_PUBKEYS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-name) SSH_KEY_NAME="$2"; shift 2 ;;
    --pubkey) EXTRA_PUBKEYS+=("$2"); shift 2 ;;
    --disable-password) PASSWORD_AUTH="no"; shift ;;
    --keep-password|--skip-password-disable) PASSWORD_AUTH="yes"; shift ;;
    --generate|--generate-key) shift ;;
    --no-restart) RESTART_SSHD=0; shift ;;
    --help|-h) sed -n '3,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "${PHONE_HOST:-}" ]; then
  echo "Auto-detecting PHONE_HOST..."
  command -v adb >/dev/null 2>&1 || { echo "ERROR: adb is not available for auto-detection." >&2; exit 1; }
  PHONE_HOST="$(auto_detect_phone_host_adb)"
  [ -n "${PHONE_HOST}" ] || { echo "ERROR: Could not auto-detect PHONE_HOST via ADB." >&2; exit 1; }
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

if [ -z "${PHONE_USER:-}" ]; then
  echo "Auto-detecting PHONE_USER..."
  PHONE_USER=""
  command -v adb >/dev/null 2>&1 && PHONE_USER="$(auto_detect_phone_user_adb || true)"
  [ -n "${PHONE_USER}" ] || { echo "ERROR: Could not auto-detect PHONE_USER from ADB package metadata." >&2; exit 1; }
  echo "Detected PHONE_USER=${PHONE_USER} (from ADB package UID)"
fi

SSH_KEY_DIR="${HOME}/.ssh"
SSH_KEY_PRIV="${SSH_KEY_DIR}/${SSH_KEY_NAME}"
SSH_KEY_PUB="${SSH_KEY_PRIV}.pub"

for pub in "${EXTRA_PUBKEYS[@]+"${EXTRA_PUBKEYS[@]}"}"; do
  [ -f "${pub}" ] || { echo "ERROR: public key not found: ${pub}" >&2; exit 1; }
done

COMMON_OPTS=(-F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
KEY_SSH=(ssh "${COMMON_OPTS[@]}" -i "${SSH_KEY_PRIV}" -o IdentitiesOnly=yes -o BatchMode=yes "${PHONE_USER}@${PHONE_HOST}")
if [ -n "${SSH_PASSWORD}" ]; then
  command -v sshpass >/dev/null 2>&1 || { echo "ERROR: sshpass is required when SSH_PASSWORD is set." >&2; exit 1; }
  PW_SSH=(sshpass -p "${SSH_PASSWORD}" ssh "${COMMON_OPTS[@]}" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive "${PHONE_USER}@${PHONE_HOST}")
else
  PW_SSH=(ssh "${COMMON_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}")
fi

echo "=== SSH hardening (LAN + Tailscale VPN) ==="
echo "Phone: ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}"
echo "Key:   ${SSH_KEY_PRIV}"
echo "Password auth: ${PASSWORD_AUTH}"
echo

if [ ! -f "${SSH_KEY_PRIV}" ]; then
  echo "Generating new SSH key: ${SSH_KEY_PRIV}"
  mkdir -p "${SSH_KEY_DIR}"
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PRIV}" -N "" -C "camper-automation@$(date +%Y%m%d)"
  chmod 600 "${SSH_KEY_PRIV}"
fi
[ -f "${SSH_KEY_PUB}" ] || ssh-keygen -y -f "${SSH_KEY_PRIV}" > "${SSH_KEY_PUB}"

# Pick a working transport: key first, then password.
if "${KEY_SSH[@]}" true >/dev/null 2>&1; then
  REMOTE=("${KEY_SSH[@]}")
  echo "✓ Connected with key"
else
  REMOTE=("${PW_SSH[@]}")
  echo "Key login not yet possible; using password login"
fi

echo "Deploying authorized keys (idempotent)..."
KEYS_B64="$(cat "${SSH_KEY_PUB}" "${EXTRA_PUBKEYS[@]+"${EXTRA_PUBKEYS[@]}"}" | base64 | tr -d '\n')"
"${REMOTE[@]}" "KEYS_B64='${KEYS_B64}' bash -s" <<'EOF'
set -e
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
added=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  if ! grep -qxF "$line" "$HOME/.ssh/authorized_keys"; then
    printf '%s\n' "$line" >> "$HOME/.ssh/authorized_keys"
    added=$((added + 1))
  fi
done < <(printf '%s' "$KEYS_B64" | base64 -d)
chmod 600 "$HOME/.ssh/authorized_keys"
# OpenSSH (StrictModes) rejects keys when $HOME is group/world writable.
chmod go-w "$HOME"
echo "authorized_keys: added ${added}, total $(grep -c . "$HOME/.ssh/authorized_keys")"
EOF

"${KEY_SSH[@]}" true >/dev/null 2>&1 && REMOTE=("${KEY_SSH[@]}") && echo "✓ Key-based login works"

if [ "${PASSWORD_AUTH}" = "no" ] && ! "${KEY_SSH[@]}" true >/dev/null 2>&1; then
  echo "ERROR: key login failed; refusing to disable password auth." >&2
  exit 1
fi

echo "Writing sshd drop-in config..."
"${REMOTE[@]}" "PASSWORD_AUTH='${PASSWORD_AUTH}' SSH_PORT='${SSH_PORT}' RESTART_SSHD='${RESTART_SSHD}' bash -s" <<'EOF'
set -e
SSH_DIR="$PREFIX/etc/ssh"
MAIN="$SSH_DIR/sshd_config"
DROPIN_DIR="$SSH_DIR/sshd_config.d"
DROPIN="$DROPIN_DIR/10-camper.conf"
mkdir -p "$DROPIN_DIR"

# Termux's sshd reads $PREFIX/etc/ssh/sshd_config (not ~/.termux/sshd_config).
# First value wins in sshd, so the Include must be at the top of the main file.
if ! grep -qE "^Include[[:space:]]+$DROPIN_DIR/\*\.conf" "$MAIN"; then
  cp "$MAIN" "$MAIN.bak.$(date +%Y%m%d%H%M%S)"
  { echo "Include $DROPIN_DIR/*.conf"; cat "$MAIN"; } > "$MAIN.tmp" && mv "$MAIN.tmp" "$MAIN"
  echo "Added Include to $MAIN"
fi

[ -f "$DROPIN" ] && cp "$DROPIN" "$DROPIN.bak"
cat > "$DROPIN" <<CONF
# Managed by provisioning/ssh/30_harden_ssh_key_auth.sh - do not edit on phone.
Port ${SSH_PORT}
ListenAddress 0.0.0.0
ListenAddress ::

PubkeyAuthentication yes
PasswordAuthentication ${PASSWORD_AUTH}
KbdInteractiveAuthentication no
PermitRootLogin no
MaxAuthTries 6
LoginGraceTime 60

# Tailscale userspace-networking delivers every VPN peer from 127.0.0.1.
# Exempt loopback so one peer's failed/aborted login cannot lock out all VPN
# clients. Access control for VPN peers is enforced by the Tailscale ACL.
PerSourcePenaltyExemptList 127.0.0.1/32,::1/128
MaxStartups 20:30:60

# Reap sessions whose VPN/hotspot path died instead of keeping them for hours.
ClientAliveInterval 30
ClientAliveCountMax 4
TCPKeepAlive yes

UseDNS no
AllowTcpForwarding yes
X11Forwarding no
PrintMotd no
CONF
chmod 600 "$DROPIN"

if ! sshd -t; then
  echo "ERROR: sshd config test failed; restoring previous drop-in." >&2
  if [ -f "$DROPIN.bak" ]; then mv "$DROPIN.bak" "$DROPIN"; else rm -f "$DROPIN"; fi
  exit 1
fi
rm -f "$DROPIN.bak"
echo "sshd config test passed"

if [ "$RESTART_SSHD" = "1" ]; then
  # Only the listener is restarted; active sshd-session processes (this one) survive.
  pids="$(pgrep -x sshd || true)"
  [ -n "$pids" ] && kill $pids
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x sshd >/dev/null || break; sleep 0.5; done
  sshd
  sleep 1
  pgrep -x sshd >/dev/null && echo "sshd restarted (pid $(pgrep -x sshd | head -1))" || { echo "ERROR: sshd failed to start" >&2; exit 1; }
fi

sshd -T 2>/dev/null | grep -E '^(listenaddress|passwordauthentication|pubkeyauthentication|persourcepenaltyexemptlist|clientaliveinterval) '
TS="$HOME/vpn/tailscale"; SOCK="$PREFIX/var/run/tailscale/tailscaled.sock"
[ -x "$TS" ] && echo "Tailscale IP: $("$TS" --socket "$SOCK" ip -4 2>/dev/null | head -1)"
EOF

echo
if [ "${RESTART_SSHD}" -eq 1 ]; then
  echo "Verifying fresh key login after restart..."
  sleep 1
  if "${KEY_SSH[@]}" 'echo ok' >/dev/null 2>&1; then
    echo "✓ Key login OK on ${PHONE_HOST}:${SSH_PORT}"
  else
    echo "WARNING: key login after restart failed. Recover via ADB:" >&2
    echo "  adb shell run-as com.termux sh -lc 'export PREFIX=/data/data/com.termux/files/usr; export PATH=\$PREFIX/bin:\$PATH; rm -f \$PREFIX/etc/ssh/sshd_config.d/10-camper.conf; pkill -x sshd; sshd'" >&2
  fi
fi

cat <<EOF

=== Done ===
Connect over LAN:      ssh -i ${SSH_KEY_PRIV} -p ${SSH_PORT} ${PHONE_USER}@${PHONE_HOST}
Connect over Tailscale: ssh -i ${SSH_KEY_PRIV} -p ${SSH_PORT} ${PHONE_USER}@<phone tailscale IP>

Note: VPN peers reach sshd as 127.0.0.1 (Tailscale userspace mode), so restrict
which tailnet devices may reach the phone in the Tailscale admin ACL, not in sshd.

~/.ssh/config example:
  Host camper-vpn
    HostName <phone tailscale IP>
    User ${PHONE_USER}
    Port ${SSH_PORT}
    IdentityFile ${SSH_KEY_PRIV}
    IdentitiesOnly yes
EOF
