#!/usr/bin/env bash
# Keep Chromium displaying the station dashboard for a public projector.
set -Eeuo pipefail

URL="${1:-http://127.0.0.1:8080/}"
PROFILE_DIR="${HOME}/.config/songrec-station-kiosk/chromium"
START_DELAY_SECONDS="${SONGREC_KIOSK_START_DELAY:-12}"
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/songrec-station-kiosk"

if command -v chromium >/dev/null 2>&1; then
  BROWSER="chromium"
elif command -v chromium-browser >/dev/null 2>&1; then
  BROWSER="chromium-browser"
else
  echo "Chromium is not installed." >&2
  exit 1
fi

mkdir -p "${PROFILE_DIR}"
mkdir -p "${STATE_DIR}"

# On Raspberry Pi OS Bookworm+ this avoids Chromium starting before labwc is
# ready. It also leaves the dashboard service enough time to start at boot.
sleep "${START_DELAY_SECONDS}"

if [[ "${XDG_SESSION_TYPE:-}" == "x11" || -n "${DISPLAY:-}" ]]; then
  if command -v xset >/dev/null 2>&1; then
    xset s off || true
    xset -dpms || true
    xset s noblank || true
  fi

  # With more than one detected connector, Chromium can correctly enter kiosk
  # mode but fill only one portion of the combined X desktop. A public station
  # has one intended projector, so make the primary HDMI output the only X11
  # output. Set SONGREC_KIOSK_OUTPUT (for example HDMI-1) to choose explicitly.
  if command -v xrandr >/dev/null 2>&1; then
    mapfile -t CONNECTED_OUTPUTS < <(xrandr --query | awk '$2 == "connected" { print $1 }')
    KIOSK_OUTPUT="${SONGREC_KIOSK_OUTPUT:-}"
    if [[ -z "${KIOSK_OUTPUT}" ]]; then
      KIOSK_OUTPUT="$(xrandr --query | awk '$2 == "connected" && $3 == "primary" { print $1; exit }')"
    fi
    if [[ -z "${KIOSK_OUTPUT}" ]]; then
      KIOSK_OUTPUT="$(xrandr --query | awk '$2 == "connected" && $1 ~ /^HDMI/ { print $1; exit }')"
    fi
    if [[ -z "${KIOSK_OUTPUT}" && "${#CONNECTED_OUTPUTS[@]}" -gt 0 ]]; then
      KIOSK_OUTPUT="${CONNECTED_OUTPUTS[0]}"
    fi
    if [[ -n "${KIOSK_OUTPUT}" ]]; then
      xrandr --output "${KIOSK_OUTPUT}" --auto --primary || true
      for output in "${CONNECTED_OUTPUTS[@]}"; do
        if [[ "${output}" != "${KIOSK_OUTPUT}" ]]; then
          xrandr --output "${output}" --off || true
        fi
      done
    fi
    xrandr --query >"${STATE_DIR}/xrandr.log" 2>&1 || true
  fi
fi

while true; do
  WAYLAND_FLAGS=()
  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    WAYLAND_FLAGS+=(--ozone-platform=wayland)
  fi
  "${BROWSER}" \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --hide-scrollbars \
    --no-first-run \
    --no-default-browser-check \
    --disable-features=TranslateUI \
    --user-data-dir="${PROFILE_DIR}" \
    "${WAYLAND_FLAGS[@]}" \
    "${URL}" || true
  # Re-open the public display if Chromium crashes or is closed remotely.
  sleep 5
done
