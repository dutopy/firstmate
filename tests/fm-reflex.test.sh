#!/usr/bin/env bash
# Native reflex reporter contract: ten bounded synthetic cases, privacy-safe
# evidence, lifecycle separation, deduplication, and explicit resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORTER="$ROOT/bin/fm-reflex.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-reflex.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
state="$TMP_ROOT/state"
mkdir -p "$state"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
run() { FM_STATE_OVERRIDE="$state" FM_HOME="$TMP_ROOT" "$REPORTER" "$@"; }

keys=()
for n in $(seq 1 10); do
  out=$(run intake "case-$n" "worker-$n" unknown "private raw evidence case $n")
  key=${out#*$'\t'}
  keys+=("$key")
  run report "case-$n" "$key" >/dev/null
  run review "case-$n" "$key" >/dev/null
  [ "$(run intake "case-$n" "worker-$n" unknown "private raw evidence case $n")" = "already-intake$(printf '\t')$key" ] \
    || fail "case $n was not intake-deduplicated"
done

[ "${#keys[@]}" -eq 10 ] || fail "expected ten keys"
all=$(run list case-1)
case "$all" in
  *"private raw evidence"*) fail 'raw evidence leaked to status output' ;;
esac
printf '%s\n' "$all" | grep -F 'cause=unknown' >/dev/null || fail 'unknown cause was not represented explicitly'
printf '%s\n' "$all" | grep -F 'evidence=sha256:' >/dev/null || fail 'evidence digest missing'

[ "$(run report case-1 "${keys[0]}")" = "already-report$(printf '\t')${keys[0]}" ] \
  || fail 'report was not idempotent'
[ "$(run review case-1 "${keys[0]}")" = "already-review$(printf '\t')${keys[0]}" ] \
  || fail 'review trigger was not idempotent'
run resolve case-1 "${keys[0]}" 'reviewed without asserting a cause' >/dev/null
[ "$(run resolve case-1 "${keys[0]}")" = "already-resolved$(printf '\t')${keys[0]}" ] \
  || fail 'resolution was not idempotent'

# Existing classifier semantics must surface the new intake/report events.
classifier="$ROOT/bin/fm-classify-lib.sh"
unset FM_CAPTAIN_RE
reflex_line='reflex-intake [key=reflex-test] [instance=x] [cause=unknown] [evidence=sha256:abc]: suspicion'
# shellcheck source=/dev/null
. "$classifier"
status_is_captain_relevant "$reflex_line" || fail 'reflex intake was not captain-relevant'
pass 'ten synthetic cases preserve lifecycle, privacy, deduplication, and explicit resolution'
