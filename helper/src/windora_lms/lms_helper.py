"""Localhost HTTP service the LMS Perl plugin calls.

Binds 127.0.0.1 only by default — never expose it to the network. It holds your
Pandora credentials and an authenticated session, and serves the small set of
queries the LMS plugin needs to drive playback.

The plugin's protocol handler resolves ONE fresh track per song via
`/station/<token>/next` right before that song plays, so Pandora's short-lived
CDN URLs never go stale in a pre-filled LMS playlist.

Endpoints (all JSON):

    POST /auth
        Body: {"email": "...", "password": "..."}
        -> {"ok": true} on success, {"ok": false, "error": "..."} on failure
        Credentials are persisted to $WINDORA_CONFIG_DIR/credentials.json (0600).

    GET  /status
        -> {"logged_in": bool, "user_id": str|null, "station_count": int}

    GET  /stations
        -> [{"id": str, "token": str, "name": str, "is_quickmix": bool}, ...]
        -> 503 if not logged in

    GET  /station/<token>/next
        -> {title, artist, album, audio_url, bitrate_kbps, duration_s,
            is_ad, album_art_url, track_token, station_token}
        -> 503 if not logged in, 502 on upstream Pandora error

    POST /feedback   Body: {"track_token": "...", "is_positive": bool} -> {"ok": true}
    POST /sleep      Body: {"track_token": "..."}                      -> {"ok": true}

Ads are filtered out (they carry no audioUrl and would just 404 the player).

Run as a systemd unit; see scripts/windora-lms-helper.service.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import stat
import sys
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlparse

from windora_lms.pandora.client import AuthError, PandoraClient, PandoraError
from windora_lms.pandora.models import Track


log = logging.getLogger("windora.lms_helper")


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 9123

CONFIG_DIR = Path(os.environ.get("WINDORA_CONFIG_DIR")
                  or Path.home() / ".config" / "windora-lms")
CREDENTIALS_FILE = CONFIG_DIR / "credentials.json"
PORT_FILE = CONFIG_DIR / "lms-helper.port"
LOG_FILE = CONFIG_DIR / "lms-helper.log"


# ----- credential / config persistence ------------------------------------


def _load_credentials() -> Optional[dict]:
    if not CREDENTIALS_FILE.exists():
        return None
    try:
        return json.loads(CREDENTIALS_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        log.warning("Could not read credentials file: %s", e)
        return None


def _save_credentials(email: str, password: str) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CREDENTIALS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"email": email, "password": password}),
                   encoding="utf-8")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    os.replace(tmp, CREDENTIALS_FILE)


# ----- session: one authenticated client + per-station playlist cache -----


class Session:
    """Holds the authed PandoraClient and a small per-station track cache.

    Pandora's station.getPlaylist returns a handful of tracks at once; we hand
    them out one at a time and refetch when the cache runs low. Each track is
    consumed (and streamed) right after it's pulled, so its CDN URL is fresh.
    """

    LOW_WATER = 1       # refill when a station's cache drops to this size
    REFILL_TARGET = 4   # Pandora hands back ~4 per getPlaylist call

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._client: Optional[PandoraClient] = None
        self._email: Optional[str] = None
        self._user_id: Optional[str] = None
        self._queues: dict[str, list[Track]] = {}  # station_token -> [Track]

    # --- auth --------------------------------------------------------------

    def login(self, email: str, password: str) -> None:
        with self._lock:
            client = PandoraClient()
            client.login(email, password)
            self._client = client
            self._email = email
            self._user_id = client.user_id
            self._queues.clear()
            log.info("Logged in as %s (user_id=%s)", email, self._user_id)

    def try_resume_from_disk(self) -> bool:
        creds = _load_credentials()
        if not creds:
            return False
        try:
            self.login(creds["email"], creds["password"])
            return True
        except (AuthError, PandoraError) as e:
            log.warning("Saved credentials no longer work: %s", e)
            return False

    def is_logged_in(self) -> bool:
        return self._client is not None

    def status(self) -> dict:
        return {
            "logged_in": self.is_logged_in(),
            "user_id": self._user_id,
            "station_count": len(self._queues) if self.is_logged_in() else 0,
        }

    # --- stations ----------------------------------------------------------

    def list_stations(self) -> list[dict]:
        with self._lock:
            self._require_client()
            try:
                stations = self._client.get_stations()
            except AuthError:
                self._reauth()
                stations = self._client.get_stations()
            return [
                {"id": s.id, "token": s.token, "name": s.name,
                 "is_quickmix": s.is_quickmix}
                for s in stations
            ]

    # --- playback ----------------------------------------------------------

    def next_track(self, station_token: str) -> Track:
        with self._lock:
            self._require_client()
            queue = self._queues.setdefault(station_token, [])
            self._maybe_refill_locked(station_token, queue)
            if not queue:
                raise PandoraError("Playlist exhausted and refill failed")
            return queue.pop(0)

    def feedback(self, track_token: str, is_positive: bool) -> None:
        with self._lock:
            self._require_client()
            try:
                self._client.add_feedback(track_token, is_positive)
            except AuthError:
                self._reauth()
                self._client.add_feedback(track_token, is_positive)

    def sleep_song(self, track_token: str) -> None:
        with self._lock:
            self._require_client()
            try:
                self._client.sleep_song(track_token)
            except AuthError:
                self._reauth()
                self._client.sleep_song(track_token)

    def _maybe_refill_locked(self, station_token: str,
                             queue: list[Track]) -> None:
        if len(queue) >= self.LOW_WATER:
            return
        try:
            tracks = self._client.get_playlist(station_token)
        except AuthError:
            self._reauth()
            tracks = self._client.get_playlist(station_token)
        playable = [t for t in tracks if not t.is_ad and t.audio_url]
        queue.extend(playable)
        log.debug("Refilled %s with %d tracks (queue now %d)",
                  station_token[:8], len(playable), len(queue))

    def _reauth(self) -> None:
        creds = _load_credentials()
        if not creds:
            raise AuthError("Not logged in and no saved credentials")
        log.info("Re-authenticating with saved credentials")
        self.login(creds["email"], creds["password"])

    def _require_client(self) -> None:
        if not self._client:
            raise AuthError("Not logged in")


# ----- HTTP layer ---------------------------------------------------------


@dataclass
class _Json:
    payload: object
    status: int = 200


def _make_handler(session: Session) -> type[BaseHTTPRequestHandler]:
    """Build a request handler class bound to a specific Session."""

    class _Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            log.info("%s - %s", self.address_string(), fmt % args)

        def do_GET(self) -> None:
            try:
                response = self._dispatch_get(self.path)
            except Exception as e:  # noqa: BLE001 - last-resort guard
                log.exception("Unhandled error in GET %s", self.path)
                response = _Json({"error": str(e)}, 500)
            self._send(response)

        def do_POST(self) -> None:
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length).decode("utf-8") if length else ""
                data = json.loads(body) if body else {}
                response = self._dispatch_post(self.path, data)
            except json.JSONDecodeError as e:
                response = _Json({"error": f"invalid JSON: {e}"}, 400)
            except Exception as e:  # noqa: BLE001 - last-resort guard
                log.exception("Unhandled error in POST %s", self.path)
                response = _Json({"error": str(e)}, 500)
            self._send(response)

        # --- routing -------------------------------------------------------

        def _dispatch_get(self, path: str) -> _Json:
            p = urlparse(path).path
            if p == "/status":
                return _Json(session.status())
            if p == "/stations":
                if not session.is_logged_in():
                    return _Json({"error": "not logged in"}, 503)
                try:
                    return _Json(session.list_stations())
                except (AuthError, PandoraError) as e:
                    return _Json({"error": str(e)}, 502)
            # /station/<token>/next
            parts = p.strip("/").split("/")
            if len(parts) == 3 and parts[0] == "station" and parts[2] == "next":
                token = unquote(parts[1])
                if not session.is_logged_in():
                    return _Json({"error": "not logged in"}, 503)
                try:
                    track = session.next_track(token)
                except (AuthError, PandoraError) as e:
                    return _Json({"error": str(e)}, 502)
                return _Json(_track_to_dict(track))
            return _Json({"error": "not found"}, 404)

        def _dispatch_post(self, path: str, data: dict) -> _Json:
            p = urlparse(path).path
            if p == "/auth":
                email = (data.get("email") or "").strip()
                password = data.get("password") or ""
                if not email or not password:
                    return _Json({"ok": False, "error": "email and password required"}, 400)
                try:
                    session.login(email, password)
                except (AuthError, PandoraError) as e:
                    return _Json({"ok": False, "error": str(e)}, 401)
                _save_credentials(email, password)
                return _Json({"ok": True})
            if p == "/feedback":
                token = (data.get("track_token") or "").strip()
                if not token:
                    return _Json({"ok": False, "error": "track_token required"}, 400)
                try:
                    session.feedback(token, bool(data.get("is_positive")))
                except (AuthError, PandoraError) as e:
                    return _Json({"ok": False, "error": str(e)}, 502)
                return _Json({"ok": True})
            if p == "/sleep":
                token = (data.get("track_token") or "").strip()
                if not token:
                    return _Json({"ok": False, "error": "track_token required"}, 400)
                try:
                    session.sleep_song(token)
                except (AuthError, PandoraError) as e:
                    return _Json({"ok": False, "error": str(e)}, 502)
                return _Json({"ok": True})
            return _Json({"error": "not found"}, 404)

        # --- response ------------------------------------------------------

        def _send(self, response: _Json) -> None:
            body = json.dumps(response.payload).encode("utf-8")
            self.send_response(response.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

    return _Handler


def _track_to_dict(t: Track) -> dict:
    return {
        "title": t.title,
        "artist": t.artist,
        "album": t.album,
        "audio_url": t.audio_url,
        "bitrate_kbps": t.bitrate_kbps,
        "duration_s": t.duration_hint,
        "is_ad": t.is_ad,
        "album_art_url": t.album_art_url,
        "track_token": t.token,
        "station_token": t.station_token,
    }


# ----- entry point --------------------------------------------------------


def make_server(host: str, port: int) -> ThreadingHTTPServer:
    session = Session()
    # Resume from disk if we can; otherwise stay logged out until /auth.
    session.try_resume_from_disk()
    return ThreadingHTTPServer((host, port), _make_handler(session))


def _write_port_file(port: int) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    PORT_FILE.write_text(str(port), encoding="utf-8")


def _remove_port_file() -> None:
    try:
        PORT_FILE.unlink()
    except FileNotFoundError:
        pass


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Windora LMS helper")
    parser.add_argument("--host", default=os.environ.get("WINDORA_HELPER_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("WINDORA_HELPER_PORT", DEFAULT_PORT)))
    parser.add_argument("--no-port-file", action="store_true",
                        help="Don't write the port file")
    parser.add_argument("--log-file", default=str(LOG_FILE),
                        help="Log file (default: %(default)s)")
    parser.add_argument("--log-level", default="INFO",
                        choices=("DEBUG", "INFO", "WARNING", "ERROR"))
    args = parser.parse_args(argv)

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=args.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        handlers=[
            logging.FileHandler(args.log_file, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )

    server = make_server(args.host, args.port)
    if not args.no_port_file:
        _write_port_file(server.server_address[1])

    log.info("Windora LMS helper listening on http://%s:%d",
             args.host, server.server_address[1])

    def _shutdown(signum, _frame):
        log.info("Caught signal %d, shutting down", signum)
        # shutdown() must run on a different thread than serve_forever.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        if not args.no_port_file:
            _remove_port_file()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
