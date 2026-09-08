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
scenarios=(
  'missing-heartbeat|worker-heartbeat|timeout|heartbeat absent after expected interval'
  'duplicate-delivery|worker-queue|transport|same event delivered twice'
  'malformed-payload|worker-parser|malformed|payload shape rejected by parser'
  'stale-worker|worker-runtime|stale|worker timestamp predates current lease'
  'unknown-cause|worker-unknown|unknown|observation lacks enough evidence to classify cause'
  'unexpected-restart|worker-runtime|unknown|worker restarted without matching completion'
  'task-drift|worker-task|unknown|reported task identity differs from expected task'
  'late-report|worker-report|stale|report arrived after lifecycle moved on'
  'partial-output|worker-output|malformed|output ended before a complete record'
  'repeated-review|worker-review|transport|review trigger repeated by delivery retry'
)
for n in $(seq 1 10); do
  IFS='|' read -r case_name instance cause observation <<< "${scenarios[$((n - 1))]}"
  out=$(run intake "$case_name" "$instance" "$cause" "$observation")
  key=${out#*$'\t'}
  keys+=("$key")
  run report "$case_name" "$key" >/dev/null
  run review "$case_name" "$key" >/dev/null
  [ "$(run intake "$case_name" "$instance" "$cause" "$observation")" = "already-intake$(printf '\t')$key" ] \
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

# Report and review apply the same structural ownership check as resolve.
printf '%s\n' "reflex-intake [key=$spoof_key] malformed" > "$state/malformed.status"
if run report malformed "$spoof_key" >/dev/null 2>&1; then
  fail 'malformed intake was accepted for report'
fi
if run review malformed "$spoof_key" >/dev/null 2>&1; then
  fail 'malformed intake was accepted for review'
fi
[ "$(wc -l < "$state/malformed.status")" -eq 1 ] || fail 'malformed lifecycle was mutated'

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

# A resolved lifecycle is also refused when its history is no longer complete;
# bounded scanning must not silently treat it as a new suspicion.
resolved_aged=$(run intake aged-resolved worker unknown 'resolved aged evidence')
resolved_aged_key=${resolved_aged#*$'\t'}
run resolve aged-resolved "$resolved_aged_key" >/dev/null
printf '%s\n' $(seq 1 100) >> "$state/aged-resolved.status"
if REFLEX_MAX_SCAN_BYTES=512 run intake aged-resolved worker unknown 'resolved aged evidence' >/dev/null 2>&1; then
  fail 'aged resolved lifecycle admitted duplicate after bounded refusal'
fi
REFLEX_MAX_SCAN_BYTES=$old_max

all=$(run list unknown-cause)
case "$all" in
  *"private raw evidence"*) fail 'raw evidence leaked to status output' ;;
esac
printf '%s\n' "$all" | grep -F 'cause=unknown' >/dev/null || fail 'unknown cause was not represented explicitly'
printf '%s\n' "$all" | grep -F 'evidence=sha256:' >/dev/null || fail 'evidence digest missing'
printf '%s\n' 'needs-decision [key=ordinary]: unrelated native decision' >> "$state/unknown-cause.status"
all=$(run list unknown-cause)
printf '%s\n' "$all" | grep -F 'key=ordinary' >/dev/null && fail 'unrelated native decision leaked into reflex list'

# Listing refuses oversized histories instead of emitting unbounded output.
printf 'signal [key=ordinary]: %*s\n' 2048 '' | tr ' ' x >> "$state/list-bound.status"
if REFLEX_MAX_SCAN_BYTES=512 run list list-bound >/dev/null 2>&1; then
  fail 'oversized list history did not fail closed'
fi

[ "$(run report missing-heartbeat "${keys[0]}")" = "already-report$(printf '\t')${keys[0]}" ] \
  || fail 'report was not idempotent'
[ "$(run review missing-heartbeat "${keys[0]}")" = "already-review$(printf '\t')${keys[0]}" ] \
  || fail 'review trigger was not idempotent'
run resolve missing-heartbeat "${keys[0]}" 'reviewed without asserting a cause' >/dev/null
[ "$(run resolve missing-heartbeat "${keys[0]}")" = "already-resolved$(printf '\t')${keys[0]}" ] \
  || fail 'resolution was not idempotent'

# Existing classifier semantics must surface the new intake/report events.
classifier="$ROOT/bin/fm-classify-lib.sh"
unset FM_CAPTAIN_RE
reflex_line='reflex-intake [key=reflex-test] [instance=x] [cause=unknown] [evidence=sha256:abc]: suspicion'
# shellcheck source=/dev/null
. "$classifier"
status_is_captain_relevant "$reflex_line" || fail 'reflex intake was not captain-relevant'

# Reporter output must feed the native decision fold, including its native close verb.
native_status="$state/native.status"
native_out=$(run intake native worker-native unknown 'native fold integration evidence')
native_key=${native_out#*$'\t'}
run report native "$native_key" >/dev/null
run review native "$native_key" >/dev/null
status_open_decisions "$native_status" | grep -F "$native_key" >/dev/null \
  || fail 'reflex review was not present in native open decisions'
run resolve native "$native_key" reviewed >/dev/null
if status_open_decisions "$native_status" | grep -F "$native_key" >/dev/null; then
  fail 'native decision fold did not close reporter review'
fi
pass 'ten synthetic cases preserve lifecycle, privacy, deduplication, and explicit resolution'
