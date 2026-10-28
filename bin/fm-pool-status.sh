#!/usr/bin/env bash
# fm-pool-status.sh - report effective Treehouse pool capacity, read-only.
#
# Usage: fm-pool-status.sh [--project <dir>]
#
# For a valid project directory and invocation, prints one line on stdout:
#   treehouse-pool: project=<path> max=<n|unknown> occupied=<n|unknown>
#     available=<n|unknown> unknown=<n|unknown> entries=<n|unknown>
#     saturation=<n>%|unknown state=<ok|saturated|full|unknown>
#     observed_at=<UTC> read_s=<n>
#
# bin/fm-pool-lib.sh's header owns maximum resolution, bucket definitions, and
# saturation classification. Actionable guidance goes to stderr for saturated,
# full, or unknown states so stdout stays machine-parseable.
#
# This command never allocates, returns, prunes, leases, or edits anything.
# Exit status: 0 complete inventory (including saturated or full), 1 unknown
# inventory, 2 usage error.
#
# Project selection defaults to the current directory and resolves its pool
# through Treehouse itself; pass --project for another checkout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

PROJECT=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  printf 'fm-pool-status.sh: project directory is not readable: %s\n' "${PROJECT:-<empty>}" >&2
  exit 2
fi

if fm_treehouse_pool_capacity "$PROJECT"; then
  rc=0
else
  rc=1
fi
fm_pool_capacity_line
case "$FM_POOL_STATE" in
  saturated|full|unknown)
    printf 'fm-pool-status.sh: %s\n' "$(fm_pool_capacity_action)" >&2
    ;;
esac
exit "$rc"
