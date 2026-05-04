#!/usr/bin/env bash
set -euo pipefail

# Run from your laptop after Termux SSH is reachable.
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/10_install_homeassistant_core.sh
# Or (auto-detect):
#   ./provisioning/ssh/10_install_homeassistant_core.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH_PORT="${SSH_PORT:-8022}"
LOCK_FILE="${HA_LOCK_FILE:-${ROOT_DIR}/provisioning/locks/homeassistant-2026.2.3.lock.env}"

if [ ! -f "${LOCK_FILE}" ]; then
  echo "ERROR: lock file not found at ${LOCK_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${LOCK_FILE}"

HA_VERSION="${HA_VERSION:-${LOCK_HA_VERSION}}"
HA_SOURCE_URL="${HA_SOURCE_URL:-${LOCK_HA_SOURCE_URL}}"
HA_SOURCE_SHA256="${HA_SOURCE_SHA256:-${LOCK_HA_SOURCE_SHA256}}"
HA_SOURCE_DIR="${HA_SOURCE_DIR:-${LOCK_HA_SOURCE_DIR}}"
HA_REQUIRES_PYTHON="${HA_REQUIRES_PYTHON:-${LOCK_HA_REQUIRES_PYTHON}}"
HA_INSTALL_TOOL="${HA_INSTALL_TOOL:-${LOCK_HA_INSTALL_TOOL}}"
HA_USE_FREEZE_LOCK="${HA_USE_FREEZE_LOCK:-0}"
LOCK_BASENAME="$(basename "${LOCK_FILE}")"
PYTHON_FREEZE_FILE="${ROOT_DIR}/provisioning/locks/homeassistant-${HA_VERSION}.python-freeze.txt"

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

ensure_sshd_reachable() {
  # Fast path: port already open.
  if nc -z "${PHONE_HOST}" "${SSH_PORT}" >/dev/null 2>&1; then
    return 0
  fi

  # Try ADB-assisted start of sshd in Termux context.
  if command -v adb >/dev/null 2>&1; then
    if ! adb shell "run-as com.termux test -x /data/data/com.termux/files/usr/bin/sshd" >/dev/null 2>&1; then
      echo "ERROR: Termux openssh is not installed (sshd binary missing)." >&2
      echo "Run in Termux first:" >&2
      echo "  bash ~/bootstrap_termux.sh" >&2
      echo "Then rerun this installer." >&2
      return 1
    fi

    adb shell "run-as com.termux sh -lc 'export PREFIX=/data/data/com.termux/files/usr; export PATH=\$PREFIX/bin:\$PATH; sshd'" >/dev/null 2>&1 || true
    sleep 1

    if nc -z "${PHONE_HOST}" "${SSH_PORT}" >/dev/null 2>&1; then
      echo "Started sshd via ADB and confirmed ${PHONE_HOST}:${SSH_PORT} is reachable."
      return 0
    fi
  fi

  echo "ERROR: SSH is not reachable at ${PHONE_HOST}:${SSH_PORT}." >&2
  echo "On phone, open Termux and run:" >&2
  echo "  bash ~/bootstrap_termux.sh" >&2
  echo "  sshd" >&2
  echo "Then retry this script." >&2
  return 1
}

# Auto-detect PHONE_HOST if not set
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
    echo "Checks to run:" >&2
    echo "  adb devices" >&2
    echo "  adb shell ip -4 addr show wlan0" >&2
    echo "Then run with manual host:" >&2
    echo "  PHONE_HOST=<PHONE_IP> ./provisioning/ssh/10_install_homeassistant_core.sh" >&2
    exit 1
  fi
  echo "Detected PHONE_HOST=${PHONE_HOST}"
fi

# Auto-detect PHONE_USER if not set (try common Termux user patterns)
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
    echo "Ensure Termux app is installed, then retry or set manually:" >&2
    echo "  PHONE_USER=u0_aNNN ./provisioning/ssh/10_install_homeassistant_core.sh" >&2
    exit 1
  fi
fi

: "${PHONE_HOST?Set PHONE_HOST to phone IP/hostname}"
: "${PHONE_USER?Set PHONE_USER to Termux username, e.g. u0_a123}"

ensure_sshd_reachable

SSH_OPTS=(
  -p "${SSH_PORT}"
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="/tmp/cm-%C"
)
SCP_OPTS=(
  -P "${SSH_PORT}"
  -o StrictHostKeyChecking=accept-new
  -o ControlMaster=auto
  -o ControlPersist=10m
  -o ControlPath="/tmp/cm-%C"
)

cleanup_ssh_mux() {
  ssh "${SSH_OPTS[@]}" -O exit "${PHONE_USER}@${PHONE_HOST}" >/dev/null 2>&1 || true
}
trap cleanup_ssh_mux EXIT

echo "Establishing SSH session (password should be requested once)..."
ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'true'

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'mkdir -p ~/scripts ~/logs ~/.termux/boot ~/.provisioning/locks'
scp "${SCP_OPTS[@]}" "${ROOT_DIR}/boot/00-bootstrap" "${PHONE_USER}@${PHONE_HOST}:~/.termux/boot/00-bootstrap"
scp "${SCP_OPTS[@]}" "${ROOT_DIR}/scripts/bootstrap_services.sh" "${PHONE_USER}@${PHONE_HOST}:~/scripts/bootstrap_services.sh"
scp "${SCP_OPTS[@]}" "${ROOT_DIR}/scripts/hass.sh" "${PHONE_USER}@${PHONE_HOST}:~/scripts/hass.sh"
scp "${SCP_OPTS[@]}" "${LOCK_FILE}" "${PHONE_USER}@${PHONE_HOST}:~/.provisioning/locks/${LOCK_BASENAME}"

if [ -f "${PYTHON_FREEZE_FILE}" ]; then
  scp "${SCP_OPTS[@]}" "${PYTHON_FREEZE_FILE}" "${PHONE_USER}@${PHONE_HOST}:~/.provisioning/locks/$(basename "${PYTHON_FREEZE_FILE}")"
fi

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'chmod 700 ~/.termux/boot/00-bootstrap ~/scripts/bootstrap_services.sh ~/scripts/hass.sh'

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" "LOCK_BASENAME='${LOCK_BASENAME}' HA_INSTALL_TOOL_OVERRIDE='${HA_INSTALL_TOOL}' HA_USE_FREEZE_LOCK='${HA_USE_FREEZE_LOCK}' bash -s" <<'REMOTE_INSTALL'
set -euo pipefail
cd ~

LOCK_PATH="$HOME/.provisioning/locks/${LOCK_BASENAME:?}"
if [ ! -f "$LOCK_PATH" ]; then
  echo "ERROR: remote lock file missing at $LOCK_PATH" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$LOCK_PATH"

HA_VERSION="${LOCK_HA_VERSION}"
HA_SOURCE_URL="${LOCK_HA_SOURCE_URL}"
HA_SOURCE_SHA256="${LOCK_HA_SOURCE_SHA256}"
HA_SOURCE_DIR="${LOCK_HA_SOURCE_DIR}"
HA_REQUIRES_PYTHON="${LOCK_HA_REQUIRES_PYTHON}"
HA_INSTALL_TOOL="${HA_INSTALL_TOOL_OVERRIDE:-${LOCK_HA_INSTALL_TOOL}}"
HA_RUNTIME_PIP_PACKAGES=("${LOCK_HA_RUNTIME_PIP_PACKAGES[@]:-}")
PYTHON_FREEZE_PATH="$HOME/.provisioning/locks/homeassistant-${HA_VERSION}.python-freeze.txt"
USE_FREEZE_LOCK="${HA_USE_FREEZE_LOCK:-0}"
ARCHIVE_DIR="$HOME/.cache/provisioning"
ARCHIVE_PATH="$ARCHIVE_DIR/homeassistant-${HA_VERSION}.tar.gz"
SOURCE_ROOT="$HOME/src"
SOURCE_PATH="$SOURCE_ROOT/$HA_SOURCE_DIR"

# cryptography (via maturin) needs Android API level when building from source on Termux.
if [ -n "${ANDROID_API_LEVEL:-}" ]; then
  ANDROID_API_LEVEL="${ANDROID_API_LEVEL}"
else
  ANDROID_API_LEVEL="$(getprop ro.build.version.sdk 2>/dev/null || true)"
fi
if [ -z "$ANDROID_API_LEVEL" ]; then
  ANDROID_API_LEVEL="$(uname -r | sed -n 's/.*android\([0-9][0-9]*\).*/\1/p' | head -n1)"
fi
if [ -z "$ANDROID_API_LEVEL" ]; then
  echo "ERROR: Could not determine Android API level for Python package builds." >&2
  echo "Set ANDROID_API_LEVEL manually and rerun this script." >&2
  exit 1
fi
export ANDROID_API_LEVEL
export TMPDIR="${PREFIX}/tmp"
mkdir -p "$TMPDIR"
export SODIUM_INSTALL=system
export CFLAGS="-I${PREFIX}/include"
export LDFLAGS="-L${PREFIX}/lib"

# Install pinned native Termux packages first, but degrade to the current
# mirror version when an exact historical pin has been rotated out.
RESOLVED_TERMUX_PACKAGES=()
for pkg_spec in "${LOCK_TERMUX_PACKAGES[@]}"; do
  if [[ "$pkg_spec" == *=* ]]; then
    pkg_name="${pkg_spec%%=*}"
    pkg_version="${pkg_spec#*=}"
    current_version="$(pkg show "$pkg_name" 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"

    if [ -z "$current_version" ]; then
      echo "ERROR: Required Termux package '$pkg_name' is not available from the current mirror." >&2
      exit 1
    fi

    if [ "$current_version" = "$pkg_version" ]; then
      RESOLVED_TERMUX_PACKAGES+=("$pkg_spec")
    else
      echo "WARNING: Termux mirror no longer provides $pkg_spec; using $pkg_name=$current_version instead." >&2
      RESOLVED_TERMUX_PACKAGES+=("$pkg_name")
    fi
  else
    RESOLVED_TERMUX_PACKAGES+=("$pkg_spec")
  fi
done

pkg install -y "${RESOLVED_TERMUX_PACKAGES[@]}"

CURRENT_PYTHON="$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
MIN_PYTHON="${HA_REQUIRES_PYTHON#>=}"
if [ -n "$MIN_PYTHON" ] && [ "$(printf '%s\n%s\n' "$MIN_PYTHON" "$CURRENT_PYTHON" | sort -V | head -n1)" != "$MIN_PYTHON" ]; then
  echo "ERROR: Home Assistant ${HA_VERSION} requires Python ${HA_REQUIRES_PYTHON}, but Termux currently provides Python ${CURRENT_PYTHON}." >&2
  echo "Install is blocked until Termux ships a compatible Python or the installer uses an alternate Python runtime." >&2
  exit 1
fi

# Create venv with system site-packages so the Termux-patched psutil is visible.
VENV="$HOME/.venv"
if [ -d "$VENV" ]; then
  rm -rf "$VENV"
fi
python3 -m venv --system-site-packages "$VENV"

if command -v uv >/dev/null 2>&1 && [ "${HA_INSTALL_TOOL:-uv}" != "pip" ]; then
  INSTALL_TOOL="uv"
else
  INSTALL_TOOL="pip"
fi

source "$VENV/bin/activate"

mkdir -p "$ARCHIVE_DIR" "$SOURCE_ROOT"
rm -rf "$SOURCE_PATH"
curl -Lf --retry 3 --retry-delay 2 -o "$ARCHIVE_PATH" "$HA_SOURCE_URL"
printf '%s  %s\n' "$HA_SOURCE_SHA256" "$ARCHIVE_PATH" | sha256sum -c -
tar -xzf "$ARCHIVE_PATH" -C "$SOURCE_ROOT"

# Pre-populate the venv with Termux's pre-built psutil so neither pip nor uv
# attempt a source build (Android is not supported in psutil 7.x upstream build).
SYS_SP="/data/data/com.termux/files/usr/lib/python3.13/site-packages"
VENV_SP="$VENV/lib/python3.13/site-packages"
for _path in "$SYS_SP"/psutil "$SYS_SP"/psutil-*.dist-info "$SYS_SP"/_psutil_linux*.so "$SYS_SP"/_psutil_posix*.so; do
  if [ -e "$_path" ]; then
    cp -r "$_path" "$VENV_SP/"
  fi
done
# grpcio is heavy to compile on Android; use the Termux-packaged build.
for _path in "$SYS_SP"/grpc "$SYS_SP"/grpcio-*.dist-info "$SYS_SP"/_grpc*.so; do
  if [ -e "$_path" ]; then
    cp -r "$_path" "$VENV_SP/"
  fi
done
unset _path SYS_SP VENV_SP

cd "$SOURCE_PATH"

# Build Termux-specific requirements/constraints:
# - keep upstream pins where possible for reproducibility
# - skip Python uv package (native Termux uv binary is used instead)
# - drop grpcio hard pins that force source builds on Android
REQ_FILE="requirements.termux.txt"
CONSTRAINT_FILE="homeassistant/package_constraints.termux.txt"
sed '/^grpcio==/d;/^grpcio-status==/d;/^grpcio-reflection==/d;/^uv==/d' \
  homeassistant/package_constraints.txt > "$CONSTRAINT_FILE"
sed "s#^-c homeassistant/package_constraints.txt#-c $CONSTRAINT_FILE#" requirements.txt | \
  sed '/^uv==/d' > "$REQ_FILE"

echo "Installing Home Assistant using: $INSTALL_TOOL"
if [ "$USE_FREEZE_LOCK" = "1" ] && [ -f "$PYTHON_FREEZE_PATH" ]; then
  echo "Using resolved Python lock: $PYTHON_FREEZE_PATH"
  if [ "$INSTALL_TOOL" = "uv" ]; then
    if uv pip install --python "$VENV/bin/python" -r "$PYTHON_FREEZE_PATH" && uv pip install --python "$VENV/bin/python" --no-deps .; then
      true
    else
      echo "WARNING: uv install failed on this Android environment; falling back to pip." >&2
      "$VENV/bin/python" -m pip install --upgrade pip wheel setuptools
      "$VENV/bin/python" -m pip install -r "$PYTHON_FREEZE_PATH"
      "$VENV/bin/python" -m pip install --no-deps .
    fi
  else
    "$VENV/bin/python" -m pip install --upgrade pip wheel setuptools
    "$VENV/bin/python" -m pip install -r "$PYTHON_FREEZE_PATH"
    "$VENV/bin/python" -m pip install --no-deps .
  fi
else
  echo "Using official Home Assistant release requirements"
  if [ "$INSTALL_TOOL" = "uv" ]; then
    if uv pip install --python "$VENV/bin/python" -r "$REQ_FILE" && uv pip install --python "$VENV/bin/python" --no-deps .; then
      true
    else
      echo "WARNING: uv install failed on this Android environment; falling back to pip." >&2
      "$VENV/bin/python" -m pip install --upgrade pip wheel setuptools
      "$VENV/bin/python" -m pip install -r "$REQ_FILE"
      "$VENV/bin/python" -m pip install --no-deps .
    fi
  else
    "$VENV/bin/python" -m pip install --upgrade pip wheel setuptools
    "$VENV/bin/python" -m pip install -r "$REQ_FILE"
    "$VENV/bin/python" -m pip install --no-deps .
  fi
fi

if [ ! -x "$VENV/bin/hass" ]; then
  echo "ERROR: install completed but venv hass binary is missing at $VENV/bin/hass" >&2
  exit 1
fi

if [ "${#HA_RUNTIME_PIP_PACKAGES[@]}" -gt 0 ]; then
  echo "Installing Termux runtime extras: ${HA_RUNTIME_PIP_PACKAGES[*]}"
  # Use uv for runtime extras to pick up the Termux build environment (CC, CFLAGS,
  # LDFLAGS) set earlier in this script; pip may fail on native packages like netifaces.
  if [ "$INSTALL_TOOL" = "uv" ]; then
    uv pip install --python "$VENV/bin/python" "${HA_RUNTIME_PIP_PACKAGES[@]}"
  else
    "$VENV/bin/python" -m pip install "${HA_RUNTIME_PIP_PACKAGES[@]}"
  fi
fi

# Patch pyserial list_ports_posix to recognise Android (sys.platform=='android').
# Python 3.13 on Android returns sys.platform='android', not 'linux'.  pyserial
# falls through to an ImportError because it only checks [:5]=='linux'.  Android
# uses the Linux kernel so list_ports_linux works correctly there.
PYSERIAL_PORTS_POSIX="$VENV/lib/python3.13/site-packages/serial/tools/list_ports_posix.py"
if [ -f "$PYSERIAL_PORTS_POSIX" ]; then
  if grep -q 'plat\[:5\].*linux' "$PYSERIAL_PORTS_POSIX" && \
     ! grep -q "android" "$PYSERIAL_PORTS_POSIX"; then
    sed -i "s/if plat\[:5\] == 'linux':/if plat[:5] == 'linux' or plat == 'android':  # Android uses Linux kernel/" \
      "$PYSERIAL_PORTS_POSIX"
    echo "Patched pyserial list_ports_posix.py for Android platform"
  fi
fi

# HA's pip package does not include translations/*.json files for components —
# they're only present as strings.json.  The translation loader uses has_translations
# (checks for a "translations/" directory) to decide whether to load them.
# Without translations/en.json, onboarding crashes with KeyError on area names,
# and other backend translations (states, services) are silently empty.
# Fix: copy strings.json -> translations/en.json for every component that needs one.
echo "Generating translations/en.json from strings.json for all components..."
"$VENV/bin/python" - "$VENV" <<'PYEOF'
import json, pathlib, sys

base = pathlib.Path(sys.argv[1]) / "lib/python3.13/site-packages/homeassistant/components"
count = 0
for comp_dir in base.iterdir():
    strings_file = comp_dir / "strings.json"
    translations_dir = comp_dir / "translations"
    en_file = translations_dir / "en.json"
    if strings_file.exists() and not en_file.exists():
        translations_dir.mkdir(exist_ok=True)
        data = json.loads(strings_file.read_text())
        en_file.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        count += 1
print(f"Created {count} translations/en.json files")
PYEOF

"$VENV/bin/python" -m pip freeze --all | LC_ALL=C sort > "$PYTHON_FREEZE_PATH"
REMOTE_INSTALL

scp "${SCP_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}:~/.provisioning/locks/homeassistant-${HA_VERSION}.python-freeze.txt" "${PYTHON_FREEZE_FILE}"

ssh "${SSH_OPTS[@]}" "${PHONE_USER}@${PHONE_HOST}" 'bash -lc "source ~/.venv/bin/activate && nohup sshd >/dev/null 2>&1 || true"'

cat <<EOF
Remote install finished.

Validate on phone (over SSH):
  screen -dmS hass sh ~/scripts/hass.sh
  screen -ls
  tail -n 80 ~/.suroot/.homeassistant/home-assistant.log
EOF
