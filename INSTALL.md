# Installing SongRec Station

Two small scripts turn a freshly flashed Raspberry Pi into a vinyl track-recognition station. One command downloads the repository and opens a menu where you choose which parts to install.

## Quick start

On a freshly flashed Raspberry Pi OS (a 3+ or 4), logged in as your normal user (not root), with the USB phono preamp plugged in:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mojikosu/songrecstation/main/bootstrap.sh)
```

Use `bash <(...)` rather than `curl ... | bash`. The menus need your keyboard, and the process substitution leaves it available.

Unattended install of everything, with the audio device and detection mode chosen up front:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mojikosu/songrecstation/main/bootstrap.sh) \
  --all --audio-device "hw:1,0" --mode silence --yes
```

> **Heads-up:** the core component compiles SongRec from source. On a Raspberry Pi 3+ this takes a long time. Plan for a while, not minutes.

## What the scripts do

### `bootstrap.sh`

The entry point you run on a blank system.

1. Refuses to run as root (it uses `sudo` where needed).
2. Installs `git`, `whiptail`, `ca-certificates` and `curl`.
3. Clones this repository to `~/songrecstation`. If that folder already exists, it fetches and resets it to the latest `main`. **Local edits inside that clone are discarded.**
4. Hands over to `install.sh`, passing along any arguments you gave.

Environment overrides:

| Variable | Default | Purpose |
|---|---|---|
| `REPO_URL` | `https://github.com/mojikosu/songrecstation.git` | Repository to clone (useful for forks) |
| `REPO_BRANCH` | `main` | Branch to install |
| `TARGET_DIR` | `~/songrecstation` | Where the clone lives |

### `install.sh`

The modular installer with the component picker. It can also be run directly from a clone: `./install.sh`.

| Option | Description |
|---|---|
| *(none)* | Interactive: component checklist, audio device menu, detection mode menu |
| `--all` | Install every component |
| `--components core,web,kiosk` | Install a comma-separated selection |
| `--audio-device DEVICE` | Capture device, e.g. `hw:1,0`. Skips the device menu |
| `--mode silence\|continuous` | Detection mode (see below). Skips the mode menu |
| `--set-mode silence\|continuous` | Only switch the mode on an existing install, then exit |
| `--yes`, `-y` | No confirmation prompts. Picks the first audio device and the `silence` mode unless given |
| `--list` | Show the available components |
| `-h`, `--help` | Show usage |

#### Components

| Component | Installs | Runs the script |
|---|---|---|
| `core` | SongRec (built from source), the audio worker and the `songrec-station` systemd service | `install-songrec-station.sh` |
| `web` | Web dashboard on port 8080 and the `songrec-web` systemd service | `songrec-web/install-songrec-web.sh` |
| `kiosk` | Chromium kiosk that shows the dashboard on the HDMI output (for example, a projector) | `songrec-web-kiosk/install-songrec-kiosk.sh` |

Components always run in the order **core → web → kiosk**, because the kiosk displays the dashboard and the dashboard reads the data the core writes. In the interactive menu, `core` and `web` are pre-selected and `kiosk` is not.

#### What happens during a run

1. Parses options and, if no components were given, shows the checklist.
2. If `core` is selected, picks the audio device and the detection mode.
3. Shows a summary and asks for confirmation (unless `--yes`).
4. Runs the selected component installers in order.
5. Applies the chosen audio device and detection mode to `/etc/songrec-station.env` and restarts the station service.
6. Offers a reboot. One is recommended after `core` (onboard audio is disabled) and after `kiosk` (graphical autologin).

The script exits with a non-zero status if any component failed, and names the failed components.

### Component installers

| Script | Notes |
|---|---|
| `install-songrec-station.sh` | Compiles SongRec headless with a temporary 2 GiB swap file (removed afterwards), disables the Pi's onboard audio so the USB device is always used, installs the worker to `/opt/songrec-station`, writes `/etc/songrec-station.env` and enables the `songrec-station` service. Needs at least 4 GiB free for the build. Tunable with `BUILD_JOBS` (1–4, default 1) and `BUILD_SWAP_MIB`. |
| `songrec-web/install-songrec-web.sh` | Copies the dashboard to `/opt/songrec-web`, installs `python3-pil` if missing, and enables the `songrec-web` service on port 8080. |
| `songrec-web-kiosk/install-songrec-kiosk.sh` | Installs LightDM, Openbox, `unclutter-xfixes` and Chromium, registers a dedicated kiosk X11 session, and sets up autologin for the current user. Optional argument: dashboard URL (default `http://127.0.0.1:8080/`). |
| `songrec-web-kiosk/songrec-kiosk-launcher.sh` | Started by the kiosk session. Disables screen blanking, selects a single HDMI output, and restarts Chromium if it exits. |
| `songrec-station-worker.py` | The recognition worker run by the `songrec-station` service. |

## Choosing the audio device

`install.sh` reads `arecord -l` and lets you pick the USB capture device from a menu. Devices are stored **by card name**, for example `hw:CARD=CODEC,DEV=0`, not by number (`hw:1,0`).

This matters because the core installer disables the Pi's onboard audio. After the reboot, the USB card can change from number 1 to number 0, but its name stays the same. If you pass `--audio-device hw:1,0`, the script converts it to the card-name form automatically. The same device is also written to `SONGREC_DEVICE` (as `alsa:hw:CARD=...`), which SongRec uses.

## Detection modes

| Mode | How it works | Best for |
|---|---|---|
| `silence` (default) | Waits for music, makes one SongRec lookup, then waits for a silent gap before the next one | Normal records with gaps between tracks |
| `continuous` | Keeps SongRec listening and publishes a new track once a change is confirmed | Gapless albums and DJ sessions |

Notes on `continuous`:

- It does not use a silence gate, so audio is sent for recognition all the time, even when nothing is playing, and the last track stays displayed after the record stops.
- `CONTINUOUS_REQUEST_INTERVAL` (default `8`) sets how often SongRec samples audio.
- `CHANGE_CONFIRM_SECONDS` (default `12`) holds a newly detected track for that many seconds. If the previous track returns in that time (for example, during a crossfade), the change is cancelled.
- The silence settings (`SILENCE_RMS`, `START_AUDIO_SECONDS`, `END_SILENCE_SECONDS`) are ignored.

Switch modes at any time without reinstalling:

```bash
cd ~/songrecstation
./install.sh --set-mode continuous   # or: silence
```

## Configuration

Runtime settings live in `/etc/songrec-station.env`. Restart the service after editing:

```bash
sudo systemctl restart songrec-station
```

See [README.md](README.md) for the meaning of each setting and how to calibrate `SILENCE_RMS`.

Kiosk launcher options (environment variables read by the launcher):

| Variable | Default | Purpose |
|---|---|---|
| `SONGREC_KIOSK_START_DELAY` | `12` | Seconds to wait before starting Chromium |
| `SONGREC_KIOSK_OUTPUT` | auto (primary or first HDMI) | Force a specific output, e.g. `HDMI-1` |

## Endpoints

Once `web` is installed, the dashboard is at `http://<pi-ip-address>:8080`.

| Path | Content |
|---|---|
| `/` | Dashboard |
| `/api/songrec.json` | Raw SongRec JSON |
| `/api/home-assistant` | JSON for Home Assistant |

## Useful checks

```bash
sudo systemctl status songrec-station
sudo systemctl status songrec-web
journalctl -u songrec-station -f
cat /var/lib/songrec-station/current.json
cat /etc/songrec-station.env
arecord -l
```

## Troubleshooting

| Symptom | Things to check |
|---|---|
| Station shows an error or never leaves "waiting" | `journalctl -u songrec-station -f`; confirm the device with `arecord -l` and that `AUDIO_DEVICE` in `/etc/songrec-station.env` matches |
| Capture device stopped working after the first reboot | The device should be stored as `hw:CARD=<name>,DEV=<n>`. A numeric `hw:1,0` can break once onboard audio is disabled |
| Continuous mode fails immediately | Check `journalctl -u songrec-station` and `/opt/songrec-station/songrec listen --help` to confirm the options the worker passes are supported by your SongRec build |
| Dashboard does not start | Make sure `/var/lib/songrec-station` exists (`core` creates it; `install.sh` also creates it for a web-only install) |
| Projector stays on the desktop or shows a blank screen | Reboot after installing the kiosk; see `~/.local/state/songrec-station-kiosk/xrandr.log` for the detected outputs |
| Wrong HDMI output used | Set `SONGREC_KIOSK_OUTPUT` (for example `HDMI-1`) |

## Notes

- Run the scripts as a normal user with `sudo` access, not as root. On Raspberry Pi OS the default user has passwordless sudo, so the long build will not stall on a password prompt.
- This code was largely created with AI assistance and then reviewed and fine-tuned by a human. Read the scripts before running them on a system you care about.
