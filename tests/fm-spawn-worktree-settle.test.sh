#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

# make_exec_fakebin <dir> <treehouse-mode> builds a fake tmux that actually RUNS
# the line sent for `treehouse get` in a shell (appending the echoed command and
# its output to a pane log that capture-pane returns), with a fake treehouse that
# either fails like a full pool (`fail`) or succeeds silently (`ok`). The pane's
# cwd is a counted FM_FAKE_PANE_PATH / FM_FAKE_PANE_STALE sequence as above.
make_exec_fakebin() {
  local dir=$1 mode=$2 fakebin
  fakebin=$(make_settle_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log="${FM_FAKE_PANE_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) cat "$log" 2>/dev/null; exit 0 ;;
  send-keys)
    for last; do :; done
    text=${*: -2:1}
    case "$text" in
      "treehouse get"*)
        printf '$ %s\n' "$text" >> "$log"
        bash -c "$text" >> "$log" 2>&1 ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  if [ "$mode" = fail ]; then
    cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
echo "error: all 24 worktrees are in use or dirty; raise max_trees" >&2
exit 1
SH
    chmod +x "$fakebin/treehouse"
  fi
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# run_exec_spawn <id> <wait-or-empty>: like run_settle_spawn but the pane log is
# per case and the isolation wait may be configured.
run_exec_spawn() {
  local id=$1 wait=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    FM_FAKE_PANE_LOG="$HOME_DIR/pane.log" \
    FM_SPAWN_ISOLATION_WAIT_SECS="${wait:-60}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

use_exec_fakebin() { # <mode>: swap the case's fake for the executing one; the pane sits in the project (never isolated) until it settles
  STALE_DIR=$PROJ_DIR
  FAKEBIN_DIR=$(make_exec_fakebin "$HOME_DIR/fake-exec" "$1")
}

# An allocator that fails is reported from its own exit status, with its message,
# long before the wait runs out - and is not reported as a timeout.
test_allocator_failure_is_surfaced_not_timed_out() {
  local rec id out status
  id=settle-alloc-fail-z5
  rec=$(make_settle_case settle-alloc-fail "$id" 0)
  read_settle_record "$rec"
  use_exec_fakebin fail
  WT_DIR=$PROJ_DIR
  out=$(run_exec_spawn "$id" "")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although treehouse get failed"$'\n'"$out"
  assert_contains "$out" "treehouse get failed (exit 1)" "allocator refusal was not reported as a refusal"
  assert_contains "$out" "all 24 worktrees are in use" "the allocator's own message did not reach the error"
  case "$out" in *"within"*) fail "an allocator refusal was reported as a wait timeout"$'\n'"$out" ;; esac
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a failing treehouse get is surfaced with its message instead of a bare timeout"
}

# A pane that never moves while get is silently running, plus a result file left
# by some other attempt, is a timeout - never a refusal or a success.
test_foreign_result_is_not_this_attempts_failure() {
  local rec id out status
  id=settle-foreign-z6
  rec=$(make_settle_case settle-foreign "$id" 0)
  read_settle_record "$rec"
  use_exec_fakebin ok
  printf '1\n' > "$HOME_DIR/state/.$id.treehouse-get.1.1.result"
  printf 'error: all 24 worktrees are in use (previous attempt)\n' > "$HOME_DIR/pane.log"
  WT_DIR=$PROJ_DIR
  out=$(run_exec_spawn "$id" 3)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never entered a worktree"
  assert_contains "$out" "did not enter an isolated worktree within 3s" "timeout was not reported as a timeout naming the configured wait"
  case "$out" in *"treehouse get failed"*) fail "a foreign result or stale scrollback was read as this attempt's failure" ;; esac
  pass "stale scrollback and another attempt's result are not this attempt's failure"
}

# The isolation wait defaults to 60s and honors FM_SPAWN_ISOLATION_WAIT_SECS: a
# pane that settles after more than 60 reads fails by default and succeeds when
# the wait is raised; a short configured wait bounds the polling.
test_isolation_wait_is_configurable() {
  local rec id out status reads
  id=settle-wait-z7
  rec=$(make_settle_case settle-wait-default "$id" 80)
  read_settle_record "$rec"
  use_exec_fakebin ok
  out=$(run_exec_spawn "$id" "")
  status=$?
  [ "$status" -ne 0 ] || fail "default wait accepted a pane that settled after 80 reads"
  assert_contains "$out" "within 60s" "default wait was not 60s"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 60 ] || fail "default wait polled $reads times, expected 60"

  id=settle-wait-z8
  rec=$(make_settle_case settle-wait-long "$id" 80)
  read_settle_record "$rec"
  use_exec_fakebin ok
  out=$(run_exec_spawn "$id" 100)
  status=$?
  expect_code 0 "$status" "a configured 100s wait should accept a slow isolated allocation"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "slow allocation did not record the isolated worktree"

  id=settle-wait-z9
  rec=$(make_settle_case settle-wait-short "$id" 100000)
  read_settle_record "$rec"
  use_exec_fakebin ok
  out=$(run_exec_spawn "$id" 5)
  status=$?
  [ "$status" -ne 0 ] || fail "short wait unexpectedly succeeded"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 5 ] || fail "a 5s wait polled $reads times"
  pass "the isolation wait defaults to 60s and honors FM_SPAWN_ISOLATION_WAIT_SECS"
}

test_invalid_isolation_wait_is_refused() {
  local rec id out status bad
  id=settle-badwait-z10
  rec=$(make_settle_case settle-badwait "$id" 0)
  read_settle_record "$rec"
  use_exec_fakebin ok
  for bad in 0 -5 abc 1.5 3601 007; do
    out=$(run_exec_spawn "$id" "$bad")
    status=$?
    [ "$status" -ne 0 ] || fail "invalid FM_SPAWN_ISOLATION_WAIT_SECS=$bad was accepted"
    assert_contains "$out" "FM_SPAWN_ISOLATION_WAIT_SECS must be a positive integer" "value $bad was refused without naming the setting"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused value $bad still published task metadata"
  done
  pass "a non-positive, non-integer, or over-long isolation wait is refused up front"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_allocator_failure_is_surfaced_not_timed_out
test_foreign_result_is_not_this_attempts_failure
test_isolation_wait_is_configurable
test_invalid_isolation_wait_is_refused

echo "# all fm-spawn-worktree-settle tests passed"
