#!/usr/bin/env bash
# Read-only GitHub small-PR eligibility snapshot; never merges or grants authority.
# Usage: fm-auto-merge-check.sh <task-id> <pr-url>
# Exit 0 prints one JSON object binding URL, final head, base tip, merge base,
# authoritative actor IDs, native run ID and size-gate measurements.
# Exit 1 refuses eligibility (including missing tools/evidence); stdout stays empty.
# Only plain modifications outside the versioned deny list in
# bin/fm-auto-merge-denylist.globs, within the installed size gate and the
# deletion bound, are classified low-risk; every other change needs explicit
# approval.
# The installed size-gate.sh owns measured size exclusions, never safety exclusions.
# No activation, persisted receipt, merge integration or journal is implemented here.
# All merges still belong to fm-pr-merge.sh and its independent authority checks.
# Requires Python 3, jq, gh-axi, gh (the actual guarded merger) and no-mistakes.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-cli-lib.sh
. "$SCRIPT_DIR/fm-cli-lib.sh"
fm_cli_help "$@"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1" || ! fm_pr_url_parse "$2" || [ "$FM_PR_PROVIDER" != github ]; then
  echo 'refused: expected task ID and canonical GitHub PR URL' >&2
  exit 1
fi
export PYTHONDONTWRITEBYTECODE=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1
exec python3 "$SCRIPT_DIR/fm_auto_merge_check.py" "$1" "$FM_PR_URL" "$FM_PR_PATH" "$FM_PR_NUMBER"
