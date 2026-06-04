#!/usr/bin/env bash
# Start the windora-lms helper in the foreground.
#
# Use this under systemd (recommended), or run it by hand while debugging.
#
# Environment overrides:
#   WINDORA_HELPER_HOST  (default 127.0.0.1)
#   WINDORA_HELPER_PORT  (default 9123)
#   WINDORA_VENV         (default <repo>/.venv)
#   WINDORA_CONFIG_DIR   (default $HOME/.config/windora-lms)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

VENV="${WINDORA_VENV:-$REPO_ROOT/.venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
    echo "windora-lms-helper: python not found in $VENV" >&2
    echo "Run \`uv sync\` first, or set WINDORA_VENV to a working venv." >&2
    exit 1
fi

CONFIG_DIR="${WINDORA_CONFIG_DIR:-$HOME/.config/windora-lms}"
mkdir -p "$CONFIG_DIR"
export WINDORA_CONFIG_DIR

HOST="${WINDORA_HELPER_HOST:-127.0.0.1}"
PORT="${WINDORA_HELPER_PORT:-9123}"
export WINDORA_HELPER_HOST WINDORA_HELPER_PORT

exec "$VENV/bin/python" -m windora_lms.lms_helper \
    --host "$HOST" \
    --port "$PORT" \
    --log-file "$CONFIG_DIR/lms-helper.log"
