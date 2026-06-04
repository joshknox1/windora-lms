"""Pandora JSON-RPC client (the same reverse-engineered protocol pianobar uses).

Auth flow:
    1. partnerLogin  — unencrypted POST. Returns partnerId, partnerAuthToken,
       and an encrypted syncTime. We compute a syncTime offset from server time.
    2. userLogin     — encrypted body, signs with partnerAuthToken. Returns userId
       and userAuthToken.
    3. All subsequent calls use userAuthToken in the URL query + encrypted body.

When `login()` fails with an auth-shaped error, we automatically retry the whole
flow with the next partner in `constants.PARTNERS`. Pandora has been flaking on
the android partner lately; iPhone usually still works.

Set env var WINDORA_DEBUG_API=1 to dump request/response envelopes (with
credentials redacted) to `windora-api.log` in the working directory.
"""

from __future__ import annotations

import json
import logging
import os
import time
from typing import Any, Optional

import requests

from . import constants as C
from .crypto import decrypt_sync_time, encrypt
from .models import Station, Track


log = logging.getLogger("windora.pandora")


class PandoraError(Exception):
    """Any Pandora API error. .code is the integer Pandora returned (or 0)."""
    def __init__(self, message: str, code: int = 0):
        super().__init__(message)
        self.code = code


class AuthError(PandoraError):
    pass


# Error codes from pianobar's reverse engineering.
ERROR_INTERNAL = 0
ERROR_INVALID_AUTH_TOKEN = 1001       # also returned for "stale partner login"
ERROR_INVALID_PARTNER_LOGIN = 1002
ERROR_INVALID_USERNAME = 1011
ERROR_INVALID_PASSWORD = 1012
ERROR_USER_NOT_AUTHORIZED = 1013

# Codes where we should retry with the next partner before giving up.
RETRY_NEXT_PARTNER = {ERROR_INVALID_AUTH_TOKEN, ERROR_INVALID_PARTNER_LOGIN}

# Codes that indicate the user's credentials really are wrong.
TRULY_BAD_USER_CREDS = {ERROR_INVALID_USERNAME, ERROR_INVALID_PASSWORD,
                        ERROR_USER_NOT_AUTHORIZED}


def _debug_enabled() -> bool:
    return os.environ.get("WINDORA_DEBUG_API") == "1"


def _redact(body: dict) -> dict:
    out = dict(body)
    for k in ("password", "userAuthToken", "partnerAuthToken"):
        if k in out and out[k]:
            out[k] = f"<redacted len={len(str(out[k]))}>"
    return out


class PandoraClient:
    def __init__(self, timeout: float = 15.0):
        self._session = requests.Session()
        self._timeout = timeout
        self.partner: Optional[C.Partner] = None
        self.partner_id: Optional[str] = None
        self.partner_auth_token: Optional[str] = None
        self.user_id: Optional[str] = None
        self.user_auth_token: Optional[str] = None
        self._sync_offset: int = 0  # server_time - local_time, in seconds

        self._email: Optional[str] = None
        self._password: Optional[str] = None

    # ------- auth ----------------------------------------------------------

    def login(self, email: str, password: str) -> None:
        """Run partner + user login. Retries with each partner in PARTNERS until
        one succeeds. Raises AuthError only if every partner says the user's
        creds are bad."""
        self._email = email
        self._password = password
        last_err: Optional[PandoraError] = None
        for partner in C.PARTNERS:
            try:
                self._login_with(partner)
                log.info("Logged in via partner %s (user_id=%s)",
                         partner.name, self.user_id)
                return
            except PandoraError as e:
                last_err = e
                if e.code in TRULY_BAD_USER_CREDS:
                    # The user's email/password is actually wrong — no point
                    # trying another partner.
                    raise
                log.warning("Login via partner %s failed (code %d: %s) — "
                            "trying next partner", partner.name, e.code, e)
                self._reset_session()
                continue
        assert last_err is not None
        raise last_err

    def _login_with(self, partner: C.Partner) -> None:
        self.partner = partner
        self._partner_login()
        self._user_login()

    def _reset_session(self) -> None:
        self.partner = None
        self.partner_id = None
        self.partner_auth_token = None
        self.user_id = None
        self.user_auth_token = None
        self._sync_offset = 0

    def _partner_login(self) -> None:
        assert self.partner is not None
        body = {
            "username": self.partner.username,
            "password": self.partner.password,
            "deviceModel": self.partner.device_model,
            "version": C.API_VERSION,
        }
        resp = self._raw_request("auth.partnerLogin", body, encrypted=False)
        self.partner_id = resp["partnerId"]
        self.partner_auth_token = resp["partnerAuthToken"]
        server_sync = decrypt_sync_time(resp["syncTime"], self.partner.decrypt_key)
        self._sync_offset = server_sync - int(time.time())

    def _user_login(self) -> None:
        assert self.partner_auth_token, "must call _partner_login first"
        body = {
            "loginType": "user",
            "username": self._email,
            "password": self._password,
            "partnerAuthToken": self.partner_auth_token,
            "syncTime": self._sync_time(),
        }
        resp = self._call("auth.userLogin", body, auth_token=self.partner_auth_token)
        self.user_id = resp["userId"]
        self.user_auth_token = resp["userAuthToken"]

    # ------- stations / playlist ------------------------------------------

    def get_stations(self) -> list[Station]:
        resp = self._call_authed("user.getStationList", {})
        return [Station.from_api(s) for s in resp.get("stations", [])]

    def get_playlist(self, station_token: str,
                     quality_preference: Optional[tuple[str, ...]] = None
                     ) -> list[Track]:
        body = {
            "stationToken": station_token,
            "additionalAudioUrl": "",
            "includeTrackLength": True,
        }
        resp = self._call_authed("station.getPlaylist", body)
        tracks: list[Track] = []
        for item in resp.get("items", []):
            t = Track.from_api(item, station_token, quality_preference)
            if t is not None:
                tracks.append(t)
        return tracks

    def add_feedback(self, track_token: str, is_positive: bool) -> None:
        self._call_authed("station.addFeedback", {
            "trackToken": track_token,
            "isPositive": bool(is_positive),
        })

    def sleep_song(self, track_token: str) -> None:
        self._call_authed("user.sleepSong", {"trackToken": track_token})

    # ------- low-level ----------------------------------------------------

    def _sync_time(self) -> int:
        return int(time.time()) + self._sync_offset

    def _call_authed(self, method: str, body: dict) -> dict:
        if not self.user_auth_token:
            raise AuthError("Not logged in")
        body = dict(body)
        body.setdefault("userAuthToken", self.user_auth_token)
        body.setdefault("syncTime", self._sync_time())
        return self._call(method, body, auth_token=self.user_auth_token,
                          user_id=self.user_id)

    def _call(self, method: str, body: dict, *, auth_token: Optional[str] = None,
              user_id: Optional[str] = None) -> dict:
        return self._raw_request(method, body, encrypted=True,
                                 auth_token=auth_token, user_id=user_id)

    def _raw_request(self, method: str, body: dict, *, encrypted: bool,
                     auth_token: Optional[str] = None,
                     user_id: Optional[str] = None) -> dict:
        params: dict[str, str] = {"method": method}
        if self.partner_id:
            params["partner_id"] = self.partner_id
        if auth_token:
            params["auth_token"] = auth_token
        if user_id:
            params["user_id"] = user_id

        body_json = json.dumps(body, separators=(",", ":"))
        if encrypted:
            assert self.partner is not None
            payload: Any = encrypt(body_json, self.partner.encrypt_key)
            headers = {"Content-Type": "text/plain"}
        else:
            payload = body_json
            headers = {"Content-Type": "application/json"}

        if _debug_enabled():
            self._debug_dump("REQUEST", method, params, body)

        r = self._session.post(C.API_BASE, params=params, data=payload,
                               headers=headers, timeout=self._timeout)
        r.raise_for_status()
        envelope = r.json()

        if _debug_enabled():
            self._debug_dump("RESPONSE", method, params, envelope)

        if envelope.get("stat") != "ok":
            code = int(envelope.get("code", 0))
            msg = str(envelope.get("message", "Pandora API error"))
            err_msg = f"{msg} (code {code}, partner={self.partner.name if self.partner else '?'})"
            if code in TRULY_BAD_USER_CREDS:
                raise AuthError(err_msg, code=code)
            if code in RETRY_NEXT_PARTNER:
                raise AuthError(err_msg, code=code)
            raise PandoraError(err_msg, code=code)
        return envelope.get("result", {})

    @staticmethod
    def _debug_dump(label: str, method: str, params: dict, body: dict) -> None:
        try:
            with open("windora-api.log", "a", encoding="utf-8") as f:
                f.write(f"=== {label} {method} ===\n")
                f.write(f"params: {params}\n")
                f.write(f"body  : {json.dumps(_redact(body) if isinstance(body, dict) else body, indent=2)}\n\n")
        except OSError:
            pass
