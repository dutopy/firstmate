#!/usr/bin/env bash
# fm-disk-simulate-vps.sh - offline simulation ONLY for dutopy VPS objects.
# Usage: fm-disk-simulate-vps.sh --inventory FILE
# No server connection, deployment or cleanup. --help owns the input contract.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-disk-simulate.py" vps "$@"
