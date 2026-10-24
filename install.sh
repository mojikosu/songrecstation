#!/usr/bin/env bash
# SongRec Station — modular installer with a component picker.
#
# Interactive:      ./install.sh
# Unattended:       ./install.sh --components core,web --audio-device hw:1,0
#                   ./install.sh --all
# List components:  ./install.sh --list
set -Eeuo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this as your normal user (not root); it uses sudo when needed." >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SRC_DIR
export STATION_USER="$(id -un)"
export STATION_HOME="${HOME}"
export DATA_DIR="/var/lib/songrec-station"

# name | description | installer
COMPONENTS=(
  "core|SongRec + audio worker + systemd service (needs USB phono preamp)"
  "web|Web dashboard (songrec-web) on port 8080"
  "kiosk|Chromium kiosk showing the dashboard on HDMI (songrec-web-kiosk)"
)

SELECTED=()
AUDIO_DEVICE=""
ASSUME_YES=0

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

list_components() {
  for entry in "${COMPONENTS[@]}"; do
    printf '  %-6s %s\n' "${entry%%|*}" "${entry#*|}"
  done
}

# ---------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)          SELECTED=(core web kiosk) ;;
    --components)   IFS=',' read -r -a SELECTED <<<"${2:?--components needs a value}"; shift ;;
    --audio-device) AUDIO_DEVICE="${2:?--audio-device needs a value}"; shift ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --list)         list_components; exit 0 ;;
    -h|--help)      usage 0 ;;
    *)              echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

# Piped installs (curl | bash) have no stdin; reattach the terminal for menus.
if [[ ! -t 0 ]] && { true </dev/tty; } 2>/dev/null; then
  exec </dev/tty
fi

# -------------------------------------------------------- component picker
if [[ ${#SELECTED[@]} -eq 0 ]]; then
  if ! command -v whiptail >/dev/null 2>&1 || [[ ! -t 0 ]]; then
    echo "No terminal for the picker. Use --all or --components core,web,kiosk" >&2
    exit 1
  fi
  items=()
  for entry in "${COMPONENTS[@]}"; do
    name="${entry%%|*}"; desc="${entry#*|}"
    state=ON; [[ "${name}" == "kiosk" ]] && state=OFF
    items+=("${name}" "${desc}" "${state}")
  done
  choice="$(whiptail --title "SongRec Station" \
    --checklist "Select components to install\n(SPACE toggles, ENTER confirms)" \
    18 90 3 "${items[@]}" 3>&1 1>&2 2>&3)" || { echo "Cancelled."; exit 1; }
  read -r -a SELECTED <<<"$(tr -d '"' <<<"${choice}")"
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "Nothing selected."; exit 0
fi

has() { local c; for c in "${SELECTED[@]}"; do [[ "$c" == "$1" ]] && return 0; done; return 1; }

# Validate names
for c in "${SELECTED[@]}"; do
  case "$c" in core|web|kiosk) ;; *) echo "Unknown component: $c" >&2; exit 1 ;; esac
done

# ---------------------------------------------------- audio device (core)
pick_audio_device() {
  local menu=() line card name desc dev
  while IFS= read -r line; do
    if [[ "${line}" =~ ^card\ ([0-9]+):\ ([^ ]+)\ \[(.*)\],\ device\ ([0-9]+): ]]; then
      card="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"; dev="${BASH_REMATCH[4]}"
      desc="${BASH_REMATCH[3]}"
      # Card *names* survive reboots; card *numbers* do not (core disables the
      # onboard audio, which renumbers the USB card).
      menu+=("hw:CARD=${name},DEV=${dev}" "${name} - ${desc} (card ${card})")
    fi
  done < <(arecord -l 2>/dev/null || true)

  if [[ ${#menu[@]} -eq 0 ]]; then
    echo "No capture device found by 'arecord -l'; falling back to ALSA 'default'." >&2
    AUDIO_DEVICE="default"; return
  fi
  if [[ ${#menu[@]} -eq 2 || ${ASSUME_YES} -eq 1 ]]; then
    AUDIO_DEVICE="${menu[0]}"; return
  fi
  AUDIO_DEVICE="$(whiptail --title "Audio input" \
    --menu "Choose the USB phono preamp / capture device" 16 78 6 \
    "${menu[@]}" 3>&1 1>&2 2>&3)" || { echo "Cancelled."; exit 1; }
}

normalize_audio_device() {  # hw:1,0 -> hw:CARD=<name>,DEV=0
  local dev="$1" idx sub name
  if [[ "${dev}" =~ ^hw:([0-9]+),([0-9]+)$ ]]; then
    idx="${BASH_REMATCH[1]}"; sub="${BASH_REMATCH[2]}"
    name="$(arecord -l 2>/dev/null | sed -nE "s/^card ${idx}: ([^ ]+) \[.*/\1/p" | head -n1)"
    [[ -n "${name}" ]] && dev="hw:CARD=${name},DEV=${sub}"
  fi
  printf '%s' "${dev}"
}

if has core; then
  command -v arecord >/dev/null 2>&1 || sudo apt-get install -y --no-install-recommends alsa-utils
  if [[ -z "${AUDIO_DEVICE}" ]]; then
    pick_audio_device
  else
    AUDIO_DEVICE="$(normalize_audio_device "${AUDIO_DEVICE}")"
  fi
fi
export AUDIO_DEVICE

# --------------------------------------------------------------- summary
echo
echo "Installing: ${SELECTED[*]}"
has core && echo "Audio device: ${AUDIO_DEVICE}"
echo "(The core build compiles SongRec from source and can take a long time on a Pi 3+.)"
if [[ ${ASSUME_YES} -eq 0 && -t 0 ]]; then
  read -r -p "Continue? [Y/n] " reply
  [[ "${reply,,}" =~ ^(n|no)$ ]] && { echo "Aborted."; exit 0; }
fi

# ------------------------------------------------------------ components
run_script() {  # run_script <label> <path> [args...]
  local label="$1" path="$2"; shift 2
  if [[ ! -f "${path}" ]]; then
    echo "!! ${label}: ${path} not found, skipping." >&2; return 1
  fi
  echo; echo "=== ${label} ==="
  bash "${path}" "$@"
}

FAILED=()
# The dashboard unit mounts the data dir read-only and will not start if it is
# missing (core normally creates it).
if has web && ! has core; then
  sudo install -d -o "${STATION_USER}" -g "${STATION_USER}" -m 0755 "${DATA_DIR}"
fi
# Fixed order: core first, dashboard next, kiosk last.
if has core;  then run_script "core"  "${SRC_DIR}/install-songrec-station.sh" "${AUDIO_DEVICE}" || FAILED+=(core);  fi
# Point SongRec at the same card by name; the core installer hardcodes CODEC.
if has core && [[ ! " ${FAILED[*]} " == *" core "* && "${AUDIO_DEVICE}" =~ ^hw:CARD= ]] \
   && [[ -f /etc/songrec-station.env ]]; then
  sudo sed -i "s|^SONGREC_DEVICE=.*|SONGREC_DEVICE=alsa:${AUDIO_DEVICE}|" /etc/songrec-station.env
  sudo systemctl restart songrec-station.service || true
fi
if has web;   then run_script "web"   "${SRC_DIR}/songrec-web/install-songrec-web.sh"                      || FAILED+=(web);   fi
if has kiosk; then run_script "kiosk" "${SRC_DIR}/songrec-web-kiosk/install-songrec-kiosk.sh"                || FAILED+=(kiosk); fi

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Finished with problems in: ${FAILED[*]}" >&2
else
  echo "All selected components installed."
fi

# Onboard audio is disabled by core and the kiosk usually sets autologin: reboot.
if has core || has kiosk; then
  if [[ ${ASSUME_YES} -eq 1 ]]; then
    echo "Reboot when convenient: sudo reboot"
  else
    read -r -p "A reboot is recommended. Reboot now? [y/N] " reply
    [[ "${reply,,}" =~ ^(y|yes)$ ]] && sudo reboot
  fi
fi
[[ ${#FAILED[@]} -eq 0 ]]
