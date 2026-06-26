# windora-lms-helper

Localhost HTTP service that speaks Pandora's reverse-engineered JSON protocol
on behalf of the Logitech Media Server plugin in `../plugin/Pandora`.

The Pandora protocol code under `src/windora_lms/pandora/` is vendored from the
[Windora](https://github.com/joshknox1/windora) Windows client.

## Run by hand (debugging)

```bash
uv sync
uv run windora-lms-helper --port 9123
# or: uv run python -m windora_lms.lms_helper --port 9123
```

Then, in another terminal:

```bash
curl -s http://127.0.0.1:9123/status | jq
curl -s -X POST http://127.0.0.1:9123/auth \
     -H 'Content-Type: application/json' \
     -d '{"email":"you@example.com","password":"…"}' | jq
curl -s http://127.0.0.1:9123/stations | jq
curl -s "http://127.0.0.1:9123/station/<station_token>/next" | jq
```

## Run as a service

See `scripts/windora-lms-helper.service` and the install steps in the
top-level [README](../README.md).
