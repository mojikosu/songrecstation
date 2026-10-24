#!/usr/bin/env python3
"""Run a SongRec turntable station in silence-gated or continuous mode."""
import json
import os
import selectors
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

ENV_PATH = "/etc/songrec-station.env"


def env_file(path):
    values = {}
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    except FileNotFoundError:
        pass
    return values


CONFIG = env_file(ENV_PATH)
DETECTION_MODE = CONFIG.get("DETECTION_MODE", "silence").lower()
DEVICE = CONFIG.get("AUDIO_DEVICE", "default")
SONGREC_DEVICE = CONFIG.get("SONGREC_DEVICE", "")
SONGREC_REQUEST_INTERVAL = CONFIG.get("SONGREC_REQUEST_INTERVAL", "5")
CONTINUOUS_REQUEST_INTERVAL = CONFIG.get("CONTINUOUS_REQUEST_INTERVAL", "8")
RATE = int(CONFIG.get("SAMPLE_RATE", "44100"))
CHANNELS = int(CONFIG.get("CHANNELS", "1"))
SILENCE_RMS = int(CONFIG.get("SILENCE_RMS", "350"))
CHUNK_SECONDS = float(CONFIG.get("CHUNK_SECONDS", "0.25"))
START_AUDIO_SECONDS = float(CONFIG.get("START_AUDIO_SECONDS", "3"))
END_SILENCE_SECONDS = float(CONFIG.get("END_SILENCE_SECONDS", "4"))
SONGREC_TIMEOUT_SECONDS = int(CONFIG.get("SONGREC_TIMEOUT_SECONDS", "90"))
CHANGE_CONFIRM_SECONDS = max(0.0, float(CONFIG.get("CHANGE_CONFIRM_SECONDS", "12")))
DATA_DIR = Path(CONFIG.get("DATA_DIR", "/var/lib/songrec-station"))
SONGREC = CONFIG.get("SONGREC_BIN", "/opt/songrec-station/songrec")
FRAME_BYTES = max(2 * CHANNELS, int(RATE * CHUNK_SECONDS) * 2 * CHANNELS)


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def rms_s16le(data):
    """Return RMS for little-endian signed 16-bit PCM without extra packages."""
    samples = memoryview(data).cast("h")
    if not samples:
        return 0
    return int((sum(sample * sample for sample in samples) / len(samples)) ** 0.5)


def publish(payload):
    """Atomically replace the document polled by the web application."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    payload["updated_at"] = now()
    output = DATA_DIR / "current.json"
    temp = DATA_DIR / ".current.json.tmp"
    temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, output)


def append_history(payload):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with (DATA_DIR / "history.ndjson").open("a", encoding="utf-8") as output:
        output.write(json.dumps(payload, ensure_ascii=False) + "\n")


def read_current():
    try:
        return json.loads((DATA_DIR / "current.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}


def track_identity(songrec_response):
    """Return a stable track ID; fall back for malformed/incomplete replies."""
    if not isinstance(songrec_response, dict):
        return ""
    track = songrec_response.get("track")
    if not isinstance(track, dict):
        return ""
    key = track.get("key")
    if isinstance(key, str) and key:
        return f"key:{key}"
    title = track.get("title", "")
    artist = track.get("subtitle", "")
    if isinstance(title, str) and isinstance(artist, str) and (title or artist):
        return f"name:{artist.casefold()}::{title.casefold()}"
    return ""


def identify(started_at):
    """Run one direct SongRec microphone recognition against the USB device."""
    publish({
        "state": "identifying",
        "detection_mode": "silence",
        "sample_started_at": started_at,
        "message": "Identifying this track...",
    })

    try:
        command = [SONGREC, "recognize", "--json", "--request-interval", SONGREC_REQUEST_INTERVAL]
        if SONGREC_DEVICE:
            command.extend(["--audio-device", SONGREC_DEVICE])
        result = subprocess.run(
            command, capture_output=True, text=True,
            timeout=SONGREC_TIMEOUT_SECONDS, check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "state": "not_found", "detection_mode": "silence",
            "sample_started_at": started_at, "error": "SongRec timed out.",
        }

    stdout = result.stdout.strip()
    if result.returncode != 0:
        return {
            "state": "not_found", "detection_mode": "silence",
            "sample_started_at": started_at,
            "error": result.stderr.strip() or "SongRec failed.",
        }
    try:
        songrec_response = json.loads(stdout)
    except json.JSONDecodeError:
        return {
            "state": "not_found", "detection_mode": "silence",
            "sample_started_at": started_at, "error": "No recognized song.",
            "songrec_stdout": stdout,
        }
    return {
        "state": "identified", "detection_mode": "silence",
        "sample_started_at": started_at, "songrec": songrec_response,
    }


def terminate_process(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run_silence_gated():
    """Preserve the original mode: identify once, then require a silent gap."""
    if shutil.which("arecord") is None:
        raise RuntimeError("arecord is not installed or not on PATH.")

    publish({
        "state": "waiting_for_audio", "detection_mode": "silence",
        "message": "Waiting for a record...",
    })
    command = [
        "arecord", "-q", "-D", DEVICE, "-f", "S16_LE", "-c", str(CHANNELS),
        "-r", str(RATE), "-t", "raw",
    ]

    def start_recorder():
        return subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)

    recorder = start_recorder()

    def stop(*_):
        terminate_process(recorder)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    active_for = 0.0
    silent_for = 0.0
    waiting_for_gap = False

    while True:
        data = recorder.stdout.read(FRAME_BYTES)
        if not data:
            stderr = recorder.stderr.read().decode(errors="replace")
            raise RuntimeError("arecord stopped: " + stderr)
        is_audio = rms_s16le(data) >= SILENCE_RMS
        duration = len(data) / (RATE * CHANNELS * 2)

        if waiting_for_gap:
            silent_for = silent_for + duration if not is_audio else 0.0
            if silent_for >= END_SILENCE_SECONDS:
                waiting_for_gap = False
                active_for = 0.0
                silent_for = 0.0
                publish({
                    "state": "waiting_for_audio", "detection_mode": "silence",
                    "message": "Waiting for the next record...",
                })
            continue

        active_for = active_for + duration if is_audio else 0.0
        if active_for >= START_AUDIO_SECONDS:
            started_at = now()
            # arecord owns ALSA while detecting silence. Release it before
            # SongRec opens that same device for its one-shot capture.
            terminate_process(recorder)
            outcome = identify(started_at)
            publish(outcome)
            append_history(outcome)
            waiting_for_gap = True
            silent_for = 0.0
            active_for = 0.0
            recorder = start_recorder()


def json_values_from_stream(buffer):
    """Decode complete JSON objects from a stdout stream without line assumptions."""
    decoder = json.JSONDecoder()
    values = []
    while buffer:
        stripped = buffer.lstrip()
        if not stripped:
            return "", values
        try:
            value, end = decoder.raw_decode(stripped)
        except json.JSONDecodeError:
            return stripped, values
        values.append(value)
        buffer = stripped[end:]
    return "", values


def run_continuous():
    """Use SongRec's persistent listener and publish confirmed track changes."""
    command = [
        SONGREC, "listen", "--json", "--disable-mpris",
        "--request-interval", CONTINUOUS_REQUEST_INTERVAL,
    ]
    if SONGREC_DEVICE:
        command.extend(["--audio-device", SONGREC_DEVICE])

    # Preserve the last confirmed ID across service restarts, so a restart does
    # not append the currently playing song to history a second time.
    current_identity = track_identity(read_current().get("songrec"))
    publish({
        "state": "waiting_for_audio", "detection_mode": "continuous",
        "message": "Listening continuously for track changes...",
    })
    listener = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=None, bufsize=0)

    def stop(*_):
        terminate_process(listener)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    candidate_identity = ""
    candidate_response = None
    candidate_started = 0.0
    buffer = ""
    selector = selectors.DefaultSelector()
    selector.register(listener.stdout, selectors.EVENT_READ)

    try:
        while True:
            # SongRec's listen command prints only when its own track key
            # changes. Hold a new key briefly; a subsequent result returning
            # to the old track cancels it during a DJ crossfade.
            timeout = None
            if candidate_response is not None:
                timeout = max(0.0, candidate_started + CHANGE_CONFIRM_SECONDS - time.monotonic())
            ready = selector.select(timeout)
            if not ready:
                outcome = {
                    "state": "identified", "detection_mode": "continuous",
                    "sample_started_at": now(), "songrec": candidate_response,
                    "change_confirmed_after_seconds": CHANGE_CONFIRM_SECONDS,
                }
                publish(outcome)
                append_history(outcome)
                current_identity = candidate_identity
                candidate_identity = ""
                candidate_response = None
                continue

            # bufsize=0 gives a FileIO pipe: read() returns the data currently
            # available instead of waiting to fill the requested size.
            chunk = listener.stdout.read(4096)
            if not chunk:
                return_code = listener.wait()
                raise RuntimeError(f"SongRec continuous listener stopped (exit {return_code}).")
            buffer += chunk.decode("utf-8", errors="replace")
            buffer, responses = json_values_from_stream(buffer)
            if len(buffer) > 1024 * 1024:
                print("Discarding oversized non-JSON SongRec stdout buffer.")
                buffer = ""

            for response in responses:
                identity = track_identity(response)
                if not identity:
                    continue
                if identity == current_identity:
                    candidate_identity = ""
                    candidate_response = None
                    continue

                seen_at = time.monotonic()
                candidate_identity = identity
                candidate_response = response
                candidate_started = seen_at
    finally:
        selector.close()
        terminate_process(listener)


def main():
    if not os.path.exists(SONGREC):
        raise RuntimeError(f"SongRec binary not found: {SONGREC}")
    if DETECTION_MODE == "silence":
        run_silence_gated()
    elif DETECTION_MODE == "continuous":
        run_continuous()
    else:
        raise RuntimeError("DETECTION_MODE must be 'silence' or 'continuous'.")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        publish({"state": "error", "detection_mode": DETECTION_MODE, "message": str(error)})
        raise
