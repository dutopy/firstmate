#!/usr/bin/env bash
# Behavior tests for the anti-drift wiring in bin/fm-watch.sh, driven through a
# real watcher subprocess: the detached producer kick, the cached heartbeat
# reader that raises a `check:` wake, its ordering relative to the status
# backstop, and the milestone kick on a done: status line. The producer,
# checkpoint script and cache readers are the real ones; git and the forge are
# fixtures. The heartbeat reader itself must never run git or reach the forge.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-antidrift)
fm_git_identity

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# A home whose state dir is its own (so the registry is inventoried) with one
# registered project that has no upstream.
make_home_case() {  # <name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/data" "$dir/projects/lonely" "$dir/config"
  git -C "$dir/projects/lonely" init -q -b main
  printf 'a\n' > "$dir/projects/lonely/a.txt"
  git -C "$dir/projects/lonely" add -A
  git -C "$dir/projects/lonely" commit -qm base
  printf -- '- lonely - drift fixture (added 2026-01-01)\n' > "$dir/data/projects.md"
  printf '%s\n' "$dir"
}

start_watch() {  # <dir> <out> [env...]
  local dir=$1 out=$2
  shift 2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 env "$@" "$WATCH" > "$out" &
}

test_heartbeat_raises_a_check_wake_for_new_drift_once() {
  local dir out pid
  dir=$(make_home_case hb-news); out="$dir/watch.out"
  start_watch "$dir" "$out" FM_HEARTBEAT=2
  pid=$!
  wait_for_exit "$pid" 150 || fail "the heartbeat never raised the anti-drift wake: $(cat "$out")"
  assert_contains "$(cat "$out")" "check: antidrift: no-upstream 1 (lonely)" "the wake reason is the one coalesced line"
  assert_contains "$(cat "$dir/state/.wake-queue")" "antidrift" "the wake is durable before it is reported"
  assert_present "$dir/state/.antidrift-reported" "the line is marked reported"
  : > "$out"
  start_watch "$dir" "$out" FM_HEARTBEAT=2
  pid=$!
  sleep 6
  assert_not_contains "$(cat "$out")" "antidrift" "the same line is not reported twice"
  reap "$pid"
  pass "fm-watch: the heartbeat raises one check wake per new drift line"
}

test_heartbeat_reader_makes_no_git_or_forge_call() {
  local dir out pid sig
  dir=$(make_home_case hb-pure); out="$dir/watch.out"
  mkdir -p "$dir/state"
  printf 'fm-antidrift-v1\nepoch=%s\nline=antidrift: no-upstream 1 (staged)\n' "$(date +%s)" > "$dir/state/.antidrift"
  printf '%s\n' "$(($(date +%s) + 999999))" > "$dir/state/.antidrift-next"
  sig=$(wc -c "$dir/state"/*.status 2>/dev/null | cksum)
  printf '%s\n' "$sig" > "$dir/state/.antidrift-sig"
  for t in git gh-axi no-mistakes; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\nexit 1\n' "$t" "$dir" > "$dir/fakebin/$t"
    chmod +x "$dir/fakebin/$t"
  done
  start_watch "$dir" "$out" FM_HEARTBEAT=2
  pid=$!
  wait_for_exit "$pid" 150 || fail "the staged line never woke: $(cat "$out")"
  assert_contains "$(cat "$out")" "(staged)" "the staged cached line was reported"
  if [ -f "$dir/calls.log" ] && grep -Eq '^(gh-axi|no-mistakes) ' "$dir/calls.log"; then
    fail "the heartbeat path reached the forge: $(cat "$dir/calls.log")"
  fi
  pass "fm-watch: the heartbeat reads the cache only and never reaches the forge"
}

test_status_backstop_is_not_skipped_when_drift_is_pending() {
  local dir out pid sig
  dir=$(make_home_case hb-both); out="$dir/watch.out"
  printf 'working: setup\nneeds-decision: pick A or B\nworking: tidying\n' > "$dir/state/miss.status"
  sig=$(LC_ALL=C wc -c < "$dir/state/miss.status" | tr -d '[:space:]')
  prime_status_seen "$dir/state" "$dir/state/miss.status" 2>/dev/null || true
  printf 'fm-antidrift-v1\nepoch=%s\nline=antidrift: no-upstream 1 (staged)\n' "$(date +%s)" > "$dir/state/.antidrift"
  printf '%s\n' "$(($(date +%s) + 999999))" > "$dir/state/.antidrift-next"
  printf '%s\n' "$(wc -c "$dir/state"/*.status 2>/dev/null | cksum)" > "$dir/state/.antidrift-sig"
  # the check cadence is not due, so the heartbeat is what carries both rows
  touch "$dir/state/.last-check"
  start_watch "$dir" "$out" FM_HEARTBEAT=2
  pid=$!
  wait_for_exit "$pid" 150 || fail "no wake with a pending decision and pending drift"
  assert_contains "$(cat "$dir/state/.wake-queue")" "antidrift" "the drift row is enqueued"
  assert_contains "$(cat "$dir/state/.wake-queue")" "heartbeat" "the status backstop still wakes"
  : "$sig"
  pass "fm-watch: the status backstop still wakes when drift is pending too"
}

test_a_done_status_line_kicks_the_producer_and_checkpoints() {
  local dir out pid i shadow slot repo n
  dir=$(make_home_case milestone); out="$dir/watch.out"
  slot="$dir/pool/t1"; mkdir -p "$slot/repo"
  repo="$slot/repo"
  git -C "$repo" init -q -b fm/t1
  printf 'a\n' > "$repo/a.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm base
  printf 'worktree=%s\nkind=ship\nproject=%s/projects/none\n' "$(cd "$repo" && pwd -P)" "$dir" > "$dir/state/t1.meta"
  printf 'task=t1\nhome=%s\n' "$dir" > "$slot/.fm-slot-owner"
  printf 'working: start\n' > "$dir/state/t1.status"
  prime_status_seen "$dir/state" "$dir/state/t1.status" 2>/dev/null || true
  start_watch "$dir" "$out" FM_HEARTBEAT=999999
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    shadow=$(find "$dir/state/wip" -maxdepth 1 -name '*.git' 2>/dev/null | head -n 1)
    [ -z "$shadow" ] || break
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$shadow" ] || { reap "$pid"; fail "the producer never made the first checkpoint"; }
  n=$(git --git-dir="$shadow" rev-list --all --count)
  printf 'edit\n' >> "$repo/a.txt"
  printf 'done: finished the packet\n' >> "$dir/state/t1.status"
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(git --git-dir="$shadow" rev-list --all --count)" -gt "$n" ] && break
    sleep 0.1; i=$((i + 1))
  done
  reap "$pid"
  [ "$(git --git-dir="$shadow" rev-list --all --count)" -gt "$n" ] || fail "a done: line must trigger an immediate milestone checkpoint"
  pass "fm-watch: a done: status line kicks the producer into a milestone checkpoint"
}

# A stub root: a copy of bin/ whose producer is replaced, so the watcher's launch
# decisions can be observed. The watcher locates its siblings from its own path.
make_stub_root() {  # <dir> -> prints the stub watcher path
  local dir=$1 root="$1/stubroot"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  cat > "$root/bin/fm-antidrift-check.sh" <<'SH'
#!/usr/bin/env bash
echo "launch" >> "$STUB_LOG"
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
exit 0
SH
  chmod +x "$root/bin/fm-antidrift-check.sh"
  printf '%s\n' "$root/bin/fm-watch.sh"
}

start_stub_watch() {  # <dir> <watcher> <out> [env...]
  local dir=$1 watcher=$2 out=$3
  shift 3
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 STUB_LOG="$dir/stub.log" env "$@" "$watcher" > "$out" &
}

# A3/B1/C3: a producer that dies before publishing is relaunched once per tick, not once per poll.
test_a_producer_that_never_publishes_is_launched_once_per_tick() {
  local dir out pid watcher n
  dir=$(make_home_case due-loop); out="$dir/watch.out"; watcher=$(make_stub_root "$dir")
  : > "$dir/stub.log"
  start_stub_watch "$dir" "$watcher" "$out" FM_CHECK_INTERVAL=5 FM_HEARTBEAT=999999
  pid=$!
  sleep 11
  reap "$pid"
  n=$(wc -l < "$dir/stub.log" | tr -d ' ')
  [ "$n" -ge 1 ] && [ "$n" -le 4 ] || fail "a producer that never publishes must be launched about once per 5 s tick, saw $n launches in 11 s"
  pass "fm-watch: a silent producer is relaunched once per tick, not on every poll"
}

# A4/B2: a status change that arrives while a producer runs is kept pending, not lost.
test_a_status_change_during_a_running_producer_is_not_lost() {
  local dir out pid watcher n i
  dir=$(make_home_case lost-kick); out="$dir/watch.out"; watcher=$(make_stub_root "$dir")
  printf 'worktree=%s\nkind=ship\nproject=%s\n' "$dir" "$dir" > "$dir/state/t1.meta"
  printf 'working: start\n' > "$dir/state/t1.status"
  prime_status_seen "$dir/state" "$dir/state/t1.status" 2>/dev/null || true
  # the next-due epoch is far away, so only a status change can launch the producer
  printf '%s\n' "$(($(date +%s) + 999999))" > "$dir/state/.antidrift-next"
  : > "$dir/stub.log"
  start_stub_watch "$dir" "$watcher" "$out" FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 STUB_SLEEP=4 \
    "FM_FAKE_CREW_STATE=state: working · source: run-step · validating (running)"
  pid=$!
  sleep 2
  printf 'working: a status change while the producer was running\n' >> "$dir/state/t1.status"
  i=0
  while [ "$i" -lt 150 ]; do
    n=$(wc -l < "$dir/stub.log" | tr -d ' ')
    [ "$n" -ge 2 ] && break
    sleep 0.1; i=$((i + 1))
  done
  reap "$pid"
  [ "${n:-0}" -ge 2 ] || fail "the status change made while the first producer ran must trigger a second launch after it exits (launches: ${n:-0})"
  pass "fm-watch: a status change during a running producer is kept pending and launches the next one"
}

# A5/B6: a new drift line is also delivered on the check cadence, not only on a backed-off heartbeat.
test_new_drift_is_delivered_on_the_check_cadence() {
  local dir out pid
  dir=$(make_home_case check-cadence); out="$dir/watch.out"
  printf 'fm-antidrift-v1\nepoch=%s\nline=antidrift: no-upstream 1 (staged)\n' "$(date +%s)" > "$dir/state/.antidrift"
  printf '%s\n' "$(($(date +%s) + 999999))" > "$dir/state/.antidrift-next"
  printf '%s\n' "$(wc -c "$dir/state"/*.status 2>/dev/null | cksum)" > "$dir/state/.antidrift-sig"
  start_watch "$dir" "$out" FM_CHECK_INTERVAL=2 FM_HEARTBEAT=999999
  pid=$!
  wait_for_exit "$pid" 120 || fail "the drift line was not delivered on the check cadence: $(cat "$out")"
  assert_contains "$(cat "$out")" "(staged)" "the check cadence carries the new line"
  assert_contains "$(cat "$dir/state/.wake-queue")" "antidrift" "the row is durable"
  pass "fm-watch: new drift is delivered on the check cadence as well as on heartbeats"
}

# B6 second claim: delivering drift from the absorbed heartbeat branch leaves the heartbeat streak reset.
test_the_heartbeat_streak_is_reset_by_a_drift_wake() {
  local dir out pid
  dir=$(make_home_case streak); out="$dir/watch.out"
  printf 'fm-antidrift-v1\nepoch=%s\nline=antidrift: no-upstream 1 (staged)\n' "$(date +%s)" > "$dir/state/.antidrift"
  printf '%s\n' "$(($(date +%s) + 999999))" > "$dir/state/.antidrift-next"
  printf '%s\n' "$(wc -c "$dir/state"/*.status 2>/dev/null | cksum)" > "$dir/state/.antidrift-sig"
  printf '2\n' > "$dir/state/.heartbeat-streak"
  start_watch "$dir" "$out" FM_HEARTBEAT=1 FM_CHECK_INTERVAL=999999
  pid=$!
  wait_for_exit "$pid" 150 || fail "no drift wake from the heartbeat: $(cat "$out")"
  assert_equals 0 "$(cat "$dir/state/.heartbeat-streak")" "a drift wake resets the heartbeat backoff like any non-heartbeat wake"
  pass "fm-watch: the heartbeat streak is reset by a drift wake"
}

test_heartbeat_raises_a_check_wake_for_new_drift_once
test_heartbeat_reader_makes_no_git_or_forge_call
test_status_backstop_is_not_skipped_when_drift_is_pending
test_a_done_status_line_kicks_the_producer_and_checkpoints
test_a_producer_that_never_publishes_is_launched_once_per_tick
test_a_status_change_during_a_running_producer_is_not_lost
test_new_drift_is_delivered_on_the_check_cadence
test_the_heartbeat_streak_is_reset_by_a_drift_wake
