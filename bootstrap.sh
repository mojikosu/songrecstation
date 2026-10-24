#!/usr/bin/env bash
# SongRec Station bootstrap — one command on a freshly flashed Raspberry Pi OS:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/mojikosu/songrecstation/main/bootstrap.sh)
#
# Extra arguments are passed on to install.sh, e.g.:
#   bash <(curl -fsSL .../bootstrap.sh) --all --audio-device hw:1,0
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/mojikosu/songrecstation.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
TARGET_DIR="${TARGET_DIR:-$HOME/songrecstation}"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this as your normal user (not root); it uses sudo when needed." >&2
  exit 1
fi

echo "Installing bootstrap prerequisites..."
sudo env DEBIAN_FRONTEND=noninteractive apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git whiptail ca-certificates curl

if [[ -d "${TARGET_DIR}/.git" ]]; then
  echo "Updating ${TARGET_DIR}..."
  git -C "${TARGET_DIR}" fetch --depth 1 origin "${REPO_BRANCH}"
  git -C "${TARGET_DIR}" reset --hard "origin/${REPO_BRANCH}"
else
  echo "Cloning ${REPO_URL} into ${TARGET_DIR}..."
  git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${TARGET_DIR}"
fi

exec bash "${TARGET_DIR}/install.sh" "$@"
