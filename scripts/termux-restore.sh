#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <backup-directory>" >&2
  exit 1
fi

BACKUP_DIR="$1"
PKG_LIST="${BACKUP_DIR}/termux-packages.txt"
APT_SOURCES="${BACKUP_DIR}/termux-apt-sources.tar.gz"
HOME_ARCHIVE="${BACKUP_DIR}/termux-home.tar.gz"
PREFIX_ARCHIVE="${BACKUP_DIR}/termux-prefix.tar.gz"
CONFIG_ARCHIVE="${BACKUP_DIR}/termux-config.tar.gz"
HA_ARCHIVE="${BACKUP_DIR}/homeassistant-config.tar.gz"
TAILSCALE_ARCHIVE="${BACKUP_DIR}/tailscale-config.tar.gz"

restore_legacy_full_backup() {
  echo "Detected legacy full backup format."

  for required in "${PKG_LIST}" "${APT_SOURCES}" "${HOME_ARCHIVE}"; do
    if [ ! -f "${required}" ]; then
      echo "Missing legacy backup artifact: ${required}" >&2
      exit 1
    fi
  done

  mkdir -p "${HOME}" "${PREFIX}"

  tar -C "${PREFIX}/etc" -xzf "${APT_SOURCES}"
  pkg update -y

  if [ -s "${PKG_LIST}" ]; then
    tr '\n' ' ' < "${PKG_LIST}" | xargs pkg install -y
  fi

  tar -C "${HOME}" -xzf "${HOME_ARCHIVE}"

  if [ -f "${PREFIX_ARCHIVE}" ]; then
    tar -C "${PREFIX}" -xzf "${PREFIX_ARCHIVE}"
  fi

  if [ -f "${HA_ARCHIVE}" ]; then
    mkdir -p "${HOME}/.suroot"
    tar -C "${HOME}/.suroot" -xzf "${HA_ARCHIVE}"
  fi

  echo "Restore completed from legacy full backup: ${BACKUP_DIR}"
}

restore_config_backup() {
  local tmp_restore_dir
  local extracted_ha_dir
  local target_ha_dir

  if [ ! -f "${HA_ARCHIVE}" ]; then
    echo "Missing backup artifact: ${HA_ARCHIVE}" >&2
    echo "This configuration backup requires Home Assistant config archive." >&2
    exit 1
  fi

  mkdir -p "${HOME}"

  if [ -f "${CONFIG_ARCHIVE}" ]; then
    tar -C "${HOME}" -xzf "${CONFIG_ARCHIVE}"
  fi

  if [ -f "${TAILSCALE_ARCHIVE}" ]; then
    tar -C "${HOME}" -xzf "${TAILSCALE_ARCHIVE}"
  fi

  tmp_restore_dir="$(mktemp -d "${PREFIX}/tmp/camper-restore-ha-XXXXXX")"

  tar -C "${tmp_restore_dir}" -xzf "${HA_ARCHIVE}"
  extracted_ha_dir="$(find "${tmp_restore_dir}" -type d -name .homeassistant | head -n1 || true)"

  if [ -z "${extracted_ha_dir}" ]; then
    rm -rf "${tmp_restore_dir}"
    echo "ERROR: Could not locate .homeassistant in ${HA_ARCHIVE}" >&2
    exit 1
  fi

  if [ -d "${HOME}/.suroot" ] || [ -d "${HOME}/.suroot/.homeassistant" ]; then
    target_ha_dir="${HOME}/.suroot/.homeassistant"
  else
    target_ha_dir="${HOME}/.homeassistant"
  fi

  mkdir -p "$(dirname "${target_ha_dir}")"
  rm -rf "${target_ha_dir}"
  cp -a "${extracted_ha_dir}" "${target_ha_dir}"
  rm -rf "${tmp_restore_dir}"

  echo "Restore completed from configuration backup: ${BACKUP_DIR}"
  echo "Home Assistant config restored to: ${target_ha_dir}"
  echo "Tailscale config restored if archive existed: ${TAILSCALE_ARCHIVE}"
}

if [ -f "${HOME_ARCHIVE}" ] || [ -f "${APT_SOURCES}" ]; then
  restore_legacy_full_backup
else
  restore_config_backup
fi

echo "Recommended follow-up: restart Termux services, then run ~/scripts/hassctl.sh status"