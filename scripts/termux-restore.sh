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
HA_ARCHIVE="${BACKUP_DIR}/homeassistant-config.tar.gz"

for required in "${PKG_LIST}" "${APT_SOURCES}" "${HOME_ARCHIVE}"; do
  if [ ! -f "${required}" ]; then
    echo "Missing backup artifact: ${required}" >&2
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

echo "Restore completed from ${BACKUP_DIR}"
echo "Recommended follow-up: restart Termux, then run ~/scripts/hassctl.sh status"