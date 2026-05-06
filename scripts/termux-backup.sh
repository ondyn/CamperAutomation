#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${1:-${HOME}/storage/shared/CamperAutomationBackups}"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
TMP_DIR="${PREFIX}/tmp/camper-backup-${STAMP}"

HOME_ARCHIVE="${BACKUP_DIR}/termux-home.tar.gz"
PREFIX_ARCHIVE="${BACKUP_DIR}/termux-prefix.tar.gz"
HA_ARCHIVE="${BACKUP_DIR}/homeassistant-config.tar.gz"
PKG_LIST="${BACKUP_DIR}/termux-packages.txt"
APT_SOURCES="${BACKUP_DIR}/termux-apt-sources.tar.gz"
METADATA_FILE="${BACKUP_DIR}/metadata.env"

mkdir -p "${BACKUP_DIR}" "${TMP_DIR}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if [ ! -d "${HOME}/storage/shared" ]; then
  echo "Shared storage is not mounted in Termux." >&2
  echo "Run: termux-setup-storage" >&2
  exit 1
fi

dpkg-query -W -f='${Package}\n' | sort -u > "${PKG_LIST}"

cat >"${METADATA_FILE}" <<EOF
BACKUP_CREATED_AT=$(date -u +%FT%TZ)
TERMUX_PREFIX=${PREFIX}
TERMUX_HOME=${HOME}
ANDROID_SDK=$(getprop ro.build.version.sdk 2>/dev/null || true)
ANDROID_DEVICE=$(getprop ro.product.device 2>/dev/null || true)
EOF

tar -C "${PREFIX}/etc" -czf "${APT_SOURCES}" apt

tar \
  --exclude='./storage' \
  --exclude='./.cache' \
  --exclude='./.npm' \
  --exclude='./.cargo/registry' \
  --exclude='./.rustup/downloads' \
  -C "${HOME}" \
  -czf "${HOME_ARCHIVE}" .

tar \
  --exclude='./tmp' \
  --exclude='./var/cache/apt/archives' \
  -C "${PREFIX}" \
  -czf "${PREFIX_ARCHIVE}" .

HA_CONFIG_SOURCE=""
for candidate in "${HOME}/.suroot/.homeassistant" "${HOME}/.homeassistant"; do
  if [ -d "${candidate}" ]; then
    HA_CONFIG_SOURCE="${candidate}"
    break
  fi
done

if [ -n "${HA_CONFIG_SOURCE}" ]; then
  tar -C "$(dirname "${HA_CONFIG_SOURCE}")" -czf "${HA_ARCHIVE}" "$(basename "${HA_CONFIG_SOURCE}")"
fi

cat <<EOF
Backup completed: ${BACKUP_DIR}

Created files:
  ${PKG_LIST}
  ${APT_SOURCES}
  ${HOME_ARCHIVE}
  ${PREFIX_ARCHIVE}
EOF

if [ -f "${HA_ARCHIVE}" ]; then
  echo "  ${HA_ARCHIVE}"
fi