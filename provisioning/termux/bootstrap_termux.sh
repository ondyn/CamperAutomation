#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Run inside Termux app on the phone (first interactive bootstrap).
# This keeps interactive steps minimal: storage permission + ssh password.

BOOTSTRAP_VERSION="2026-05-06.1"
echo "[bootstrap_termux] version=${BOOTSTRAP_VERSION}"

HOME="/data/data/com.termux/files/home"
PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH:-/system/bin}"
export HOME PREFIX PATH

ensure_password_auth_enabled() {
  local cfg="$HOME/.termux/sshd_config"

  if [ -f "$cfg" ]; then
    # Keep password auth enabled for provisioning phase; key-only hardening is a separate step.
    if grep -q '^PasswordAuthentication[[:space:]]\+no' "$cfg"; then
      sed -i 's/^PasswordAuthentication[[:space:]]\+no/PasswordAuthentication yes/' "$cfg"
    elif ! grep -q '^PasswordAuthentication[[:space:]]\+yes' "$cfg"; then
      printf '\nPasswordAuthentication yes\n' >> "$cfg"
    fi
  fi
}

APT_DIR="${PREFIX}/etc/apt"
TERMUX_MAIN_REPO="${TERMUX_MAIN_REPO:-https://packages.termux.dev/apt/termux-main}"
TERMUX_ROOT_REPO="${TERMUX_ROOT_REPO:-https://packages.termux.dev/apt/termux-root}"
TERMUX_X11_REPO="${TERMUX_X11_REPO:-https://packages.termux.dev/apt/termux-x11}"

write_repo_file() {
  local file_path="$1"
  local repo_url="$2"
  local suite="$3"
  local component="$4"

  mkdir -p "$(dirname "${file_path}")"
  cat >"${file_path}" <<EOF
deb ${repo_url} ${suite} ${component}
EOF
}

configure_termux_repos() {
  mkdir -p "${APT_DIR}/sources.list.d"

  write_repo_file "${APT_DIR}/sources.list" "${TERMUX_MAIN_REPO}" stable main
  write_repo_file "${APT_DIR}/sources.list.d/root.list" "${TERMUX_ROOT_REPO}" root stable
  write_repo_file "${APT_DIR}/sources.list.d/x11.list" "${TERMUX_X11_REPO}" x11 main

  echo "Configured Termux APT repositories:"
  echo "  main -> ${TERMUX_MAIN_REPO}"
  echo "  root -> ${TERMUX_ROOT_REPO}"
  echo "  x11  -> ${TERMUX_X11_REPO}"
}

termux-wake-lock

# OpenSSH rejects authorized_keys when the home directory is group/world writable.
chmod 700 "${HOME}"
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
if [ -f "${HOME}/.ssh/authorized_keys" ]; then
  chmod 600 "${HOME}/.ssh/authorized_keys"
fi

echo
echo "Granting Termux shared storage access..."
printf 'y\n' | termux-setup-storage || true

if [ -d "$HOME/storage/downloads" ]; then
  echo "Shared storage is available at: $HOME/storage/downloads"
else
  echo "WARNING: Termux storage shortcut was not created yet."
  echo "         If Android showed a storage permission prompt, allow it and rerun: termux-setup-storage"
  echo "         Shared-storage provisioning fallbacks depend on this path."
fi

configure_termux_repos

export DEBIAN_FRONTEND=noninteractive
APT_NONINTERACTIVE_OPTS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

pkg update -y
pkg upgrade -y "${APT_NONINTERACTIVE_OPTS[@]}"

# Termux package naming changed over time; pick available binutils variant.
BINUTILS_PKG=""
if pkg show binutils >/dev/null 2>&1; then
  BINUTILS_PKG="binutils"
elif pkg show binutils-is-llvm >/dev/null 2>&1; then
  BINUTILS_PKG="binutils-is-llvm"
else
  echo "WARNING: No known binutils package variant found; continuing without explicit binutils package."
fi

BASE_PACKAGES=(
  openssh git python rust uv tsu ffmpeg termux-api root-repo x11-repo
  libxml2 libxslt pkg-config libffi libjpeg-turbo libpng
  patchelf ninja screen cmake
)

# Note: python-psutil was removed from Termux repos; will be installed via pip in HA setup

if [ -n "${BINUTILS_PKG}" ]; then
  BASE_PACKAGES+=("${BINUTILS_PKG}")
fi

pkg install -y "${APT_NONINTERACTIVE_OPTS[@]}" "${BASE_PACKAGES[@]}"

if ! command -v sshd >/dev/null 2>&1; then
  echo "ERROR: sshd missing after package install." >&2
  exit 1
fi

echo
SSH_PASSWORD="${TERMUX_SSH_PASSWORD:-}"
if [ -z "$SSH_PASSWORD" ]; then
  echo "ERROR: TERMUX_SSH_PASSWORD is not set. Pass SSH_PWD from .env via the provisioning orchestrator." >&2
  exit 1
fi

if printf '%s\n%s\n' "$SSH_PASSWORD" "$SSH_PASSWORD" | passwd >/dev/null 2>&1; then
  mkdir -p "$HOME/logs"
  CRED_FILE="$HOME/logs/bootstrap-credentials.txt"
  {
    echo "timestamp=$(date -Iseconds)"
    echo "user=$(id -un)"
    echo "ssh_password=$SSH_PASSWORD"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  echo "SSH password set for user $(id -un): $SSH_PASSWORD"
  echo "Saved credentials: $CRED_FILE"
else
  echo "ERROR: Failed to set SSH password non-interactively." >&2
  exit 1
fi

echo
echo "Starting sshd..."

ensure_password_auth_enabled

SSHD_LOG="${HOME}/logs/sshd-start.log"
SSHD_BIN="${PREFIX}/bin/sshd"
SSHD_PID_FILE="${HOME}/.ssh/sshd.pid"
mkdir -p "${HOME}/logs"
mkdir -p "${HOME}/.ssh"

# Verify sshd config before attempting to start.
if [ ! -x "${SSHD_BIN}" ]; then
  echo "ERROR: sshd binary missing at ${SSHD_BIN}" >&2
  exit 1
fi

if ! "${SSHD_BIN}" -t 2>>"${SSHD_LOG}"; then
  echo "ERROR: sshd config test failed." >&2
  cat "${SSHD_LOG}" >&2
  exit 1
fi

# Stop a previous instance managed by this bootstrap when possible.
if [ -f "${SSHD_PID_FILE}" ]; then
  _old_pid="$(cat "${SSHD_PID_FILE}" 2>/dev/null || true)"
  if [ -n "${_old_pid}" ]; then
    kill "${_old_pid}" 2>/dev/null || true
    sleep 2
  fi
fi
rm -f "${SSHD_PID_FILE}"

# Start sshd in the foreground under nohup/background. In this adb/run-as
# bootstrap path, the default daemonizing mode can accept a TCP connection and
# then immediately drop it before key exchange. Running with -D avoids that.
nohup "${SSHD_BIN}" -D -e -o PidFile="${SSHD_PID_FILE}" >>"${SSHD_LOG}" 2>&1 &

# Poll up to 10 seconds for local TCP listener readiness.
_sshd_ready=1
for _i in 1 2 3 4 5 6 7 8 9 10; do
  if python - <<'PY'
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(1.0)
try:
    sock.connect(("127.0.0.1", 8022))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
raise SystemExit(0)
PY
  then
    break
  else
    _sshd_ready=0
    sleep 1
  fi
done

if [ "${_sshd_ready}" -eq 1 ]; then
  echo "sshd is running on port 8022"
else
  echo "ERROR: sshd did not start correctly." >&2
  if [ -s "${SSHD_LOG}" ]; then
    echo "--- sshd log ---" >&2
    cat "${SSHD_LOG}" >&2
  fi
  echo "Try manually: sshd -d 2>&1 | head -20" >&2
  exit 1
fi

echo
echo "Termux base bootstrap complete."
echo "Next: from your laptop, continue with provisioning/ssh/10_install_homeassistant_core.sh"
