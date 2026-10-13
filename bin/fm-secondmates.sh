#!/usr/bin/env bash
# fm-secondmates.sh - read-only inventory of the registered secondmate homes.
#
# Usage:
#   fm-secondmates.sh list
#   fm-secondmates.sh --help
#
# `list` prints one machine-readable block per record in data/secondmates.md,
# through the single owner of the registry format
# (bin/fm-secondmate-registry-lib.sh), so an agent answers "which secondmates
# exist, where, and for what scope" without re-parsing the registry prose. A
# malformed record fails loudly rather than being silently skipped.
#
# Output:
#   schema=fm-secondmates.list.v1
#   count=<n>
#   --
#   id=<id>
#   remote=<0|1>
#   host=<ssh alias>          (remote records only)
#   root=<code root>          (remote records only)
#   home=<home path>
#   scope=<scope text>
#   projects=<project keys>
#   added=<YYYY-MM-DD>
#
# Read-only: it never resolves a home, writes state, or contacts a mate.
# See data/secondmates.md for the registry format.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

cmd_list() {
  local line count=0
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"
  # A first pass validates every record and counts them, so `count=` is exact
  # even when a later record is malformed; the second pass emits the blocks.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
    count=$((count + 1))
  done < "$REG"
  printf 'schema=fm-secondmates.list.v1\n'
  printf 'count=%s\n' "$count"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
    printf '%s\n' '--'
    printf 'id=%s\n' "$SECONDMATE_REGISTRY_ID"
    printf 'remote=%s\n' "$SECONDMATE_REGISTRY_REMOTE"
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      printf 'host=%s\n' "$SECONDMATE_REGISTRY_HOST"
      printf 'root=%s\n' "$SECONDMATE_REGISTRY_ROOT"
    fi
    printf 'home=%s\n' "$SECONDMATE_REGISTRY_HOME"
    printf 'scope=%s\n' "$SECONDMATE_REGISTRY_SCOPE"
    printf 'projects=%s\n' "$SECONDMATE_REGISTRY_PROJECTS"
    printf 'added=%s\n' "$SECONDMATE_REGISTRY_ADDED"
  done < "$REG"
}

case "${1:-}" in
  list)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    cmd_list
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
