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
METADATA_FILE="${BACKUP_DIR}/metadata.env"

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
  local backup_ha_config_rel
  local expected_dashboard_count
  local restored_dashboard_count

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

  backup_ha_config_rel=""
  expected_dashboard_count=""
  if [ -f "${METADATA_FILE}" ]; then
    backup_ha_config_rel="$(sed -n 's/^HA_CONFIG_REL=//p' "${METADATA_FILE}" | tail -n1)"
    expected_dashboard_count="$(sed -n 's/^HA_STORAGE_DASHBOARD_COUNT=//p' "${METADATA_FILE}" | tail -n1)"
  fi

  case "${expected_dashboard_count}" in
    ""|*[!0-9]*)
      if [ -n "${expected_dashboard_count}" ]; then
        rm -rf "${tmp_restore_dir}"
        echo "ERROR: Invalid HA_STORAGE_DASHBOARD_COUNT in ${METADATA_FILE}." >&2
        exit 1
      fi
      ;;
  esac

  case "${backup_ha_config_rel}" in
    .homeassistant|.suroot/.homeassistant)
      target_ha_dir="${HOME}/${backup_ha_config_rel}"
      ;;
    *)
      if [ -d "${HOME}/.homeassistant" ]; then
        target_ha_dir="${HOME}/.homeassistant"
      elif [ -d "${HOME}/.suroot/.homeassistant" ]; then
        target_ha_dir="${HOME}/.suroot/.homeassistant"
      else
        target_ha_dir="${HOME}/.homeassistant"
      fi
      ;;
  esac

  restored_dashboard_count=0
  for dashboard_file in "${extracted_ha_dir}/.storage"/lovelace.dashboard_*; do
    [ -f "${dashboard_file}" ] || continue
    restored_dashboard_count=$((restored_dashboard_count + 1))
  done
  if [ -n "${expected_dashboard_count}" ] && [ "${restored_dashboard_count}" -ne "${expected_dashboard_count}" ]; then
    rm -rf "${tmp_restore_dir}"
    echo "ERROR: Dashboard count mismatch in ${HA_ARCHIVE}: expected ${expected_dashboard_count}, found ${restored_dashboard_count}." >&2
    exit 1
  fi

  if pgrep -f -- "[[:space:]]-c[[:space:]]+${target_ha_dir}([[:space:]]|$)" >/dev/null 2>&1; then
    rm -rf "${tmp_restore_dir}"
    echo "ERROR: Home Assistant is running with ${target_ha_dir}." >&2
    echo "Stop it with ~/scripts/hassctl.sh stop, then run restore again." >&2
    exit 1
  fi

  mkdir -p "$(dirname "${target_ha_dir}")"
  rm -rf "${target_ha_dir}"
  cp -a "${extracted_ha_dir}" "${target_ha_dir}"
  rm -rf "${tmp_restore_dir}"

  echo "Restore completed from configuration backup: ${BACKUP_DIR}"
  echo "Home Assistant config restored to: ${target_ha_dir}"
  echo "Storage-backed dashboards restored: ${restored_dashboard_count}"
  echo "Tailscale config restored if archive existed: ${TAILSCALE_ARCHIVE}"
}

if [ -f "${HOME_ARCHIVE}" ] || [ -f "${APT_SOURCES}" ]; then
  restore_legacy_full_backup
else
  restore_config_backup
fi

echo "Recommended follow-up: restart Termux services, then run ~/scripts/hassctl.sh status"