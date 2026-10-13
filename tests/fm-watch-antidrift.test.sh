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
  printf 'fm-antidrift-v1\nepoch=1\nline=antidrift: no-upstream 1 (staged)\n' > "$dir/state/.antidrift"
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
  printf 'fm-antidrift-v1\nepoch=1\nline=antidrift: no-upstream 1 (staged)\n' > "$dir/state/.antidrift"
  printf '%s\n' "$(($(date +%s) + 999999))" > "$dir/state/.antidrift-next"
  printf '%s\n' "$(wc -c "$dir/state"/*.status 2>/dev/null | cksum)" > "$dir/state/.antidrift-sig"
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

test_heartbeat_raises_a_check_wake_for_new_drift_once
test_heartbeat_reader_makes_no_git_or_forge_call
test_status_backstop_is_not_skipped_when_drift_is_pending
test_a_done_status_line_kicks_the_producer_and_checkpoints
