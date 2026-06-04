from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .constants import AUDIO_QUALITY_PREFERENCE


@dataclass
class Station:
    id: str            # stationId
    token: str         # stationToken — what the API actually wants in requests
    name: str
    is_quickmix: bool = False

    @classmethod
    def from_api(cls, data: dict) -> "Station":
        return cls(
            id=str(data.get("stationId", "")),
            token=str(data["stationToken"]),
            name=str(data.get("stationName", "")),
            is_quickmix=bool(data.get("isQuickMix", False)),
        )


@dataclass
class Track:
    token: str          # trackToken — for feedback / sleep
    station_token: str
    title: str
    artist: str
    album: str
    album_art_url: Optional[str]
    audio_url: str
    bitrate_kbps: Optional[int]
    is_ad: bool = False
    duration_hint: Optional[int] = None  # seconds, often missing

    @classmethod
    def from_api(cls, data: dict, station_token: str,
                 quality_preference: Optional[tuple[str, ...]] = None
                 ) -> Optional["Track"]:
        # Ad tokens come back as {"adToken": "..."} with no audio.
        if "adToken" in data and "trackToken" not in data:
            return cls(
                token=str(data["adToken"]),
                station_token=station_token,
                title="(Advertisement)",
                artist="",
                album="",
                album_art_url=None,
                audio_url="",
                bitrate_kbps=None,
                is_ad=True,
            )

        # Pick best available audio URL according to the user's preference
        # (falls back through the rest if the preferred quality is missing).
        url_map = data.get("audioUrlMap") or {}
        chosen = None
        for q in (quality_preference or AUDIO_QUALITY_PREFERENCE):
            if q in url_map and url_map[q].get("audioUrl"):
                chosen = url_map[q]
                break

        # Some responses (older) use additionalAudioUrl or audioUrl directly.
        audio_url = ""
        bitrate = None
        if chosen:
            audio_url = chosen["audioUrl"]
            try:
                bitrate = int(chosen.get("bitrate", 0)) or None
            except (TypeError, ValueError):
                bitrate = None
        elif data.get("audioUrl"):
            audio_url = data["audioUrl"]

        if not audio_url:
            return None  # unplayable

        return cls(
            token=str(data["trackToken"]),
            station_token=station_token,
            title=str(data.get("songName", "")),
            artist=str(data.get("artistName", "")),
            album=str(data.get("albumName", "")),
            album_art_url=data.get("albumArtUrl") or None,
            audio_url=audio_url,
            bitrate_kbps=bitrate,
            is_ad=False,
        )
