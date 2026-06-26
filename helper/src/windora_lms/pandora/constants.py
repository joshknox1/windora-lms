"""Partner credentials and endpoints for the reverse-engineered Pandora JSON API.

Pandora's API has multiple "partners" — each corresponds to one of their official
clients (Android, iPhone, Pandora One desktop). They all use the same protocol;
only the partner credentials and Blowfish keys differ. When one partner gets
flaky (Pandora has been bot-detecting and rate-limiting them lately), falling
back to a different one usually works.

These are the same partner constants pianobar/pithos/pydora ship.
"""

from __future__ import annotations

from dataclasses import dataclass

API_BASE = "https://tuner.pandora.com/services/json/"
API_VERSION = "5"

# Audio quality preference order — we ask Pandora to return all and pick the best.
# Pandora returns these keys inside each track's `audioUrlMap`.
AUDIO_QUALITY_PREFERENCE = ("highQuality", "mediumQuality", "lowQuality")


@dataclass(frozen=True)
class Partner:
    name: str
    username: str
    password: str
    device_model: str
    decrypt_key: bytes
    encrypt_key: bytes


# Fallback order: iPhone first (most reliable recently), then Android.
PARTNERS = [
    Partner(
        name="iphone",
        username="iphone",
        password="P2E4FC0EAD3*878N92B2CDp34I0B1@388137C",
        device_model="IP01",
        decrypt_key=b"20zE1E47BE57$51",
        encrypt_key=b"721^26xE22776",
    ),
    Partner(
        name="android",
        username="android",
        password="AC7IBG09A3DTSYM4R41UJWL07VLN8JI7",
        device_model="android-generic",
        decrypt_key=b"R=U!LH$O2B#",
        encrypt_key=b"6#26FRL$ZWD",
    ),
]
