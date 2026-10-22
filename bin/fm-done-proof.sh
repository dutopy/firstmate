#!/usr/bin/env bash
# fm-done-proof.sh - the single owner of the "done/resolved" proof packet check.
#
# A task or incident may be called done or resolved only when its proof packet
# names, as non-empty `key: value` lines, the root cause, the regression test,
# the retest result, the authoritative state re-read after the change, the
# artifact or scope, and the exact rollback.
# A workaround is not a resolution: label it `status: workaround` and the check
# refuses it as done.
#
# Usage: fm-done-proof.sh <proof-file>
# Exit 0 when the packet is complete; exit 1 listing every missing or
# placeholder field; exit 2 on a usage error.
set -u

required_keys="root_cause regression_test retest authoritative_state artifact_or_scope rollback"

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: fm-done-proof.sh <proof-file>" >&2
  exit 2
fi
proof=$1
problems=""

for key in $required_keys; do
  value=$(sed -n "s/^${key}:[[:space:]]*//p" "$proof" | head -n 1)
  lowered=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    ""|todo*|tbd*|none|n/a|na|unknown|"?")
      problems="$problems $key"
      ;;
  esac
done

status=$(sed -n 's/^status:[[:space:]]*//p' "$proof" | head -n 1 | tr '[:upper:]' '[:lower:]')
if [ "$status" = "workaround" ]; then
  problems="$problems status=workaround"
fi

if [ -n "$problems" ]; then
  echo "refused: not done, fix:$problems" >&2
  exit 1
fi
echo "ok: proof packet complete"
