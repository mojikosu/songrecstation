#!/usr/bin/env python3
"""Small, dependency-free web server for the SongRec station dashboard."""
import colorsys
import io
import json
import mimetypes
import os
import re
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, urlopen

WEB_ROOT = Path(os.environ.get("SONGREC_WEB_ROOT", "/opt/songrec-web"))
DATA_ROOT = Path(os.environ.get("SONGREC_DATA_ROOT", "/var/lib/songrec-station"))
HOST = os.environ.get("SONGREC_WEB_HOST", "0.0.0.0")
PORT = int(os.environ.get("SONGREC_WEB_PORT", "8080"))
PALETTE_CACHE = {}
PALETTE_LOCK = threading.Lock()
MAX_ARTWORK_BYTES = 5 * 1024 * 1024


def read_json(path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return fallback


def cover_1200(url):
    """Request the high-resolution Apple artwork variant when available."""
    if not isinstance(url, str):
        return ""
    return re.sub(r"/\d+x\d+cc\.jpg(?=\?|$)", "/1200x1200cc.jpg", url)


def album_palette(url):
    """Return prominent cover colors as RGB and LIFX HSBK palettes.

    The result is cached by artwork URL, so a cover is downloaded and analysed
    only once. Pillow is imported here so the rest of the dashboard still works
    while the installer is fetching its optional image-processing dependency.
    """
    if not urlparse(url).scheme == "https":
        return [], [], []
    with PALETTE_LOCK:
        cached = PALETTE_CACHE.get(url)
    if cached is not None:
        return cached

    try:
        from PIL import Image

        request = Request(url, headers={"User-Agent": "SongRecStation/1.0"})
        with urlopen(request, timeout=8) as response:
            content = response.read(MAX_ARTWORK_BYTES + 1)
        if len(content) > MAX_ARTWORK_BYTES:
            raise ValueError("Artwork image exceeds the download limit")

        with Image.open(io.BytesIO(content)) as image:
            image = image.convert("RGB")
            image.thumbnail((96, 96))
            quantized = image.quantize(colors=5)
            palette = quantized.getpalette()
            counted = sorted(quantized.getcolors() or [], reverse=True)

        candidates = []
        for _, index in counted:
            color = tuple(palette[index * 3:index * 3 + 3])
            if len(color) == 3 and list(color) not in candidates:
                candidates.append(list(color))

        # JPEG quantization often produces several nearly-identical shades.
        # Prefer a visibly varied five-colour palette for the Beam.
        rgb = []
        for color in candidates:
            if all(sum((part - other) ** 2 for part, other in zip(color, chosen)) >= 40 ** 2
                   for chosen in rgb):
                rgb.append(color)
        if len(rgb) < 2 and len(candidates) > 1:
            rgb.append(candidates[1])

        # LIFX's paint_theme uses [hue, saturation, brightness, Kelvin].
        hsbk = []
        for red, green, blue in rgb:
            hue, saturation, brightness = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)
            hsbk.append([round(hue * 360), round(saturation * 100),
                         max(15, round(brightness * 100)), 3500])
        result = (rgb, [f"#{red:02x}{green:02x}{blue:02x}" for red, green, blue in rgb], hsbk)
    except Exception as error:
        print(f"Could not extract artwork palette: {error}")
        result = ([], [], [])

    with PALETTE_LOCK:
        # Keep this intentionally small on the Pi; entries are only metadata.
        if len(PALETTE_CACHE) >= 64:
            PALETTE_CACHE.pop(next(iter(PALETTE_CACHE)))
        PALETTE_CACHE[url] = result
    return result


def station_payload():
    return read_json(DATA_ROOT / "current.json", {
        "state": "waiting_for_audio", "message": "Waiting for a record..."
    })


def home_assistant_payload(current):
    """Return stable, small fields suited to a Home Assistant REST sensor."""
    songrec = current.get("songrec")
    if not isinstance(songrec, dict):
        songrec = {}
    track = songrec.get("track")
    if not isinstance(track, dict):
        track = {}

    metadata = {}
    for section in track.get("sections", []):
        if not isinstance(section, dict):
            continue
        for item in section.get("metadata", []):
            if not isinstance(item, dict):
                continue
            label, value = item.get("title"), item.get("text")
            if isinstance(label, str) and isinstance(value, str):
                metadata[label.strip().lower()] = value

    images = track.get("images")
    if not isinstance(images, dict):
        images = {}
    artwork = images.get("coverarthq") or images.get("coverart") or ""
    artwork_url = cover_1200(artwork)
    palette_rgb, palette_hex, palette_hsbk = album_palette(artwork_url)

    return {
        "state": current.get("state", "waiting_for_audio"),
        # This is deliberately separate from the track title. It changes for
        # every write to current.json, including repeated identification.
        "revision": current.get("updated_at", ""),
        "updated_at": current.get("updated_at", ""),
        "sample_started_at": current.get("sample_started_at", ""),
        "message": current.get("message", ""),
        "error": current.get("error", ""),
        "title": track.get("title", ""),
        "artist": track.get("subtitle", ""),
        "album": metadata.get("album", ""),
        "genre": metadata.get("genre", metadata.get("genres", "")),
        "released": metadata.get("released", ""),
        "label": metadata.get("label", ""),
        "track_key": track.get("key", ""),
        "shazam_url": track.get("url", ""),
        "artwork_url": artwork_url,
        "palette_rgb": palette_rgb,
        "palette_hex": palette_hex,
        "palette_hsbk": palette_hsbk,
        "raw_songrec_path": "/api/songrec.json",
    }


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "SongRecStation/1.0"

    def log_message(self, format, *args):
        print(f"{self.address_string()} — {format % args}")

    def send_json(self, payload, status=HTTPStatus.OK, revision=""):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if revision:
            self.send_header("X-SongRec-Revision", revision)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def send_static(self, filename):
        path = WEB_ROOT / filename
        if not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = path.read_bytes()
        mime, _ = mimetypes.guess_type(str(path))
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", (mime or "application/octet-stream") + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/current":
            current = station_payload()
            self.send_json(current, revision=current.get("updated_at", ""))
        elif path == "/api/songrec.json":
            # Exact JSON written by `songrec recognize --json`, without the
            # station wrapper. It is useful for custom Home Assistant use.
            current = station_payload()
            songrec = current.get("songrec", {})
            self.send_json(songrec if isinstance(songrec, dict) else {},
                           revision=current.get("updated_at", ""))
        elif path == "/api/home-assistant":
            current = station_payload()
            payload = home_assistant_payload(current)
            self.send_json(payload, revision=payload["revision"])
        elif path == "/api/history":
            records = []
            try:
                for line in (DATA_ROOT / "history.ndjson").read_text(encoding="utf-8").splitlines()[-24:]:
                    records.append(json.loads(line))
            except (FileNotFoundError, OSError, json.JSONDecodeError):
                pass
            self.send_json(list(reversed(records)))
        elif path in ("/", "/index.html"):
            self.send_static("index.html")
        elif path in ("/app.css", "/lyrics.css", "/app.js"):
            self.send_static(path.lstrip("/"))
        else:
            self.send_error(HTTPStatus.NOT_FOUND)


if __name__ == "__main__":
    print(f"SongRec dashboard listening at http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), DashboardHandler).serve_forever()
