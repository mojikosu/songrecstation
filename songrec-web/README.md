# Tasogare-kun no Station web API

The web service reads `/var/lib/songrec-station/current.json` on every HTTP
request. The station worker replaces that file atomically, so callers only see
a complete old or new document, never a partially written one. API responses
send `Cache-Control: no-store` and an `X-SongRec-Revision` header containing
the update timestamp.

| Endpoint | Purpose |
| --- | --- |
| `/api/current` | The complete station document: state, timestamps, and the embedded SongRec response. |
| `/api/songrec.json` | The unmodified JSON emitted by `songrec recognize --json`. It is `{}` until a track is identified. |
| `/api/home-assistant` | Small, stable Home Assistant payload with metadata and a high-resolution artwork URL. |
| `/api/history` | The latest 24 station events, newest first. |

For example, with the Pi at `192.168.39.18`:

```sh
curl http://192.168.39.18:8080/api/songrec.json
curl http://192.168.39.18:8080/api/home-assistant
```

`artwork_url` is converted to the `1200x1200cc.jpg` artwork variant for LED
colour extraction. `revision` is the `updated_at` timestamp written by the
station worker. It changes on every station update, including a repeat
identification of the same song.

`palette_rgb`, `palette_hex`, and `palette_hsbk` are up to five prominent
colors sampled once from each cover. `palette_hsbk` is ready for the local LIFX
integration's `lifx.paint_theme` action.

## Home Assistant

Copy the `rest:` section from `home-assistant.example.yaml` into Home
Assistant's `configuration.yaml` and replace the example IP address. The main
sensor uses `revision` as its state so Home Assistant raises a state-change
event for every result; title, artist, album, Shazam URL, and `artwork_url` are
attributes. Its `picture` comes directly from the 1200px artwork URL.

`scan_interval: 1` makes Home Assistant check each second, which is the
fastest dependable behaviour supported by a polling REST sensor. HTTP polling
cannot be instant; a push transport such as MQTT would be needed if sub-second
updates ever matter. The raw sensor is optional because very large SongRec
responses can be inconvenient as Home Assistant attributes.

### Dashboard card

Add a **Manual** card to a Home Assistant dashboard and paste the contents of
`home-assistant-dashboard-card.yaml`. It displays the sensor's dynamic
`entity_picture` (the album artwork) as a square. Tapping the artwork opens the
normal **More info** panel, which lists the title, artist, album, genre, label,
Shazam link, and the other REST-sensor attributes. Change `sensor.lounge_tune`
in the card YAML if Home Assistant assigned your sensor a different entity ID.

### LIFX Beam album-art automation

`home-assistant-lifx-album-art.yaml` is a complete automation which paints the
cover palette across the individual zones of a LIFX Beam. Replace
`light.lounge_beam` with the Beam's light entity, then paste the file into a
new Home Assistant automation in YAML mode. It stops a running effect first,
then sends the palette using one local-network command. Set `power_on: false`
if a new song should not turn on a Beam that somebody has turned off.

## Updating an existing dashboard

Copy the updated web-folder files to the Pi and run
`./install-songrec-web.sh` again. The installer restarts `songrec-web.service`
after copying `app.py`; this is necessary because an already-running Python
process otherwise continues serving the prior routes. Verify the installed
service with:

```sh
curl -i http://127.0.0.1:8080/api/songrec.json
sudo systemctl status songrec-web.service
```
