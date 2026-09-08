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
run() { FM_STATE_OVERRIDE="$state" FM_HOME="$TMP_ROOT" REFLEX_MAX_SCAN_BYTES="${REFLEX_MAX_SCAN_BYTES:-131072}" "$REPORTER" "$@"; }

keys=()
causes=(unknown timeout transport malformed stale)
for n in $(seq 1 10); do
  cause=${causes[$(( (n - 1) % ${#causes[@]} ))]}
  out=$(run intake "case-$n" "worker-$n" "$cause" "private raw evidence case $n")
  key=${out#*$'\t'}
  keys+=("$key")
  run report "case-$n" "$key" >/dev/null
  run review "case-$n" "$key" >/dev/null
  [ "$(run intake "case-$n" "worker-$n" "$cause" "private raw evidence case $n")" = "already-intake$(printf '\t')$key" ] \
    || fail "case $n was not intake-deduplicated"
done

[ "${#keys[@]}" -eq 10 ] || fail "expected ten keys"

# Existing ordinary status and distinct evidence must not suppress intake.
printf '%s\n' 'signal [key=ordinary]: unrelated status event' > "$state/existing.status"
first=$(run intake existing worker-existing unknown 'first distinct evidence')
second=$(run intake existing worker-existing unknown 'second distinct evidence')
[ "${first#*$'\t'}" != "${second#*$'\t'}" ] || fail 'distinct suspicions reused a key'
[ "$(wc -l < "$state/existing.status")" -eq 3 ] || fail 'existing status file lost distinct suspicion'

# Unknown resolution keys must not close unrelated native decisions.
printf '%s\n' 'needs-decision [key=ordinary-decision]: keep this decision open' > "$state/unrelated.status"
if run resolve unrelated ordinary-decision >/dev/null 2>&1; then
  fail 'unknown reflex key was accepted for resolution'
fi
grep -F 'needs-decision [key=ordinary-decision]' "$state/unrelated.status" >/dev/null \
  || fail 'unknown resolution mutated unrelated native decision'

# A prose mention is not lifecycle ownership, and must not close a native decision.
spoof_key=reflex-0123456789abcdef01234567
printf '%s\n' "needs-decision [key=$spoof_key]: quoted reflex-intake [key=$spoof_key] text" > "$state/spoof.status"
if run resolve spoof "$spoof_key" >/dev/null 2>&1; then
  fail 'embedded reflex intake text was accepted as ownership'
fi
[ "$(wc -l < "$state/spoof.status")" -eq 1 ] || fail 'spoof resolution mutated native decision'

# Contending identical intakes must serialize to one durable suspicion.
contended_pids=()
for n in $(seq 1 20); do
  run intake contended worker unknown 'same concurrent evidence' >/dev/null &
  contended_pids+=("$!")
done
for pid in "${contended_pids[@]}"; do wait "$pid" || fail 'contended intake failed'; done
[ "$(grep -c '^reflex-intake ' "$state/contended.status")" -eq 1 ] \
  || fail 'contended identical intakes appended duplicates'

# Bounded refusal must not forget an aged lifecycle and admit a duplicate.
old_max=${REFLEX_MAX_SCAN_BYTES:-131072}
REFLEX_MAX_SCAN_BYTES=512
aged=$(run intake aged worker unknown 'aged evidence')
aged_key=${aged#*$'\t'}
run report aged "$aged_key" >/dev/null
run review aged "$aged_key" >/dev/null
printf '%s\n' $(seq 1 100) >> "$state/aged.status"
if run resolve aged "$aged_key" >/dev/null 2>&1; then
  fail 'aged lifecycle was resolved after bounded history was lost'
fi
if run intake aged worker unknown 'aged evidence' >/dev/null 2>&1; then
  fail 'aged lifecycle admitted duplicate after bounded refusal'
fi
REFLEX_MAX_SCAN_BYTES=$old_max

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

# Reflex review uses the native decision fold, including its native close verb.
native_status="$TMP_ROOT/native.status"
native_key=reflex-aaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' "needs-decision [key=$native_key]: reflex review requested" > "$native_status"
status_open_decisions "$native_status" | grep -F "$native_key" >/dev/null \
  || fail 'reflex review was not present in native open decisions'
printf '%s\n' "resolved [key=$native_key]: reviewed" >> "$native_status"
if status_open_decisions "$native_status" | grep -F "$native_key" >/dev/null; then
  fail 'native decision fold did not close reflex review'
fi
pass 'ten synthetic cases preserve lifecycle, privacy, deduplication, and explicit resolution'
