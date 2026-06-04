#!/usr/bin/env bash
# Re-vendor windora/pandora/* from the Windora source tree.
#
# Pandora tweaks their backend often, and the protocol code (Blowfish keys,
# partner credentials, error code handling) lives in one place upstream.
# Run this from the windora-lms repo root after pulling Windora updates:
#
#   ./scripts/sync-from-windora.sh
#   git add src/windora_lms/pandora
#   git commit -m "vendor: sync windora.pandora from upstream"
#
# Override the source path with WINDORA_SRC=/path/to/windora.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

WINDORA_SRC="${WINDORA_SRC:-$HOME/src/windora}"
if [[ ! -d "$WINDORA_SRC/windora/pandora" ]]; then
    echo "Windora source not found at $WINDORA_SRC/windora/pandora" >&2
    echo "Set WINDORA_SRC=/path/to/windora if it lives elsewhere." >&2
    exit 1
fi

DST="$REPO_ROOT/src/windora_lms/pandora"
mkdir -p "$DST"

for f in __init__.py client.py constants.py crypto.py models.py; do
    cp -v "$WINDORA_SRC/windora/pandora/$f" "$DST/$f"
done

echo
echo "Done. Diff against the last vendor:"
git diff --stat -- src/windora_lms/pandora || true
