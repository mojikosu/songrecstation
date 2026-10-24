#!/usr/bin/env bash
# Install a Chromium kiosk for the locally hosted SongRec station dashboard.
# Run as the Raspberry Pi account that should log in to the graphical desktop.
set -Eeuo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "Run this as the desktop account, not as root." >&2
  exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_SOURCE="${SOURCE_DIR}/songrec-kiosk-launcher.sh"
KIOSK_USER="$(id -un)"
KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"
DASHBOARD_URL="${1:-http://127.0.0.1:8080/}"
LAUNCHER_DESTINATION="${KIOSK_HOME}/.local/bin/songrec-station-kiosk"
LABWC_AUTOSTART="${KIOSK_HOME}/.config/labwc/autostart"
LXDE_AUTOSTART="${KIOSK_HOME}/.config/lxsession/LXDE-pi/autostart"
LIGHTDM_DROPIN="/etc/lightdm/lightdm.conf.d/99-songrec-station-kiosk.conf"
SYSTEM_LAUNCHER="/usr/local/bin/songrec-station-kiosk"
SYSTEM_SESSION_LAUNCHER="/usr/local/bin/songrec-station-kiosk-session"
KIOSK_SESSION_FILE="/usr/share/xsessions/songrec-station-kiosk.desktop"
KIOSK_SESSION_NAME="songrec-station-kiosk"
MARKER_START="# BEGIN SongRec Station kiosk"
MARKER_END="# END SongRec Station kiosk"

if [[ ! -f "${LAUNCHER_SOURCE}" ]]; then
  echo "Missing ${LAUNCHER_SOURCE}; copy both kiosk files to the Pi." >&2
  exit 1
fi
if [[ ! -d "${KIOSK_HOME}" ]]; then
  echo "Cannot determine the home directory for ${KIOSK_USER}." >&2
  exit 1
fi
URL_PATTERN='^https?://[A-Za-z0-9._:/?&=%#-]+$'
if [[ ! "${DASHBOARD_URL}" =~ ${URL_PATTERN} ]]; then
  echo "Dashboard URL must be a simple http:// or https:// URL." >&2
  exit 1
fi
DASHBOARD_URL_ESCAPED="$(printf '%q' "${DASHBOARD_URL}")"
LAUNCHER_ESCAPED="$(printf '%q' "${LAUNCHER_DESTINATION}")"

sudo apt-get update
# Openbox is the small piece a bare X11 kiosk still needs: without a window
# manager Chromium's --kiosk fullscreen request cannot be applied and it opens
# at its default, smaller window geometry.
# unclutter-xfixes hides the pointer after a fraction of a second of inactivity
# while preserving a usable mouse for emergency kiosk maintenance.
packages=(lightdm x11-xserver-utils openbox unclutter-xfixes)
if ! command -v chromium >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
  packages+=(chromium)
fi
sudo apt-get install -y "${packages[@]}"

install -d -m 0755 "${KIOSK_HOME}/.local/bin" \
  "${KIOSK_HOME}/.config/labwc" \
  "${KIOSK_HOME}/.config/lxsession/LXDE-pi"
install -m 0755 "${LAUNCHER_SOURCE}" "${LAUNCHER_DESTINATION}"
sudo install -m 0755 "${LAUNCHER_SOURCE}" "${SYSTEM_LAUNCHER}"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# Start a lightweight X11 window manager, then the persistent kiosk browser.'
  printf '%s\n' 'openbox --sm-disable &'
  printf '%s\n' 'if command -v unclutter >/dev/null 2>&1; then'
  printf '%s\n' '  unclutter --timeout 0.2 &'
  printf '%s\n' 'fi'
  printf '%s\n' 'sleep 1'
  printf 'exec %q %q\n' "${SYSTEM_LAUNCHER}" "${DASHBOARD_URL}"
} | sudo tee "${SYSTEM_SESSION_LAUNCHER}" >/dev/null
sudo chmod 0755 "${SYSTEM_SESSION_LAUNCHER}"

install_autostart_block() {
  local file="$1"
  local command="$2"
  touch "${file}"
  sed -i "\\|${MARKER_START}|,\\|${MARKER_END}|d" "${file}"
  {
    printf '\n%s\n' "${MARKER_START}"
    printf '%s\n' "${command}"
    printf '%s\n' "${MARKER_END}"
  } >>"${file}"
}

# Raspberry Pi OS Bookworm/Trixie uses labwc; the LXDE entry keeps older X11
# installations working. Only the active desktop reads its corresponding file.
install_autostart_block "${LABWC_AUTOSTART}" \
  "${LAUNCHER_ESCAPED} ${DASHBOARD_URL_ESCAPED} &"
install_autostart_block "${LXDE_AUTOSTART}" \
  "@${LAUNCHER_ESCAPED} ${DASHBOARD_URL_ESCAPED} &"

sudo chown -R "${KIOSK_USER}:${KIOSK_USER}" \
  "${KIOSK_HOME}/.local/bin/songrec-station-kiosk" \
  "${KIOSK_HOME}/.config/labwc" \
  "${KIOSK_HOME}/.config/lxsession/LXDE-pi"

# Request the normal Raspberry Pi OS graphical-autologin mode too. The
# LightDM drop-in below is authoritative: it avoids B4 selecting the wrong
# account when this installer is run via SSH or with a non-default username.
sudo raspi-config nonint do_boot_behaviour B4

# Register a self-contained X11 session. This is deliberately independent of
# LXDE/labwc: Raspberry Pi OS Lite includes neither desktop, but a kiosk only
# needs Xorg, LightDM, and Chromium. LightDM launches this session as the
# autologin user, and the launcher keeps Chromium alive.
{
  printf '%s\n' '[Desktop Entry]'
  printf '%s\n' 'Name=SongRec Station Kiosk'
  printf '%s\n' 'Comment=Public SongRec dashboard display'
  printf 'Exec=%s\n' "${SYSTEM_SESSION_LAUNCHER}"
  printf '%s\n' 'Type=Application'
} | sudo tee "${KIOSK_SESSION_FILE}" >/dev/null
sudo chmod 0644 "${KIOSK_SESSION_FILE}"
DESKTOP_SESSION="${KIOSK_SESSION_NAME}"

sudo install -d -m 0755 /etc/lightdm/lightdm.conf.d
{
  printf '%s\n' '[Seat:*]'
  printf 'autologin-user=%s\n' "${KIOSK_USER}"
  printf '%s\n' 'autologin-user-timeout=0'
  printf 'autologin-session=%s\n' "${DESKTOP_SESSION}"
} | sudo tee "${LIGHTDM_DROPIN}" >/dev/null
sudo chmod 0644 "${LIGHTDM_DROPIN}"

# LightDM reads /etc/lightdm/lightdm.conf after its drop-in directory. B4 on
# some Raspberry Pi OS releases writes its selected user there, so correct any
# value it left behind as well. The drop-in still covers images without this
# legacy file.
if [[ -f /etc/lightdm/lightdm.conf ]]; then
  sudo sed -i -E "s|^([[:space:]]*autologin-user=).*|\\1${KIOSK_USER}|" \
    /etc/lightdm/lightdm.conf
  sudo sed -i -E 's|^([[:space:]]*autologin-user-timeout=).*|\\10|' \
    /etc/lightdm/lightdm.conf
  sudo sed -i -E "s|^([[:space:]]*autologin-session=).*|\\1${DESKTOP_SESSION}|" \
    /etc/lightdm/lightdm.conf
fi

# Debian/Raspberry Pi OS normally protects LightDM's password-less login with
# PAM groups. raspi-config adds the initial user, but it can miss an account
# selected through an SSH install. Grant the kiosk account the same narrowly
# scoped permission when those groups exist.
for group in autologin nopasswdlogin; do
  if getent group "${group}" >/dev/null; then
    sudo usermod -aG "${group}" "${KIOSK_USER}"
  fi
done
sudo systemctl set-default graphical.target
sudo systemctl enable lightdm.service

echo "Kiosk installed for ${KIOSK_USER}."
echo "Configured LightDM autologin in ${LIGHTDM_DROPIN}."
echo "Granted ${KIOSK_USER} the LightDM autologin permission where required."
echo "Dashboard: ${DASHBOARD_URL}"
echo "Reboot to start the projector display: sudo reboot"
echo "On Raspberry Pi OS Wayland, disable screen blanking in:"
echo "  raspi-config → Display Options → Screen Blanking → No"
