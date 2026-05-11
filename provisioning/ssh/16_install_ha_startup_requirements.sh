#!/usr/bin/env bash
set -euo pipefail

# Install missing Python modules reported by recent Home Assistant startup logs.
# Usage:
#   PHONE_HOST=192.168.43.1 PHONE_USER=u0_a123 ./provisioning/ssh/16_install_ha_startup_requirements.sh
# Or (auto-detect):
#   ./provisioning/ssh/16_install_ha_startup_requirements.sh
# Password-based (host key verification disabled automatically):
#   SSH_PASSWORD=secret ./provisioning/ssh/16_install_ha_startup_requirements.sh
# Force host key checking regardless of auth method:
#   SSH_STRICT_HOST_CHECKING=accept-new SSH_PASSWORD=secret ./provisioning/ssh/16_install_ha_startup_requirements.sh

auto_detect_phone_host_adb() {
  local host=""
  host="$(adb shell getprop dhcp.wlan0.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell getprop dhcp.ap.ipaddress 2>/dev/null | tr -d '\r' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1 || true)"
  [ -n "${host}" ] || host="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 | tr -d '\r' || true)"
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
# Set SSH_STRICT_HOST_CHECKING=no to skip host key verification (useful for password-based
# provisioning flows where the host key is not yet stored in known_hosts).
SSH_STRICT_HOST_CHECKING="${SSH_STRICT_HOST_CHECKING:-accept-new}"

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
  # When using a password without an identity file, default to skipping host key
  # verification unless the caller has explicitly set SSH_STRICT_HOST_CHECKING.
  if [ "${SSH_STRICT_HOST_CHECKING}" = "accept-new" ]; then
    SSH_STRICT_HOST_CHECKING="no"
  fi
fi

SSH_BASE=("${SSH_TRANSPORT[@]}" -F /dev/null -p "${SSH_PORT}" -o ClearAllForwardings=yes -o ForwardAgent=no -o StrictHostKeyChecking="${SSH_STRICT_HOST_CHECKING}")
if [ "${SSH_STRICT_HOST_CHECKING}" = "no" ]; then
  SSH_BASE+=(-o UserKnownHostsFile=/dev/null)
fi
if [ ${#SSH_AUTH_OPTS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_AUTH_OPTS[@]}")
fi
if [ ${#SSH_ID_ARGS[@]} -gt 0 ]; then
  SSH_BASE+=("${SSH_ID_ARGS[@]}")
fi
SSH_BASE+=("${PHONE_USER}@${PHONE_HOST}")

echo "Installing startup-missing HA requirements on ${PHONE_USER}@${PHONE_HOST}:${SSH_PORT}..."

"${SSH_BASE[@]}" 'bash -s' <<'REMOTE_INSTALL'
set -euo pipefail

VENV_PY="$HOME/.venv/bin/python"
RUN_LOG="$HOME/logs/hass-runner.log"
HA_LOG_TERMUX_HOME="$HOME/.homeassistant/home-assistant.log"
HA_LOG_SUROOT="$HOME/.suroot/.homeassistant/home-assistant.log"

if [ ! -x "$VENV_PY" ]; then
  echo "ERROR: missing HA venv at $VENV_PY" >&2
  exit 1
fi

configure_android_build_env() {
  local detected
  detected="${ANDROID_API_LEVEL:-}"

  if [ -z "${detected}" ]; then
    detected="$("$VENV_PY" - 2>/dev/null <<'PY'
import sysconfig
v = sysconfig.get_config_var('ANDROID_API_LEVEL')
print(v or '')
PY
 || true)"
  fi

  if [ -z "${detected}" ] && command -v getprop >/dev/null 2>&1; then
    detected="$(getprop ro.build.version.sdk 2>/dev/null || true)"
  fi

  if [ -z "${detected}" ]; then
    echo "WARNING: Could not determine ANDROID_API_LEVEL; Rust/native builds may fail" >&2
    return 1
  fi

  export ANDROID_API_LEVEL="${detected}"
  echo "Using ANDROID_API_LEVEL=${ANDROID_API_LEVEL}"
}

configure_android_build_env || true

if [ ! -f "$RUN_LOG" ]; then
  echo "INFO: HA runner log not found at $RUN_LOG — Home Assistant has not been started yet."
  echo "INFO: Start Home Assistant first (e.g. ~/scripts/hass.sh or hassctl.sh start) then re-run this script."
  exit 0
fi

find_ha_log() {
  if [ -f "$HA_LOG_TERMUX_HOME" ]; then
    echo "$HA_LOG_TERMUX_HOME"
    return 0
  fi
  if [ -f "$HA_LOG_SUROOT" ]; then
    echo "$HA_LOG_SUROOT"
    return 0
  fi
  return 1
}

# Build and install a Python C-extension package from source on Android/Termux.
#
# Both zlib-ng and isal use setup.py with a SYSTEM_IS_UNIX guard that excludes
# sys.platform=="android". pip's standard source-build path therefore raises
# NotImplementedError before any compilation begins.  The workaround is:
#   1. Download the sdist.
#   2. Patch SYSTEM_IS_UNIX in setup.py to include "android".
#   3. Build the wheel with `python setup.py bdist_wheel` (avoids pip's
#      build-isolation wrapper which re-runs the unpatched pyproject.toml).
#   4. Install the resulting .whl with pip.
#
# NOTE: setup.py bdist_wheel exits with SIGSEGV (signal 11) during Python
# interpreter teardown *after* the wheel file is fully written.  The wheel is
# valid; we suppress the abnormal exit and check for the file explicitly.
_pip_install_patched_source() {
  local pip_name="$1"   # PyPI package name (e.g. "zlib-ng")
  local import_mod="$2" # Python import name to verify (e.g. "zlib_ng")
  local setup_patch="$3" # sed expression(s) to apply to setup.py (newline-separated)

  # Already installed?
  if "$VENV_PY" -c "import ${import_mod}" 2>/dev/null; then
    echo "OK: ${import_mod} already importable, skipping build"
    return 0
  fi

  local workdir
  workdir="$(mktemp -d)"
  trap "rm -rf '${workdir}'" RETURN

  echo "Downloading ${pip_name} sdist..."
  if ! "$VENV_PY" -m pip download --no-deps --no-binary "${pip_name}" "${pip_name}" \
        -d "${workdir}" 2>&1 | grep -E "^(Saved|error|ERROR)"; then
    echo "WARNING: failed to download ${pip_name} sdist" >&2
    return 1
  fi

  local tarball srcdir
  tarball="$(ls "${workdir}"/*.tar.gz 2>/dev/null | head -1)"
  if [ -z "${tarball}" ]; then
    echo "WARNING: no sdist tarball found for ${pip_name}" >&2
    return 1
  fi

  tar xzf "${tarball}" -C "${workdir}"
  srcdir="$(ls -d "${workdir}"/*/  2>/dev/null | head -1)"
  if [ -z "${srcdir}" ]; then
    echo "WARNING: could not find extracted source dir for ${pip_name}" >&2
    return 1
  fi
  srcdir="${srcdir%/}"

  echo "Patching setup.py for Android..."
  while IFS= read -r sed_expr; do
    [ -n "${sed_expr}" ] || continue
    sed -i "${sed_expr}" "${srcdir}/setup.py"
  done <<< "${setup_patch}"

  local distdir="${srcdir}/dist"
  mkdir -p "${distdir}"

  echo "Building wheel for ${pip_name} (may take a few minutes)..."
  # Exit code may be 139 (SIGSEGV) due to known teardown crash in setup.py
  # bdist_wheel on Android.  The wheel is fully written before the crash.
  (cd "${srcdir}" && "$VENV_PY" setup.py bdist_wheel 2>&1) || true

  local wheel
  wheel="$(ls "${distdir}"/*.whl 2>/dev/null | head -1)"
  if [ -z "${wheel}" ]; then
    echo "WARNING: wheel build produced no .whl file for ${pip_name}" >&2
    return 1
  fi

  echo "Installing ${wheel##*/}..."
  if "$VENV_PY" -m pip install --force-reinstall --disable-pip-version-check "${wheel}"; then
    echo "OK: ${pip_name} installed from patched source"
  else
    echo "WARNING: pip install of built wheel failed for ${pip_name}" >&2
    return 1
  fi
}

install_optional_zlib_accelerators_if_needed() {
  local ha_log
  ha_log="$(find_ha_log || true)"
  if [ -z "$ha_log" ]; then
    echo "INFO: Home Assistant core log not found; skipping optional zlib accelerator check."
    return 0
  fi

  if ! grep -q "\[aiohttp_fast_zlib\] zlib_ng and isal are not available" "$ha_log"; then
    echo "No aiohttp_fast_zlib accelerator warning detected in $(basename "$ha_log")"
    return 0
  fi

  echo "Detected aiohttp_fast_zlib fallback warning in $(basename "$ha_log")"
  echo ""
  echo "NOTE: zlib-ng and isal both hard-code 'android' as unsupported in their"
  echo "      setup.py SYSTEM_IS_UNIX guard.  Standard pip install always fails."
  echo "      Using patch-and-build approach: download sdist -> patch -> build .whl -> install."
  echo ""

  # ── zlib-ng ─────────────────────────────────────────────────────────────────
  # setup.py line 21: SYSTEM_IS_UNIX = (sys.platform.startswith("linux") or
  # Fix: insert android before the existing linux check.
  # setup.py line 110: elif sys.platform == "linux":
  # Fix: extend the condition to cover android too.
  local ZLIB_NG_PATCH
  ZLIB_NG_PATCH='s/SYSTEM_IS_UNIX = (sys.platform.startswith("linux") or/SYSTEM_IS_UNIX = (sys.platform.startswith("linux") or\n                  sys.platform == "android" or/
s/elif sys.platform == "linux":/elif sys.platform in ("linux", "android"):/
'
  _pip_install_patched_source "zlib-ng" "zlib_ng" "${ZLIB_NG_PATCH}" || \
    echo "WARNING: zlib-ng optional accelerator could not be installed" >&2

  # ── isal ────────────────────────────────────────────────────────────────────
  # setup.py line 28: SYSTEM_IS_BSD)
  # Fix: append android to the SYSTEM_IS_UNIX OR chain.
  local ISAL_PATCH
  ISAL_PATCH='s/SYSTEM_IS_BSD)/SYSTEM_IS_BSD or sys.platform == "android")/
'
  _pip_install_patched_source "isal" "isal" "${ISAL_PATCH}" || \
    echo "WARNING: isal optional accelerator could not be installed" >&2

  echo "Verifying optional package imports..."
  "$VENV_PY" - <<'PY'
mods = ("zlib_ng", "isal")
for mod in mods:
    try:
        __import__(mod)
        print(f"OK: import {mod}")
    except Exception as exc:
        print(f"MISSING: import {mod} failed: {exc}")
PY
}

# Scan a single log file for 'No module named' errors since the last HA start.
_scan_log_missing() {
  local logfile="$1"
  [ -f "$logfile" ] || { printf ''; return 0; }
  "$VENV_PY" -c "
import re, pathlib
p = pathlib.Path('${logfile}')
lines = p.read_text(errors='ignore').splitlines()
s = 0
for i, l in enumerate(lines):
    if 'Starting Home Assistant' in l:
        s = i
window = '\n'.join(lines[s:])
mods = sorted(set(re.findall(r\"No module named '([^']+)'\", window)))
print('\n'.join(mods))
" 2>/dev/null || true
}

# Capture missing module names from runner log AND HA core log.
HA_LOG_PATH="$(find_ha_log 2>/dev/null || true)"
MISSING_MODULES="$(
  { _scan_log_missing "$RUN_LOG"; _scan_log_missing "${HA_LOG_PATH:-}"; } \
  | sort -u | grep -v '^$' || true
)"

if [ -z "$MISSING_MODULES" ]; then
  echo "No missing Python modules detected in logs"
else
  echo "Missing modules detected:"
  printf '%s\n' "$MISSING_MODULES"
fi

to_pip_name() {
  case "$1" in
    gtts) echo "gTTS" ;;
    *) echo "$1" ;;
  esac
}

if [ -n "$MISSING_MODULES" ]; then
  while IFS= read -r module; do
    [ -n "$module" ] || continue
    pkg="$(to_pip_name "$module")"
    echo "Installing Python package: $pkg"
    if ! "$VENV_PY" -m pip install --disable-pip-version-check "$pkg"; then
      echo "WARNING: could not install package '$pkg' for module '$module'" >&2
    fi
  done <<EOF
$MISSING_MODULES
EOF
fi

# Known integration packages that require pre-installation (e.g. installed
# before HA can set up the integration flow for the first time).
# Format: pip_package_name|python_import_name
KNOWN_INTEGRATION_PKGS="gTTS|gtts
radios|radios
openai==2.15.0|openai"

install_known_integration_packages() {
  echo "Checking known integration packages..."
  while IFS='|' read -r pip_name import_mod; do
    [ -n "${pip_name}" ] || continue
    if "$VENV_PY" -c "import ${import_mod}" 2>/dev/null; then
      echo "OK: ${import_mod} already importable"
    else
      echo "Installing: ${pip_name}"
      if ! "$VENV_PY" -m pip install --disable-pip-version-check "${pip_name}"; then
        echo "WARNING: could not install '${pip_name}'" >&2
      fi
    fi
  done <<EOF
${KNOWN_INTEGRATION_PKGS}
EOF
}

# ── uv stub ─────────────────────────────────────────────────────────────────
# HA 2026.x always calls `python -m uv pip install` (no fallback to pip).
# Termux ships uv as a system binary, not a Python module.  Install a minimal
# stub package so `python -m uv` works by delegating to the system binary.
install_uv_python_stub() {
  local site_pkg
  site_pkg="$("$VENV_PY" -c 'import site; print(site.getsitepackages()[0])')"
  local stub_dir="${site_pkg}/uv"
  local uv_bin
  uv_bin="$(command -v uv 2>/dev/null || echo '/data/data/com.termux/files/usr/bin/uv')"

  if ! "$VENV_PY" -c "import uv" 2>/dev/null; then
    echo "Installing uv Python stub (delegates to system uv at ${uv_bin})..."
    mkdir -p "${stub_dir}"
    cat >"${stub_dir}/__init__.py" <<PYEOF
# Stub: makes 'python -m uv' delegate to the Termux system uv binary.
PYEOF
    cat >"${stub_dir}/__main__.py" <<PYEOF
import os, sys
_UV_BIN = "${uv_bin}"
if not os.path.isfile(_UV_BIN):
    raise FileNotFoundError(f"System uv binary not found at {_UV_BIN}")
os.execv(_UV_BIN, [_UV_BIN] + sys.argv[1:])
PYEOF
    if "$VENV_PY" -c "import uv" 2>/dev/null; then
      echo "OK: uv stub installed"
    else
      echo "WARNING: uv stub installation failed" >&2
    fi
  else
    echo "OK: uv already importable"
  fi
}

install_uv_python_stub
install_known_integration_packages
install_optional_zlib_accelerators_if_needed

echo "Startup-missing requirements install complete."
REMOTE_INSTALL

echo "Done."