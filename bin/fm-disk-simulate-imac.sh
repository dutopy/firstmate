#!/usr/bin/env bash
# fm-disk-simulate-imac.sh - simulation ONLY for explicit iMac whitelist objects.
# Usage: fm-disk-simulate-imac.sh --inventory FILE
# --help prints the shared inventory/evidence contract; no apply mode exists.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-disk-simulate.py" imac "$@"
