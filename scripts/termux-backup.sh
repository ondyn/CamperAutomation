#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PREFIX="/data/data/com.termux/files/usr"
PATH="${PREFIX}/bin:${PATH}"
export PREFIX PATH

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${1:-${HOME}/storage/shared/CamperAutomationBackups}"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
TMP_DIR="${PREFIX}/tmp/camper-backup-${STAMP}"

CONFIG_ARCHIVE="${BACKUP_DIR}/termux-config.tar.gz"
HA_ARCHIVE="${BACKUP_DIR}/homeassistant-config.tar.gz"
TAILSCALE_ARCHIVE="${BACKUP_DIR}/tailscale-config.tar.gz"
PKG_LIST="${BACKUP_DIR}/termux-packages.txt"
MANIFEST_FILE="${BACKUP_DIR}/manifest.txt"
METADATA_FILE="${BACKUP_DIR}/metadata.env"

mkdir -p "${BACKUP_DIR}" "${TMP_DIR}" "${TMP_DIR}/termux-config" "${TMP_DIR}/tailscale"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

if [ ! -d "${HOME}/storage/shared" ]; then
  echo "Shared storage is not mounted in Termux." >&2
  echo "Run: termux-setup-storage" >&2
  exit 1
fi

collect_if_exists() {
  local src_rel="$1"
  local src_abs="${HOME}/${src_rel}"
  local dst_abs="${TMP_DIR}/termux-config/${src_rel}"

  if [ -e "${src_abs}" ]; then
    mkdir -p "$(dirname "${dst_abs}")"
    cp -a "${src_abs}" "${dst_abs}"
    echo "${src_rel}" >> "${MANIFEST_FILE}"
  fi
}

collect_ssh_files() {
  local ssh_dir="${HOME}/.ssh"
  local dst_dir="${TMP_DIR}/termux-config/.ssh"

  [ -d "${ssh_dir}" ] || return 0
  mkdir -p "${dst_dir}"

  # Avoid runtime sockets (for example .ssh/agent/*) and keep only stable config/key files.
  for name in authorized_keys config known_hosts; do
    if [ -f "${ssh_dir}/${name}" ]; then
      cp -a "${ssh_dir}/${name}" "${dst_dir}/${name}"
      echo ".ssh/${name}" >> "${MANIFEST_FILE}"
    fi
  done

  find "${ssh_dir}" -mindepth 1 -maxdepth 1 -type f \( -name 'id_*' -o -name '*.pub' \) ! -name '*.sock' -print0 \
    | while IFS= read -r -d '' key_file; do
        local rel
        rel="${key_file#${HOME}/}"
        cp -a "${key_file}" "${TMP_DIR}/termux-config/${rel}"
        echo "${rel}" >> "${MANIFEST_FILE}"
      done
}

collect_tailscale_path_if_exists() {
  local src_rel="$1"
  local src_abs="${HOME}/${src_rel}"
  local dst_abs="${TMP_DIR}/tailscale/${src_rel}"

  if [ -e "${src_abs}" ]; then
    mkdir -p "$(dirname "${dst_abs}")"
    cp -a "${src_abs}" "${dst_abs}"
    echo "tailscale:${src_rel}" >> "${MANIFEST_FILE}"
  fi
}

cat >"${MANIFEST_FILE}" <<EOF
# Configuration-only backup manifest
# Includes Home Assistant configuration/database and selected Termux/Tailscale settings.
EOF

dpkg-query -W -f='${Package}\n' | sort -u > "${PKG_LIST}"

cat >"${METADATA_FILE}" <<EOF
BACKUP_CREATED_AT=$(date -u +%FT%TZ)
TERMUX_PREFIX=${PREFIX}
TERMUX_HOME=${HOME}
BACKUP_MODE=config-only
ANDROID_SDK=$(getprop ro.build.version.sdk 2>/dev/null || true)
ANDROID_DEVICE=$(getprop ro.product.device 2>/dev/null || true)
EOF

# Core Termux configuration to restore startup and access behavior.
collect_if_exists ".termux"
collect_ssh_files
collect_if_exists ".provisioning/locks"
collect_if_exists "scripts"
collect_if_exists ".bashrc"
collect_if_exists ".profile"
collect_if_exists ".zshrc"
collect_if_exists ".gitconfig"

# Tailscale userspace configuration/state (accessible as Termux user).
collect_tailscale_path_if_exists ".config/tailscale"
collect_tailscale_path_if_exists ".local/state/tailscale"
collect_tailscale_path_if_exists ".tailscale"

if find "${TMP_DIR}/termux-config" -mindepth 1 -print -quit >/dev/null 2>&1; then
  tar -C "${TMP_DIR}/termux-config" -czf "${CONFIG_ARCHIVE}" .
fi

if find "${TMP_DIR}/tailscale" -mindepth 1 -print -quit >/dev/null 2>&1; then
  tar -C "${TMP_DIR}/tailscale" -czf "${TAILSCALE_ARCHIVE}" .
fi

HA_CONFIG_SOURCE=""
for candidate in "${HOME}/.suroot/.homeassistant" "${HOME}/.homeassistant"; do
  if [ -d "${candidate}" ]; then
    HA_CONFIG_SOURCE="${candidate}"
    break
  fi
done

if [ -n "${HA_CONFIG_SOURCE}" ]; then
  tar -C "$(dirname "${HA_CONFIG_SOURCE}")" -czf "${HA_ARCHIVE}" "$(basename "${HA_CONFIG_SOURCE}")"
  echo "homeassistant:${HA_CONFIG_SOURCE#${HOME}/}" >> "${MANIFEST_FILE}"
fi

cat <<EOF
Backup completed: ${BACKUP_DIR}

Created files:
  ${METADATA_FILE}
  ${MANIFEST_FILE}
  ${PKG_LIST}
EOF

if [ -f "${CONFIG_ARCHIVE}" ]; then
  echo "  ${CONFIG_ARCHIVE}"
fi

if [ -f "${TAILSCALE_ARCHIVE}" ]; then
  echo "  ${TAILSCALE_ARCHIVE}"
fi

if [ -f "${HA_ARCHIVE}" ]; then
  echo "  ${HA_ARCHIVE}"
else
  echo "WARNING: Home Assistant config directory was not found, so no HA archive was created." >&2
fi

cat <<EOF

Notes:
  - This backup is configuration-only (not full Termux runtime snapshot).
  - Runtime caches, package trees, sockets, and logs are intentionally excluded.
EOF