#!/usr/bin/env bash
set -euo pipefail

# Build the obdmonitor Flutter app and install it on the connected Android phone.
# Uses FVM (https://fvm.app/) to resolve the Flutter SDK version pinned in
# android-app/obdmonitor/.fvm/fvm_config.json.
#
# Usage:
#   ./provisioning/adb/10_install_obdmonitor_apk.sh
#
# Optional variables:
#   SKIP_BUILD=1           – skip Flutter build (use existing APK in provisioning/apks/)
#   FLUTTER_BIN=           – override flutter binary (default: auto-resolved via fvm)
#   BUILD_MODE=release     – release (default) or debug
#
# Requirements:
#   - adb connected to phone (adb devices shows device)
#   - fvm installed (brew tap leoafarias/fvm && brew install fvm)
#   - Java 17+ in PATH for Gradle (brew install openjdk@17)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${ROOT_DIR}/android-app/obdmonitor"
APK_STAGING="${ROOT_DIR}/provisioning/apks"
BUILD_MODE="${BUILD_MODE:-release}"
SKIP_BUILD="${SKIP_BUILD:-0}"
PACKAGE_NAME="com.camperautomation.obdmonitor"

# ── Resolve Flutter via FVM ────────────────────────────────────────────────
# If FLUTTER_BIN is explicitly set, use it. Otherwise resolve through fvm.
if [ -n "${FLUTTER_BIN:-}" ]; then
  echo "Using custom FLUTTER_BIN: ${FLUTTER_BIN}"
else
  if ! command -v fvm >/dev/null 2>&1; then
    echo "ERROR: fvm not found in PATH." >&2
    echo "  Install: brew tap leoafarias/fvm && brew install fvm" >&2
    echo "  Then run: fvm install  (from ${APP_DIR})" >&2
    exit 1
  fi
  # fvm creates a per-project symlink .fvm/flutter_sdk pointing to the cached SDK.
  # Use its bin/flutter directly so the script works without shell alias tricks.
  FVM_SYMLINK="${APP_DIR}/.fvm/flutter_sdk"
  if [ ! -L "${FVM_SYMLINK}" ]; then
    echo "FVM symlink not found at ${FVM_SYMLINK}. Running 'fvm install'..."
    (cd "${APP_DIR}" && fvm install)
  fi
  FLUTTER_BIN="${FVM_SYMLINK}/bin/flutter"
  echo "Using fvm-managed Flutter SDK: $(readlink -f "${FVM_SYMLINK}")"
fi

# ── Preflight ──────────────────────────────────────────────────────────────

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found in PATH." >&2
  exit 1
fi

adb wait-for-device
DEVICE_SERIAL="$(adb get-serialno 2>/dev/null | tr -d '\r')"
echo "Target device: ${DEVICE_SERIAL:-unknown}"

# ── Build ──────────────────────────────────────────────────────────────────

APK_PATH="${APK_STAGING}/obdmonitor.apk"

if [ "${SKIP_BUILD}" = "1" ]; then
  echo "SKIP_BUILD=1: skipping Flutter build, using ${APK_PATH}"
else
  # Verify the resolved binary actually works.
  if ! "${FLUTTER_BIN}" --version >/dev/null 2>&1; then
    echo "ERROR: Flutter not available at '${FLUTTER_BIN}'." >&2
    echo "  Ensure fvm is installed and 'fvm install' has been run in ${APP_DIR}" >&2
    echo "  Or set SKIP_BUILD=1 to use a pre-built APK at ${APK_PATH}" >&2
    exit 1
  fi

  if [ ! -d "${APP_DIR}" ]; then
    echo "ERROR: obdmonitor app directory missing: ${APP_DIR}" >&2
    exit 1
  fi
  if [ ! -f "${APP_DIR}/pubspec.yaml" ]; then
    echo "ERROR: pubspec.yaml missing in ${APP_DIR}" >&2
    exit 1
  fi

  echo "Building obdmonitor (${BUILD_MODE}) with Flutter (via fvm)..."
  echo "  App dir: ${APP_DIR}"

  (
    cd "${APP_DIR}"
    "${FLUTTER_BIN}" pub get
    "${FLUTTER_BIN}" build apk "--${BUILD_MODE}" --target-platform android-arm64
  )

  BUILT_APK="${APP_DIR}/build/app/outputs/flutter-apk/app-${BUILD_MODE}.apk"
  if [ ! -f "${BUILT_APK}" ]; then
    echo "ERROR: build succeeded but APK not found at ${BUILT_APK}" >&2
    exit 1
  fi

  mkdir -p "${APK_STAGING}"
  cp "${BUILT_APK}" "${APK_PATH}"
  echo "APK copied to staging: ${APK_PATH}"
fi

# ── Install ────────────────────────────────────────────────────────────────

if [ ! -f "${APK_PATH}" ]; then
  echo "ERROR: APK not found at ${APK_PATH}. Build it first or set SKIP_BUILD=0." >&2
  exit 1
fi

echo "Installing obdmonitor APK on device..."
echo "  → You may need to approve the installation on the phone screen."
adb install -r "${APK_PATH}" || {
  echo "ERROR: APK installation failed." >&2
  echo "  On Xiaomi/MIUI: enable Developer options → Install via USB." >&2
  exit 1
}

echo "obdmonitor installed. Verifying package on device..."
INSTALLED_VERSION="$(adb shell dumpsys package "${PACKAGE_NAME}" 2>/dev/null \
  | grep -m1 versionName | tr -d '\r' | awk -F= '{print $2}' || echo "unknown")"
echo "  Installed version: ${INSTALLED_VERSION}"

echo ""
echo "=== obdmonitor APK installed successfully ==="
echo "NEXT:"
echo "  1. Open 'OBD Monitor' app on the phone."
echo "  2. Grant Bluetooth permissions when prompted."
echo "  3. Pair ELM327 adapter via Android BT settings if not already done."
echo "  4. Select ELM327 adapter in the app dropdown."
echo "  5. Start the engine — the app will connect and start polling."
echo "  6. Verify REST endpoint from Termux: curl http://127.0.0.1:8766/health"
echo ""
echo "To rebuild: JAVA_HOME=/opt/homebrew/opt/openjdk@17 bash provisioning/adb/10_install_obdmonitor_apk.sh"
