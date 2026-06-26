# WindoraLMS

Stream your [Pandora](https://www.pandora.com) stations to every Squeezebox on
your network, through [Logitech Media Server](https://github.com/LMS-Community/slimserver)
(LMS). Companion to the [Windora](https://github.com/joshknox1/windora) desktop
player — it reuses the same reverse-engineered Pandora protocol code.

## How it fits together

```
LMS host (your Linux server)
┌────────────────────────────────────────────────────────────┐
│  Logitech Media Server (Perl)                                │
│    plugin/Pandora/                                            │
│      Plugin.pm          → "Pandora" in My Apps, lists stations│
│      ProtocolHandler.pm → pandora://<stationToken>           │
│      Settings.pm        → sign-in + helper connection page   │
│            │  localhost HTTP (127.0.0.1:9123)                 │
│            ▼                                                  │
│  windora-lms-helper (Python)                                 │
│      /stations, /station/<token>/next, /auth, /status        │
│      talks the Pandora JSON protocol, filters ads            │
└────────────────────────────────────────────────────────────┘
            │  one freshly-signed CDN URL per track
            ▼
   Squeezebox players stream audio directly from Pandora's CDN
```

**Why a protocol handler?** A Pandora station is the URL
`pandora://<stationToken>`. LMS treats it as a never-ending stream, so each
time a track ends — or you press **Next** — it asks the handler for the next
song, and the handler fetches one fresh CDN URL from the helper right then.
Pandora's signed URLs expire in under a minute, so resolving them per-track
(instead of pre-filling the playlist) is what makes auto-advance and skip work.

## Repository layout

```
WindoraLMS/
├── plugin/Pandora/        # the LMS plugin — copy to <LMS>/Plugins/Pandora/
│   ├── Plugin.pm
│   ├── ProtocolHandler.pm
│   ├── Settings.pm
│   ├── install.xml
│   ├── strings.txt
│   └── HTML/EN/plugins/Pandora/settings/basic.html
└── helper/                # the Python helper service — install on the LMS host
    ├── src/windora_lms/
    │   ├── lms_helper.py
    │   └── pandora/       # vendored from Windora; keep in sync
    ├── scripts/
    │   ├── windora-lms-helper.service
    │   └── windora-lms-helper.sh
    └── pyproject.toml
```

The helper and the plugin both run **on the LMS host**. The helper binds
`127.0.0.1` only; nothing here should be exposed to the network.

## Install (LMS on a Linux server)

Run these on the machine where Logitech Media Server runs.

### 1. Install the helper service

```bash
# A home for the install. /opt/windora-lms is what the systemd unit assumes.
sudo useradd --system --home /var/lib/windora-lms \
             --shell /usr/sbin/nologin windora-lms
sudo install -d -o windora-lms -g windora-lms /opt/windora-lms /var/lib/windora-lms

# Copy the helper (the contents of this repo's helper/ dir).
sudo rsync -a --chown=windora-lms:windora-lms helper/ /opt/windora-lms/

# Build the venv (installs requests + cryptography).
sudo -u windora-lms -H bash -c 'cd /opt/windora-lms && uv sync'

# Install + start the systemd unit.
sudo install -m 0644 /opt/windora-lms/scripts/windora-lms-helper.service \
                     /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now windora-lms-helper
sudo systemctl status windora-lms-helper
```

No `uv`? Use any Python ≥3.11: `python3 -m venv /opt/windora-lms/.venv &&
/opt/windora-lms/.venv/bin/pip install -e /opt/windora-lms`.

### 2. Install the LMS plugin

```bash
# Drop the plugin into LMS's Plugins directory. The exact path varies by
# packaging; find yours with:  sudo find / -type d -name Plugins 2>/dev/null
sudo rsync -a plugin/Pandora/ /usr/share/squeezeboxserver/Plugins/Pandora/
sudo systemctl restart logitechmediaserver   # or: lyrionmediaserver / squeezeboxserver
```

### 3. Sign in

LMS web UI → **Settings → Advanced → Pandora** (or **Settings → Plugins**).
Confirm the helper status shows **reachable**, then enter your Pandora email and
password and click **Sign in**. Credentials go to the helper, which validates
them against Pandora and stores them at
`/var/lib/windora-lms/credentials.json` (mode 0600) — never in the LMS DB.

### 4. Play

On any Squeezebox: **My Apps → Pandora** → pick a station. The first track
starts and playback auto-advances; **Next** skips to a fresh track.

## Develop / test the helper without LMS

```bash
cd helper
uv sync
uv run windora-lms-helper --port 9123
# then curl /status, /auth, /stations, /station/<token>/next — see helper/README.md
```

## Status & limitations (v0.1)

- Stations list + playback with real auto-advance and skip. ✅
- Ads are filtered server-side (the player never sees them).
- Thumbs up/down and sleep are plumbed in the helper (`/feedback`, `/sleep`)
  but not yet wired to player buttons — v0.2.
- Pandora has no public API; this rides the same reverse-engineered protocol as
  pianobar/pithos and can break if Pandora changes their backend. When that
  happens, re-vendor `helper/src/windora_lms/pandora/` from
  [Windora](https://github.com/joshknox1/windora).

## License

MIT.
