#!/usr/bin/env bash
# size-gate.sh [base-ref] [head-ref]
# Measure committed changes; defaults: merge-base(origin/main, head) and HEAD.
# Exit 0: measured <=400 added+deleted lines and <=15 files; 1: oversized;
# 2: usage, read or measurement failure (including included binary changes).
# Successful measurements print exactly one line, even when oversized:
# added=N deleted=N lines=N files=N max_lines=400 max_files=15
# Exclude only package-lock.json, pnpm-lock.yaml and uv.lock basenames,
# *.snap paths, and root docs/external/ and tests/fixtures/ trees.
# Renames count once and are excluded only when BOTH paths are excluded.
# Limits and exclusions are fixed; environment variables cannot relax them.
set -u

usage() {
  cat <<'HELP'
Usage: size-gate.sh [base-ref] [head-ref]
Defaults: base = merge-base(origin/main, head); head = HEAD.
Exit 0: <=400 added+deleted lines and <=15 files; 1: oversized; 2: failure.
Measured output: added=N deleted=N lines=N files=N max_lines=400 max_files=15
Exclusions: package-lock.json, pnpm-lock.yaml, uv.lock (any directory),
*.snap, root docs/external/ and tests/fixtures/ trees.
Renames count once; both paths must be excluded to omit a rename.
Included binary changes are measurement failures. Limits are not configurable.
HELP
}
error() { printf 'size-gate: %s\n' "$1" >&2; exit 2; }
excluded() {
  case "$1" in
    package-lock.json|*/package-lock.json|pnpm-lock.yaml|*/pnpm-lock.yaml|uv.lock|*/uv.lock|*.snap|docs/external/*|tests/fixtures/*) return 0 ;;
    *) return 1 ;;
  esac
}
if [ "$#" -eq 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
[ "$#" -le 2 ] || error 'expected at most two refs'
head=${2-HEAD}
# Resolve to object IDs before diff so options and revision ranges cannot be
# interpreted as Git arguments. Require commit-ish refs, not working-tree paths.
head=$(git rev-parse --verify --end-of-options "$head^{commit}") || error 'cannot resolve head ref'
if [ "$#" -ge 1 ]; then
  base=$(git rev-parse --verify --end-of-options "$1^{commit}") || error 'cannot resolve base ref'
else
  base=$(git merge-base origin/main "$head") || error 'cannot find merge-base with origin/main'
fi
stats=$(mktemp "${TMPDIR:-/tmp}/size-gate.XXXXXX") || error 'cannot create measurement file'
trap 'rm -f "$stats"' EXIT
trap 'exit 2' HUP INT TERM
# Stage the complete output: a process substitution/pipeline would lose Git's
# failure status. Disable external/textconv drivers and pin rename detection.
git diff --no-relative --no-ext-diff --no-textconv --ignore-submodules=none --find-renames=50% --numstat -z "$base" "$head" -- > "$stats" || error 'cannot read diff'
added=0 deleted=0 files=0
while IFS= read -r -d '' record; do
  tab=$'\t'
  [[ "$record" == *"$tab"*"$tab"* ]] || error 'malformed numstat record'
  a=${record%%"$tab"*}
  rest=${record#*"$tab"}
  d=${rest%%"$tab"*}
  path=${rest#*"$tab"}
  if [ -z "$path" ]; then
    IFS= read -r -d '' old_path || error 'missing rename source'
    IFS= read -r -d '' path || error 'missing rename destination'
    if excluded "$old_path" && excluded "$path"; then continue; fi
  elif excluded "$path"; then
    continue
  fi
  [[ "$a" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || error 'included binary or unmeasurable change'
  added=$((added + 10#$a))
  deleted=$((deleted + 10#$d))
  files=$((files + 1))
done < "$stats"
lines=$((added + deleted))
printf 'added=%d deleted=%d lines=%d files=%d max_lines=400 max_files=15\n' "$added" "$deleted" "$lines" "$files"
[ "$lines" -le 400 ] && [ "$files" -le 15 ] || exit 1
