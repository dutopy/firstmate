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
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 exec "$@"
}

start_frozen_watcher() {  # <state> <fakebin> ; sets FROZEN_PID
  local state=$1 fakebin=$2 i=0
  (
    # Stop only after the beacon write finishes: stopping the shell while its
    # touch child is running lets that child overwrite our aged fixture later.
    # shellcheck disable=SC2329 # Exported into the real watcher below.
    touch() {
      command touch "$@" || return 1
      if [ "$#" -eq 1 ] && [ "$1" = "$FM_STATE_OVERRIDE/.last-watcher-beat" ]; then
        kill -STOP "$$"
      fi
    }
    export -f touch
    watch_env "$state" "$fakebin" "$WATCH"
  ) > "$state/../frozen.out" 2>&1 &
  FROZEN_PID=$!
  while [ "$i" -lt 100 ]; do
    case "$(ps -p "$FROZEN_PID" -o stat= 2>/dev/null)" in *T*) break ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 100 ] || fail "first watcher never stopped after writing its beacon"
  [ -s "$state/.watch.lock/pid-identity" ] || fail "first watcher never published its lock identity"
  [ "$(cat "$state/.watch.lock/pid")" = "$FROZEN_PID" ] || fail "background pid is not the watcher"
  touch -t 200001010000 "$state/.last-watcher-beat" || fail "could not age frozen watcher's beacon"
}

test_status_scans_touch_beacon_while_running() {
  local dir state beat journal mode i n m1 m2 changes pid last too_fast
  for mode in fold span; do
    dir=$(make_case "beat-$mode")
    state="$dir/state"
    beat="$state/.last-beat"
    journal="$state/big.status"
    mkdir -p "$state/big-task.inbox/handled"
    i=0
    while [ "$i" -lt 3000 ]; do
      : > "$state/big-task.inbox/handled/r$i.md"
      i=$((i + 1))
    done
    awk -v mode="$mode" 'BEGIN {
      pad = sprintf("%800s", ""); gsub(/ /, "x", pad)
      for (i = 1; i <= 6500; i++) {
        if (mode == "fold") printf "needs-decision [key=k%d]: %s\n", i % 40, pad
        else printf "working: %s\n", pad
      }
    }' > "$journal"
    n=$(wc -c < "$journal")
    [ "$n" -ge 5000000 ] || fail "fixture journal is only $n bytes"
    printf 'kind=ship\n' > "$state/big.meta"
    touch -t 200001010000 "$beat"
    (
      FM_BEAT_FILE="$beat" FM_BEAT_LAST=$SECONDS
      # Keep both scans busy across two real refresh intervals even on fast
      # runners. Delegate to the real helper so its fixed cadence is tested.
      beat_impl=$(declare -f fm_beat_progress)
      eval "${beat_impl/fm_beat_progress/fm_test_real_beat_progress}"
      fm_beat_progress() {
        sleep 1
        fm_test_real_beat_progress
      }
      if [ "$mode" = fold ]; then
        _fm_status_open_decision_origins "$journal" ship
      else
        status_span_first_actionable_record "$journal" 0
      fi
    ) > "$dir/result" 2> "$dir/err" &
    pid=$!
    m1=$(fm_path_mtime "$beat")
    i=0
    changes=0
    too_fast=0
    while [ "$i" -lt 30 ] && [ "$changes" -lt 2 ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || break
      m2=$(fm_path_mtime "$beat")
      if [ "$m2" != "$m1" ]; then
        if [ "$changes" -gt 0 ] && [ $((m2 - m1)) -lt 5 ]; then too_fast=1; fi
        changes=$((changes + 1))
        m1=$m2
      fi
      i=$((i + 1))
    done
    last=$(kill -0 "$pid" 2>/dev/null && echo running || echo finished)
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ "$last" = running ] || [ "$changes" -ge 1 ] || fail "$mode finished too early to prove anything"
    [ "$changes" -ge 2 ] || fail "beacon advanced only $changes time(s) during a multi-MB $mode"
    [ "$too_fast" -eq 0 ] || fail "$mode refreshed the beacon faster than the fixed 5-second cadence"
    pass "a multi-MB $mode keeps the watcher beacon fresh at the default cadence ($changes advances)"
  done
}

test_stuck_watcher_replaced_once() {
  local dir state fakebin out err old new status=0 lines i
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
  while [ "$i" -lt 100 ] && [ ! -s "$state/.watcher-replace.log" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$state/.watcher-replace.log" ] || fail "replacement budget was not reserved"
  kill -0 "$old" 2>/dev/null || fail "budget was not recorded before retiring the frozen watcher"
  (watch_env "$state" "$fakebin" "$WATCH") > "$dir/contender.out" 2> "$dir/contender.err" || true
  i=0
  while [ "$i" -lt 150 ] && ! grep -F 'check: rearm-resurface' "$out" > /dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$old" 2>/dev/null && fail "the stuck watcher is still alive after replacement"
  grep -F 'check: rearm-resurface' "$out" > /dev/null || fail "replacement did not deliver recovery"
  wait "$new" 2>/dev/null || fail "replacement recovery failed"
  awk -F '\t' -v pid="$new" '$1 == pid { found=1 } END { exit !found }' \
    "$state/.watch-deliveries.log" || fail "recovery was not delivered by the replacement pid"
  grep -F 'replacing stuck watcher' "$err" > /dev/null || fail "replacement was not announced"
  lines=$(wc -l < "$state/.watcher-replace.log")
  [ "$lines" -eq 1 ] || fail "expected one ledger line, got $lines"
  [ ! -e "$state/.watcher-replace-loud" ] || fail "a first replacement must not be loud"
  wait "$old" 2>/dev/null || true
  pass "a frozen stale watcher of this home is replaced exactly once"

  # Second replacement inside the window is refused.
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  (watch_env "$state" "$fakebin" "$WATCH") > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "a second replacement inside the window was allowed"
  grep -F 'one replacement per' "$err" > /dev/null || fail "the window refusal was not explained"
  kill -0 "$old" 2>/dev/null || fail "the second stuck watcher was killed despite the window"
  kill -KILL "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  pass "a second replacement inside the window is refused loudly"
}

test_repeated_replacement_is_loud() {
  local dir state fakebin out err old new now lines i=0
  dir=$(make_case loud)
  state="$dir/state"
  fakebin="$dir/fakebin"
  now=$(date +%s)
  while [ "$i" -lt 25 ]; do
    printf '%s\t999\t400\n' "$((now - 25200 - i))" >> "$state/.watcher-replace.log"
    i=$((i + 1))
  done
  printf '%s\t999\t400\n' "$((now - 2000))" >> "$state/.watcher-replace.log"
  cp "$state/.watcher-replace.log" "$dir/history"
  i=0
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  out="$dir/new.out"
  err="$dir/new.err"
  watch_env "$state" "$fakebin" "$WATCH" > "$out" 2> "$err" &
  new=$!
  while [ "$i" -lt 100 ] && ! grep -F 'replaced twice in a row' "$out" > /dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -F 'LOUD' "$err" > /dev/null || fail "second replacement did not announce LOUD"
  grep -F 'replaced twice in a row' "$out" > /dev/null || fail "no wake carried the repeated replacement to the captain"
  awk -F '\t' '$3 == "stale" && $4 == "watcher-replacement" && $5 ~ /replaced twice in a row/ { found=1 } END { exit !found }' \
    "$state/.wake-queue" || fail "repeated replacement was not durably queued"
  [ ! -e "$state/.watcher-replace-loud" ] || fail "delivered loud marker was not consumed"
  lines=$(wc -l < "$state/.watcher-replace.log")
  [ "$lines" -eq 27 ] || fail "replacement history was truncated"
  head -n 26 "$state/.watcher-replace.log" > "$dir/history-after"
  cmp "$dir/history" "$dir/history-after" || fail "replacement history was rewritten"
  wait "$new" 2>/dev/null || fail "loud replacement delivery failed"
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
  (watch_env "$state" "$fakebin" "$WATCH") > "$dir/out" 2> "$dir/err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher accepted a holder it cannot identify"
  kill -0 "$holder" 2>/dev/null || fail "a holder without this home's identity was killed"
  grep -F 'heartbeat is stale' "$dir/err" > /dev/null || fail "the unchanged refusal message is gone"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a live holder without this home's lock identity is never killed"
}

test_failed_budget_write_preserves_holder() {
  local dir state fakebin old status=0
  dir=$(make_case budget-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  mkdir "$state/.watcher-replace.log"
  (watch_env "$state" "$fakebin" "$WATCH") > "$dir/out" 2> "$dir/err" || status=$?
  [ "$status" -ne 0 ] || fail "replacement proceeded without a persisted budget"
  kill -0 "$old" 2>/dev/null || fail "budget write failure killed the holder"
  [ "$(cat "$state/.watch.lock/pid")" = "$old" ] || fail "budget write failure changed the holder"
  rmdir "$state/.watcher-replace.log"
  kill -CONT "$old"
  sleep 0.5
  kill -0 "$old" 2>/dev/null || fail "budget write failure sent a deferred TERM"
  kill -KILL "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  pass "failed budget persistence never signals the holder"
}

test_failed_loud_delivery_preserves_marker() {
  local dir state fakebin status=0
  dir=$(make_case loud-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  printf 'watcher replaced twice in a row\n' > "$state/.watcher-replace-loud"
  mkdir "$state/.wake-queue"
  (watch_env "$state" "$fakebin" "$WATCH") > "$dir/out" 2> "$dir/err" || status=$?
  [ "$status" -ne 0 ] || fail "failed loud queue write was ignored"
  [ -s "$state/.watcher-replace-loud" ] || fail "failed loud delivery lost the marker"
  rmdir "$state/.wake-queue"
  (watch_env "$state" "$fakebin" "$WATCH") > "$dir/retry.out" 2> "$dir/retry.err" || fail "loud delivery retry failed"
  grep -F 'stale: watcher replaced twice in a row' "$dir/retry.out" > /dev/null || fail "retained marker was not delivered"
  [ ! -e "$state/.watcher-replace-loud" ] || fail "successful retry retained the marker"
  pass "failed loud persistence retains the marker for the next arm"
}

test_failed_loud_publication_preserves_holder() {
  local dir state fakebin old now lines status=0
  dir=$(make_case loud-publication-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  now=$(date +%s)
  printf '%s\t999\t400\n' "$((now - 2000))" > "$state/.watcher-replace.log"
  start_frozen_watcher "$state" "$fakebin"
  old=$FROZEN_PID
  mkdir "$state/.watcher-replace-loud"
  (watch_env "$state" "$fakebin" "$WATCH") > "$dir/out" 2> "$dir/err" || status=$?
  [ "$status" -ne 0 ] || fail "replacement proceeded without a published loud marker"
  kill -0 "$old" 2>/dev/null || fail "loud publication failure killed the holder"
  [ "$(cat "$state/.watch.lock/pid")" = "$old" ] || fail "loud publication failure changed the holder"
  lines=$(wc -l < "$state/.watcher-replace.log")
  [ "$lines" -eq 2 ] || fail "loud publication failure lost the reserved budget"
  if grep -F 'LOUD' "$dir/err" > /dev/null; then fail "failed loud publication promised delivery"; fi
  # Remove the injected fault before resuming: a directory can satisfy -s,
  # causing the holder's ordinary loud-marker delivery to exit without TERM.
  rmdir "$state/.watcher-replace-loud"
  kill -CONT "$old"
  sleep 0.5
  kill -0 "$old" 2>/dev/null || fail "loud publication failure sent a deferred TERM"
  kill -KILL "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
  pass "failed loud publication preserves the holder and reserved budget"
}

test_status_scans_touch_beacon_while_running
test_failed_loud_publication_preserves_holder
test_failed_budget_write_preserves_holder
test_failed_loud_delivery_preserves_marker
test_stuck_watcher_replaced_once
test_repeated_replacement_is_loud
test_foreign_holder_is_never_killed
