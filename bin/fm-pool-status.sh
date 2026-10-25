#!/usr/bin/env bash
# fm-pool-status.sh - report effective Treehouse pool capacity, read-only.
#
# Usage: fm-pool-status.sh [--project <dir>]
#
# Prints exactly one stable line on stdout:
#   treehouse-pool: project=<path> max=<n|unknown> occupied=<n|unknown>
#     available=<n|unknown> unknown=<n|unknown> entries=<n|unknown>
#     saturation=<n>%|unknown state=<ok|saturated|full|unknown>
#     observed_at=<UTC> read_s=<n>
#
# occupied is Treehouse's in-use + leased + dirty count, available is its
# available count, and unknown is any entry whose status is not one of those
# four. Unknown is never counted as available: an unreadable status read, a
# malformed inventory, or an unrecognized entry reports available=unknown or an
# explicit unknown count instead. The maximum comes from the primary checkout's
# treehouse.toml, falling back to ~/.config/treehouse/config.toml when absent.
# The default is 16 when neither file exists or the selected file omits max_trees.
#
# saturated means occupied is at least 80% of the effective maximum. full means
# no slot is available and the materialized count has reached the maximum, so
# Treehouse can neither hand out nor create a copy. Actionable guidance goes to
# stderr so stdout stays machine-parseable.
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
