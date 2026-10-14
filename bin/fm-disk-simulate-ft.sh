#!/usr/bin/env bash
# fm-disk-simulate-ft.sh - simulation ONLY; FT lacks whitelist and inventory.
# Usage: fm-disk-simulate-ft.sh [--inventory FILE]
# Always refuses candidate evaluation. --help prints the shared contract.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-disk-simulate.py" ft "$@"
