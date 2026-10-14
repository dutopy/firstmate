#!/usr/bin/env bash
# fm-disk-simulate-staging.sh - local simulation ONLY; hand off to Fred.
# Usage: fm-disk-simulate-staging.sh --inventory FILE
# Does not contact Fred or staging. --help owns the input/evidence contract.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm-disk-simulate.py" staging "$@"
