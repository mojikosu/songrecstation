# Tasogare-kun no Station

This station listens to a turntable through a USB phono preamp, identifies a track with SongRec, and publishes the current result to a local web dashboard.

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
