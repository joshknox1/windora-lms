# windora-lms

Stream your [Pandora](https://www.pandora.com) stations to every Squeezebox
on your network, by way of [Logitech Media Server](https://github.com/LMS-Community/slimserver).

The Pandora protocol work is done by a small Python helper service that
the LMS Perl plugin talks to. The protocol module (`windora_lms.pandora.*`)
is vendored from the [Windora](https://github.com/anomalyco/windora) Windows
client so this package can install and run standalone — the LMS box doesn't
need the Windora GUI.

```
LMS (Perl)                  windora-lms-helper (Python, on the LMS box)
──────────                  ──────────────────────────────────────────
lms-plugin/Pandora/Plugin.pm  ──HTTP──►  windora_lms.lms_helper  ──uses──►  windora_lms.pandora.*
   │                                    │                              ▲
   │  list stations                     │  stations / next track /      │
   │  play a station                    │  re-auth                      │
   │  next on user "next"               │  filter ads                   │
   ▼                                    ▼
Squeezebox / player streams Pandora CDN URL directly
```

## Layout

```
windora-lms/
├── src/
│   └── windora_lms/
│       ├── lms_helper.py       # HTTP service the plugin talks to
│       └── pandora/            # vendored from Windora; keep in sync
│           ├── client.py
│           ├── constants.py
│           ├── crypto.py
│           ├── models.py
│           └── __init__.py
├── lms-plugin/
│   └── Pandora/                # drop into LMS's Plugins/ directory
│       ├── install.xml
│       ├── Plugin.pm
│       ├── Settings.pm
│       └── strings.txt
├── scripts/
│   ├── windora-lms-helper.sh   # foreground launcher
│   ├── windora-lms-helper.service  # systemd unit
│   └── sync-from-windora.sh    # re-vendor the pandora module
├── dev-lms-stubs/              # dev-only Perl shims (not for install)
├── pyproject.toml
└── README.md
```

## Install — LMS server (Linux)

### 1. Install the helper service

```bash
# Pick a home for the install. /opt/windora-lms is what the systemd
# unit assumes; override if you install elsewhere.
sudo install -d -o windora-lms -g windora-lms /opt/windora-lms
sudo install -d -o windora-lms -g windora-lms /var/lib/windora-lms
sudo useradd --system --home /var/lib/windora-lms \
             --shell /usr/sbin/nologin windora-lms
git clone https://github.com/joshknox1/windora-lms.git /opt/windora-lms-src
sudo rsync -a --chown=windora-lms:windora-lms \
    /opt/windora-lms-src/ /opt/windora-lms/

# Set up the venv with the helper's dependencies.
sudo -u windora-lms -H bash -c 'cd /opt/windora-lms && uv sync'

# Install the systemd unit and start the helper.
sudo install -m 0644 /opt/windora-lms/scripts/windora-lms-helper.service \
                    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now windora-lms-helper
sudo systemctl status windora-lms-helper
```

### 2. Install the LMS plugin

```bash
# Drop the plugin into LMS's Plugins directory.
sudo rsync -av /opt/windora-lms/lms-plugin/Pandora/ \
              /usr/share/squeezeboxserver/Plugins/Pandora/
# (On Debian/Ubuntu LMS packages the path can also be
#  /var/lib/squeezeboxserver/plugins/ — pick whichever your
#  install uses; `find / -name 'Plugins' -type d 2>/dev/null`
#  will show you.)
sudo systemctl restart logitechmediaserver
```

### 3. Sign in

Open the LMS web UI → **Settings → Plugins → Pandora**, enter your
Pandora email and password, click **Sign in**. The plugin POSTs to the
helper, which validates the credentials against Pandora, persists them
to `~/.config/windora-lms/credentials.json` (mode 0600), and starts
holding an authenticated session.

### 4. Play

On any Squeezebox, go to **My Apps → Pandora**. You'll see your stations.
Pick one; the first track starts. A small batch is queued behind it so
playback continues naturally for a while; when the queue runs out, press
**Next** on the player to grab more.

## Config

| Knob                     | Where                                         | Default                       |
| ------------------------ | --------------------------------------------- | ----------------------------- |
| Helper host              | LMS plugin Settings page, "Helper connection" | `127.0.0.1`                   |
| Helper port              | LMS plugin Settings page, "Helper connection" | `9123`                        |
| Helper bind address      | `WINDORA_HELPER_HOST` env var                 | `127.0.0.1`                   |
| Helper port (alt)        | `WINDORA_HELPER_PORT` env var                 | `9123`                        |
| Helper log file          | `WINDORA_CONFIG_DIR`/lms-helper.log           | `~/.config/windora-lms/…`     |
| Credentials file         | `WINDORA_CONFIG_DIR`/credentials.json         | `~/.config/windora-lms/…`     |
| Pre-queue depth (tracks) | `KEEP_AHEAD` constant in `Plugin.pm`          | `2`                           |

## Testing the helper without LMS

```bash
uv run python -m windora_lms.lms_helper --port 9123

# In another terminal:
curl -s http://127.0.0.1:9123/status | jq

# Sign in:
curl -s -X POST http://127.0.0.1:9123/auth \
     -H 'Content-Type: application/json' \
     -d '{"email":"you@example.com","password":"…"}' | jq

# List stations:
curl -s http://127.0.0.1:9123/stations | jq

# Pull the next playable track from a station:
curl -s "http://127.0.0.1:9123/station/<station_id>/next" | jq
```

## Keeping the vendored Pandora module in sync

The `src/windora_lms/pandora/` directory is a copy of the same module in
[Windora](https://github.com/anomalyco/windora) (`windora/pandora/`).
When Windora updates its protocol work — usually because Pandora broke
something — re-vendor:

```bash
./scripts/sync-from-windora.sh
git add src/windora_lms/pandora
git commit -m "vendor: sync windora.pandora from upstream"
```

The script points at the default clone location; override with
`WINDORA_SRC=/path/to/windora` if yours is elsewhere.

## MVP limitations (v0.1)

- **Auto-advance is partial.** The plugin pre-queues `KEEP_AHEAD` tracks
  when you pick a station, so the first few play through without
  intervention. Once the queue is empty, you have to press **Next** to
  get more.
- **No feedback, no sleep, no station create/delete.** v0.2.
- **Ads are filtered** server-side so the player only ever sees playable
  audio. Pandora's "you heard this ad" accounting won't reflect that —
  the ad slot is just dropped from the playlist.
- **No re-login on token expiry.** If your partner auth token goes stale
  the helper returns 502; the simplest fix is to re-enter your password
  on the plugin's Settings page (which re-runs `/auth`).

## Troubleshooting

- **`/status` returns `{"logged_in": false}` after restart**: the helper
  couldn't re-auth from saved credentials. Check the log
  (`~/.config/windora-lms/lms-helper.log`) and the permissions on
  `credentials.json` (must be `0600`).
- **`{"error": "not logged in"}` from `/stations` or `/station/.../next`**:
  open the LMS plugin's Settings page and re-enter your password.
- **Tracks 404 / die after 30 s**: Pandora's CDN URLs are short-lived.
  If you see this, your network is probably re-encoding or proxying the
  audio, which breaks the signed URL. Test with a raw `curl` on the URL
  the helper returns.
- **Perl compile errors on LMS**: LMS ships with its own Perl modules;
  you should not need to install anything. The plugin uses
  `LWP::UserAgent` and `JSON::XS`, which are core LMS deps.

## License

MIT. See [Windora](https://github.com/anomalyco/windora) for the
attribution chain on the Pandora protocol module.
