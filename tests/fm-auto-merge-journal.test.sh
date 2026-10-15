#!/usr/bin/env bash
# Run from the repository root; clear file-based fixtures preserve the real data transport.
set -eu
# shellcheck source=tests/git-config-helpers.sh
. tests/git-config-helpers.sh
python3 tests/fixtures/auto-merge-journal/run.py "$@"
