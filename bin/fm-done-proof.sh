#!/usr/bin/env bash
# fm-done-proof.sh - the single owner of the "done/resolved" proof packet check.
#
# A task or incident may be called done or resolved only when its proof packet
# contains these non-empty `key: value` lines:
#   root_cause: the root cause
#   regression_test: the regression test
#   retest: the retest result
#   authoritative_state: the authoritative state re-read after the change
#   artifact_or_scope: the artifact or scope
#   rollback: the exact rollback
# Keys start at column zero; the first occurrence of each key is checked.
# Values are trimmed of surrounding whitespace and checked case-insensitively.
# Empty values, TODO*/TBD* prefixes, none, n/a, na, unknown, and ? are refused.
# A workaround is not a resolution: label it `status: workaround` and the check
# refuses it as done.
#
# Usage: fm-done-proof.sh <proof-file>
#        fm-done-proof.sh --status <status-file> <proof-file>
# The --status form is the executable gate: it passes when the status file's
# latest recognized event is not a done claim, and otherwise requires the packet.
# Event selection and verb parsing use fm-classify-lib.sh, including keyed and
# indented declarations; continuation prose and blanks do not supersede events.
# This gate runs only when invoked; it does not intercept status-file writes.
# Exit 0 when the packet is complete or --status finds no done claim; exit 1
# for a missing packet required by --status, missing/placeholder fields, or a
# workaround; exit 2 on a usage error.
# Regression coverage: tests/fm-done-proof.test.sh.
set -u

required_keys="root_cause regression_test retest authoritative_state artifact_or_scope rollback"

if [ "${1:-}" = "--status" ]; then
  if [ "$#" -ne 3 ] || [ ! -f "$2" ]; then
    echo "usage: fm-done-proof.sh --status <status-file> <proof-file>" >&2
    exit 2
  fi
  # shellcheck source=bin/fm-classify-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-classify-lib.sh"
  last=$(last_status_line "$2")
  case "$(status_line_verb "$last")" in
    done) ;;
    *) echo "ok: latest status is not a done claim"; exit 0 ;;
  esac
  if [ ! -f "$3" ]; then
    echo "refused: done claimed without a proof packet ($3)" >&2
    exit 1
  fi
  shift 2
fi

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: fm-done-proof.sh <proof-file>" >&2
  exit 2
fi
proof=$1
problems=""

for key in $required_keys; do
  value=$(sed -n "/^${key}:/ { s/^${key}:[[:space:]]*//; s/[[:space:]]*$//; p; }" "$proof" | head -n 1)
  lowered=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    ""|todo*|tbd*|none|n/a|na|unknown|"?")
      problems="$problems $key"
      ;;
  esac
done

status=$(sed -n '/^status:/ { s/^status:[[:space:]]*//; s/[[:space:]]*$//; p; }' "$proof" | head -n 1 | tr '[:upper:]' '[:lower:]')
if [ "$status" = "workaround" ]; then
  problems="$problems status=workaround"
fi

if [ -n "$problems" ]; then
  echo "refused: not done, fix:$problems" >&2
  exit 1
fi
echo "ok: proof packet complete"
