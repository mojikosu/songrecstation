#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  STATION_USER="$(systemctl show --property=User --value songrec-station.service)"
else
  STATION_USER="${SUDO_USER:-$(id -un)}"
fi
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/songrec-web"
UNIT_FILE="/etc/systemd/system/songrec-web.service"

if [[ -z "${STATION_USER}" ]]; then echo "Cannot find the SongRec service account." >&2; exit 1; fi
# Used once per newly recognised cover to extract a small album-art palette.
if ! /usr/bin/python3 -c 'from PIL import Image' >/dev/null 2>&1; then
  sudo apt-get install -y python3-pil
fi
sudo install -d -o "${STATION_USER}" -g "${STATION_USER}" -m 0755 "${INSTALL_DIR}"
sudo install -o "${STATION_USER}" -g "${STATION_USER}" -m 0644 \
  "${SOURCE_DIR}/app.py" "${SOURCE_DIR}/index.html" "${SOURCE_DIR}/app.css" "${SOURCE_DIR}/lyrics.css" "${SOURCE_DIR}/app.js" "${INSTALL_DIR}/"
sudo tee "${UNIT_FILE}" >/dev/null <<EOF
[Unit]
Description=SongRec Station web dashboard
After=network-online.target songrec-station.service
Wants=network-online.target

[Service]
Type=simple
User=${STATION_USER}
Group=${STATION_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=SONGREC_WEB_ROOT=${INSTALL_DIR}
Environment=SONGREC_DATA_ROOT=/var/lib/songrec-station
Environment=SONGREC_WEB_PORT=8080
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadOnlyPaths=/var/lib/songrec-station

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable songrec-web.service
# enable --now does not replace an already-running Python process. Restart so
# an existing dashboard immediately begins serving the freshly copied app.py.
sudo systemctl restart songrec-web.service
sudo systemctl --no-pager --full status songrec-web.service
echo "Dashboard running at: http://$(hostname -I | awk '{print $1}'):8080"
echo "Raw SongRec JSON:     http://$(hostname -I | awk '{print $1}'):8080/api/songrec.json"
echo "Home Assistant JSON:  http://$(hostname -I | awk '{print $1}'):8080/api/home-assistant"
