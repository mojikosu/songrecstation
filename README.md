# SongRec turntable station
Transform a Raspberry Pi (3+ or 4) into a music identifying station for vinyl records. Grabs metadata from Shazaam for played records. Hosts a webserver with music fingerprinting result.

This station listens to a turntable through a USB phono preamp, identifies a track with SongRec, and publishes the current result to a local web dashboard.

`install-songrec-station.sh` provisions a Raspberry Pi 3+ running Raspberry Pi OS and creates a `systemd` service that identifies vinyl tracks from a USB phono preamp.

Install from the account that will run the station:

```bash
arecord -l
./install-songrec-station.sh "hw:1,0"
```

Use the exact device string reported for the USB capture device. If it is unknown, omit the argument to try ALSA's `default` device.

The service writes a stable, web-friendly JSON document to `/var/lib/songrec-station/current.json` and an append-only recognition log to `/var/lib/songrec-station/history.ndjson`. A web server should serve or read `current.json`; its `songrec` field intentionally preserves the complete SongRec/Shazam response, so the UI can use artwork, artist, album, genres, links, and other details that upstream returns.

## Calibration

With a record stopped, then playing, view the input level in another terminal:

```bash
arecord -D "hw:1,0" -f S16_LE -c 1 -r 44100 -t raw | \
  python3 -c 'import sys; import math; [print(int(math.sqrt(sum(x*x for x in memoryview(sys.stdin.buffer.read(22050)).cast("h"))/11025))) for _ in iter(int, 1)]'
```

Choose `SILENCE_RMS` in `/etc/songrec-station.env` above the turntable's surface/noise-floor reading but comfortably below quiet music. Then restart:


```bash
sudo systemctl restart songrec-station
journalctl -u songrec-station -f
```

If `44100` is unsupported by the USB device, change `SAMPLE_RATE` to `48000`; verify the hardware capabilities with:

```bash
arecord -D "hw:1,0" --dump-hw-params -f S16_LE -c 1 -r 44100 -t raw /dev/zero
```

Gapless records are the one intentional limitation: a silence-gated system treats a continuous side as one segment. For gapless albums, add a manual “identify now” button to the eventual web UI or move to a more sophisticated novelty/track-change detector; do not switch to unrestricted continuous SongRec polling.

SongRec’s documented CLI offers one-shot `recognize`, continuous `listen`, and JSON/CSV output. This station deliberately uses the one-shot JSON mode on a WAV sample, because JSON keeps nested metadata intact for a richer web page. [SongRec README](https://github.com/marin-m/SongRec#sample-usage) · [current command options](https://man.archlinux.org/man/songrec-recognize.1.en)

## Station configuration

The runtime configuration lives in `/etc/songrec-station.env`. Restart the station after changing a value:

```bash
sudo systemctl restart songrec-station
```

```ini
# RMS threshold (0-32767). Raise it if surface noise starts captures; lower it if music is missed.
SILENCE_RMS=750
START_AUDIO_SECONDS=3
END_SILENCE_SECONDS=4
SONGREC_TIMEOUT_SECONDS=90
DATA_DIR=/var/lib/songrec-station
SONGREC_BIN=/opt/songrec-station/songrec
SONGREC_DEVICE=alsa:hw:CARD=CODEC,DEV=0
SONGREC_REQUEST_INTERVAL=8
```

### `SILENCE_RMS=750`

The audio-level threshold used to distinguish music from silence and turntable surface noise. RMS values range from `0` to `32767`.

- Raise it if clicks, rumble, or surface noise falsely trigger a recognition.
- Lower it if quiet music or softly mastered records are missed.

`750` is a moderately conservative starting point.

### `START_AUDIO_SECONDS=3`

Audio must stay above `SILENCE_RMS` continuously for three seconds before the station asks SongRec to identify the track. This prevents brief pops and handling noise from producing a request.

### `END_SILENCE_SECONDS=4`

After an identification, the input must stay below `SILENCE_RMS` for four continuous seconds before the station considers the track complete and permits a new identification. This ensures only one request is made for each audible track segment.

### `SONGREC_TIMEOUT_SECONDS=90`

The safety limit for one SongRec run. When no result returns within 90 seconds, the station records a timeout and resumes its normal listening state.

### `DATA_DIR=/var/lib/songrec-station`

The station’s runtime-data directory:

- `current.json` contains the latest status or identified track. The dashboard polls this file through its local API.
- `history.ndjson` contains one JSON object per identification attempt.

### `SONGREC_BIN=/opt/songrec-station/songrec`

The absolute path to the SongRec executable used by the station service.

### `SONGREC_DEVICE=alsa:hw:CARD=CODEC,DEV=0`

The input-device identifier understood by SongRec. It is intentionally different from the ALSA `arecord` notation such as `hw:1,0`.

List the valid SongRec device IDs with:

```bash
/opt/songrec-station/songrec recognize --list-devices
```

### `SONGREC_REQUEST_INTERVAL=8`

How long SongRec listens before submitting a fingerprint for recognition.

- Lower values identify tracks faster but can reduce matching reliability, especially with quiet, worn, or noisy vinyl.
- Higher values are slower but provide more fingerprint data and are generally more robust.

Eight seconds is a quality-oriented setting.

## Useful checks

```bash
sudo systemctl status songrec-station
journalctl -u songrec-station -f
cat /var/lib/songrec-station/current.json
```

The dashboard service is available after installation at `http://<pi-ip-address>:8080`.
