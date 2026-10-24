#!/usr/bin/env bash
# tests/fm-watch-stuck-replacement.test.sh - honest watcher beacon and bounded
# replacement of a live-but-stuck watcher (the 2026-10-24 night blindness: a
# watcher folding multi-MB status journals kept its pid but its beacon went
# stale for hours, and a new arm refused to replace it).
#
# Real processes, no harness. Fixture is a realistic home: a status journal over
# 5 MB of keyed decisions and a handled-inbox directory of 3000 files.
#   - the fold touches the beacon while it runs (it never did);
#   - a frozen watcher of THIS home with a stale beacon is replaced;
#   - a second replacement inside the window is refused;
#   - a replacement that repeats inside the loud window surfaces a wake;
#   - a live holder that is not this home's watcher is never killed.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-stuck-replacement-tests)

watch_env() {  # <state> <fakebin> -- cmd...
  local state=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@"
}

start_frozen_watcher() {  # <state> <fakebin> ; sets FROZEN_PID
  local state=$1 fakebin=$2 i=0
  watch_env "$state" "$fakebin" "$WATCH" > "$state/../frozen.out" 2>&1 &
  FROZEN_PID=$!
  while [ "$i" -lt 100 ] && [ ! -s "$state/.watch.lock/pid-identity" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$state/.watch.lock/pid-identity" ] || fail "first watcher never published its lock identity"
  kill -STOP "$FROZEN_PID"
  touch -t 200001010000 "$state/.last-watcher-beat"
}

test_fold_touches_beacon_while_running() {
  local dir state beat journal i n m1 m2 changes=0 pid last
  dir=$(make_case beat)
  state="$dir/state"
  beat="$state/.last-beat"
  journal="$state/big.status"
  mkdir -p "$state/big-task.inbox/handled"
  i=0
  while [ "$i" -lt 3000 ]; do
    : > "$state/big-task.inbox/handled/r$i.md"
    i=$((i + 1))
  done
  # ~5.2 MB: keyed decisions padded to ~800 bytes per line, like the real log.
  awk 'BEGIN { pad = sprintf("%760s", ""); gsub(/ /, "x", pad); for (i = 1; i <= 6500; i++) printf "needs-decision [key=k%d]: %s\n", i % 40, pad }' > "$journal"
  n=$(wc -c < "$journal")
  [ "$n" -ge 5000000 ] || fail "fixture journal is only $n bytes"
  printf 'kind=ship\n' > "$state/big.meta"
  touch -t 200001010000 "$beat"
  (
    FM_BEAT_FILE="$beat" FM_BEAT_PROGRESS_SECONDS=1
    _fm_status_open_decision_origins "$journal" ship > /dev/null 2>&1
  ) &
  pid=$!
  m1=$(fm_path_mtime "$beat")
  i=0
  while [ "$i" -lt 12 ]; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || break
    m2=$(fm_path_mtime "$beat")
    [ "$m2" != "$m1" ] && { changes=$((changes + 1)); m1=$m2; }
    i=$((i + 1))
  done
  last=$(kill -0 "$pid" 2>/dev/null && echo running || echo finished)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$last" = running ] || [ "$changes" -ge 1 ] || fail "fold finished too early to prove anything"
  [ "$changes" -ge 2 ] || fail "beacon advanced only $changes time(s) during a multi-MB fold (stale beacon: the watcher looks dead)"
  pass "a multi-MB fold keeps the watcher beacon fresh ($changes advances)"
}

test_stuck_watcher_replaced_once() {
  local dir state fakebin out err old new status=0 lines
  dir=$(make_case replace)
  state="$dir/state"
  fakebin="$dir/fakebin"
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  out="$dir/new.out"
  err="$dir/new.err"
  watch_env "$state" "$fakebin" "$WATCH" > "$out" 2> "$err" &
  new=$!
  i=0
  while [ "$i" -lt 100 ] && [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" != "$new" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$old" 2>/dev/null && fail "the stuck watcher is still alive after replacement"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$new" ] || fail "the replacement does not hold the lock"
  grep -F 'replacing stuck watcher' "$err" > /dev/null || fail "replacement was not announced"
  lines=$(wc -l < "$state/.watcher-replace.log")
  [ "$lines" -eq 1 ] || fail "expected one ledger line, got $lines"
  [ ! -e "$state/.watcher-replace-loud" ] || fail "a first replacement must not be loud"
  kill "$new" 2>/dev/null || true
  wait "$new" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  pass "a frozen stale watcher of this home is replaced exactly once"

  # Second replacement inside the window is refused.
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  watch_env "$state" "$fakebin" "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "a second replacement inside the window was allowed"
  grep -F 'one replacement per' "$err" > /dev/null || fail "the window refusal was not explained"
  kill -0 "$old" 2>/dev/null || fail "the second stuck watcher was killed despite the window"
  kill -KILL "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  pass "a second replacement inside the window is refused loudly"
}

test_repeated_replacement_is_loud() {
  local dir state fakebin out err old new now i=0
  dir=$(make_case loud)
  state="$dir/state"
  fakebin="$dir/fakebin"
  now=$(date +%s)
  printf '%s\t999\t400\n' "$((now - 2000))" > "$state/.watcher-replace.log"
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  out="$dir/new.out"
  err="$dir/new.err"
  FM_WATCHER_REPLACE_WINDOW=900 watch_env "$state" "$fakebin" "$WATCH" > "$out" 2> "$err" &
  new=$!
  while [ "$i" -lt 100 ] && ! grep -F 'replaced twice in a row' "$out" > /dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -F 'LOUD' "$err" > /dev/null || fail "second replacement did not announce LOUD"
  grep -F 'replaced twice in a row' "$out" > /dev/null || fail "no wake carried the repeated replacement to the captain"
  kill "$new" 2>/dev/null || true
  wait "$new" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  pass "two replacements in a row surface a wake"
}

test_foreign_holder_is_never_killed() {
  local dir state fakebin holder status=0
  dir=$(make_case foreign)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sleep 60 &
  holder=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$holder" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  watch_env "$state" "$fakebin" "$WATCH" > "$dir/out" 2> "$dir/err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher accepted a holder it cannot identify"
  kill -0 "$holder" 2>/dev/null || fail "a holder without this home's identity was killed"
  grep -F 'heartbeat is stale' "$dir/err" > /dev/null || fail "the unchanged refusal message is gone"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a live holder without this home's lock identity is never killed"
}

test_fold_touches_beacon_while_running
test_stuck_watcher_replaced_once
test_repeated_replacement_is_loud
test_foreign_holder_is_never_killed
