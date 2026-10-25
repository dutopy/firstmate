#!/usr/bin/env bash
# Tests for the task-close -> guarded copy-return connection.
#
# `tasks-axi done` (alias `close`) is the public task-close command, and a
# launched task's close owes its copy return. bin/fm-tasks-axi.sh lands the
# close first, then runs bin/fm-teardown.sh <id> --after-close so the existing
# cleanup owner proves incarnation, ownership, landed work, and cleanliness
# before returning the copy. Teardown's refusal must preserve every copy that is
# dirty, unlanded, or owned by another task, and the close itself must stay
# authoritative through a refusal or a repeated/concurrent close.
#
# Matrix:
#   (a) clean landed owned copy                    -> return once, record removed
#   (b) dirty copy                                 -> close lands, copy preserved
#   (c) unlanded commit                            -> close lands, copy preserved
#   (d) pool slot reassigned to another task       -> copy and claim preserved
#   (e) failed copy return                         -> preserved, retry returns once
#   (f) repeated close                             -> one return, converged
#   (g) direct --after-close on an open row        -> refused, nothing changed
#   (h) secondmate record                          -> never torn down by a close
#   (i) close in another home's backlog            -> this home's copy preserved
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOSE=
TEARDOWN=
TMP_ROOT=$(fm_test_tmproot fm-task-close-copy-return)

# Teardown unconditionally runs bin/fm-remote-job-reap-orphans.sh, a
# machine-wide host process sweep by design. A synthetic teardown must never
# perform that scan, so every case here runs a disposable copy of the real bin/
# with only that one helper replaced by a fixture stub (the established
# test-root/bin pattern in tests/fm-teardown.test.sh). Production cleanup is
# untouched: the copied wrapper and teardown are the working-tree scripts.
setup_fixture_code_root() {
  local root="$TMP_ROOT/fixture-root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  cat > "$root/bin/fm-remote-job-reap-orphans.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$PWD" >> "${FM_FIXTURE_REAPER_LOG:?}"
exit 0
SH
  chmod +x "$root/bin/fm-remote-job-reap-orphans.sh"
  printf '%s\n' "$root"
}

FIXTURE_ROOT=$(setup_fixture_code_root)
CLOSE="$FIXTURE_ROOT/bin/fm-tasks-axi.sh"
TEARDOWN="$FIXTURE_ROOT/bin/fm-teardown.sh"

# Build a sandbox home plus a real project/origin and one task worktree.
#   $CASE/home/{state,data,config}/  the home
#   $CASE/home/.tasks.toml          markdown backlog config
#   $CASE/project/                  clone used as the task's project
#   $CASE/wt/                       the task worktree
#   $CASE/fakebin/                  treehouse/tmux/gh/no-mistakes stubs
#   $CASE/runtime.log               every stubbed runtime call
make_case() {  # <name>
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin"
  cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$dir/home/data/backlog.md"
  : > "$dir/runtime.log"

  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ] && [ "${FM_TREEHOUSE_FAIL_RETURN:-0}" = 1 ]; then
  printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
  printf ' <return-failed>' >> "${FM_RUNTIME_LOG:?}"
  printf '\n' >> "${FM_RUNTIME_LOG:?}"
  echo 'fixture: copy return failed' >&2
  exit 1
fi
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
case "${1:-}" in
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then
      printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"
    fi
    exit 0
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = runs ]; then exit 0; fi
exit 0
SH
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/tmux" \
    "$dir/fakebin/gh-axi" "$dir/fakebin/gh" "$dir/fakebin/no-mistakes"

  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m 'origin baseline'
  git -C "$dir/_seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true

  if [ "${2:-}" = pool ]; then
    # Treehouse-shaped pool slot: the task copy lives at <pool>/1/project and
    # $CASE/wt links to it, so the slot-owner claim has its real location.
    mkdir -p "$dir/pool/1"
    git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
      commit --allow-empty -qm pool-fixture
    git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
    ln -s pool/1/project "$dir/wt"
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
      "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  else
    git -C "$dir/project" worktree add -q -b fm/task-x1 "$dir/wt" main
  fi

  printf '%s\n' "$dir"
}

# Add the task's backlog row, start it, and publish its task record.
# Args: <case> <id> <kind> [worktree] [project]
seed_task() {  # <case> <id> <kind> [worktree] [project]
  local dir=$1 id=$2 kind=$3 wt=${4:-$1/wt} project=${5:-$1/project}
  tasks-axi add "$id" "close-return fixture $id" --kind "$kind" \
    --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$dir/home/data/backlog.md" >/dev/null
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$project" \
    "kind=$kind" \
    "mode=local-only" \
    "yolo=off" \
    "spawn_gen=fixture-$id"
  printf 'done: fixture outcome\n' > "$dir/home/state/$id.status"
}

# Commit clean work in the task copy and push its branch to origin, which is
# the ordinary landed proof the teardown reuses.
land_task_branch() {  # <case> <id>
  local dir=$1 id=$2
  git -C "$dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "work for $id"
  git -C "$dir/wt" push -q origin "HEAD:refs/heads/fm/$id"
  git -C "$dir/project" fetch -q origin
}

run_close() {  # <case> <id> [state-dir]
  local dir=$1 id=$2 state=${3:-$1/home/state}
  ( cd "$dir/home" || exit 1
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_FIXTURE_REAPER_LOG="$dir/reaper.log" \
    PATH="$dir/fakebin:$PATH" \
    "$CLOSE" done "$id" )
}

run_close_in_backlog() {  # <case> <id> <other-data-dir>
  local dir=$1 id=$2 data=$3
  ( cd "$dir/home" || exit 1
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_FIXTURE_REAPER_LOG="$dir/reaper.log" \
    PATH="$dir/fakebin:$PATH" \
    "$CLOSE" done "$id" )
}

run_after_close() {  # <case> <id>
  local dir=$1 id=$2
  ( cd "$dir/home" || exit 1
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_RUNTIME_LOG="$dir/runtime.log" \
    FM_FIXTURE_REAPER_LOG="$dir/reaper.log" \
    PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --after-close )
}

row_state() {  # <case> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

return_count() {  # <case>
  grep -c 'treehouse <return>' "$1/runtime.log" 2>/dev/null || true
}

# --- (a) a clean landed owned copy is returned by the close -------------------

test_close_returns_clean_landed_copy() {
  local dir id=task-x1 rc
  dir=$(make_case landed)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"

  run_close "$dir" "$id" > "$dir/close.out" 2> "$dir/close.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "close refused a clean landed task: $(cat "$dir/close.err")"
  [ "$(row_state "$dir" "$id")" = done ] \
    || fail "close did not land the backlog row: $(row_state "$dir" "$id")"
  assert_absent "$dir/home/state/$id.meta" "the close left the task record behind"
  [ "$(return_count "$dir")" -eq 1 ] \
    || fail "the close did not return the owned copy exactly once: $(cat "$dir/runtime.log")"
  grep -F "copy: task $id's guarded cleanup completed" "$dir/close.err" >/dev/null \
    || fail "the close did not report guarded cleanup completion: $(cat "$dir/close.err")"
  assert_present "$dir/reaper.log" "the fixture teardown never reached its stub reaper"
  grep -F "$FIXTURE_ROOT/bin/fm-remote-job-reap-orphans.sh" "$dir/reaper.log" >/dev/null \
    || fail "teardown ran a reaper outside the disposable fixture: $(cat "$dir/reaper.log")"
  pass "fm-tasks-axi: a close returns its clean landed owned copy exactly once"
  pass "fm-tasks-axi: synthetic teardown calls only the fixture reaper stub, never the host sweep"
}

# --- (b) a dirty copy is preserved ------------------------------------------

test_dirty_copy_is_preserved() {
  local dir id=task-x1 rc
  dir=$(make_case dirty)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"
  printf 'uncommitted\n' > "$dir/wt/untracked.txt"

  run_close "$dir" "$id" > "$dir/close.out" 2> "$dir/close.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "a refused copy return failed the close itself: $(cat "$dir/close.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "the dirty-copy close did not land the row"
  assert_present "$dir/home/state/$id.meta" "the dirty copy's task record was removed"
  assert_present "$dir/wt/untracked.txt" "the dirty copy was modified"
  [ "$(return_count "$dir")" -eq 0 ] \
    || fail "a dirty copy was returned: $(cat "$dir/runtime.log")"
  grep -F 'copy was preserved' "$dir/close.err" >/dev/null \
    || fail "the close did not report the preserved dirty copy: $(cat "$dir/close.err")"
  pass "fm-tasks-axi: a close preserves a dirty copy and still lands the close"
}

# --- (c) unlanded committed work is preserved --------------------------------

test_unlanded_copy_is_preserved() {
  local dir id=task-x1 rc
  dir=$(make_case unlanded)
  seed_task "$dir" "$id" ship
  git -C "$dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m 'unpushed work'

  run_close "$dir" "$id" > "$dir/close.out" 2> "$dir/close.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "an unlanded refusal failed the close itself: $(cat "$dir/close.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "the unlanded close did not land the row"
  assert_present "$dir/home/state/$id.meta" "the unlanded copy's task record was removed"
  [ "$(return_count "$dir")" -eq 0 ] \
    || fail "unlanded work was returned: $(cat "$dir/runtime.log")"
  grep -F 'copy was preserved' "$dir/close.err" >/dev/null \
    || fail "the close did not report the preserved unlanded copy: $(cat "$dir/close.err")"
  pass "fm-tasks-axi: a close preserves unlanded committed work and still lands the close"
}

# --- (d) a slot reassigned to another task is never touched ------------------

test_reassigned_slot_is_preserved() {
  local dir id=task-x1 rc
  dir=$(make_case reassigned pool)
  seed_task "$dir" "$id" ship "$dir/wt" "$dir/project"
  land_task_branch "$dir" "$id"
  printf 'task=other-live\nhome=%s\n' "$dir/home" > "$dir/pool/1/.fm-slot-owner"

  run_close "$dir" "$id" > "$dir/close.out" 2> "$dir/close.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "a reassigned-slot close was not a clean close: $(cat "$dir/close.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "the reassigned-slot close did not land the row"
  [ "$(return_count "$dir")" -eq 0 ] \
    || fail "another task's reassigned copy was returned: $(cat "$dir/runtime.log")"
  assert_present "$dir/pool/1/.fm-slot-owner" "the other task's slot claim was removed"
  assert_present "$dir/pool/1/project" "the other task's copy was removed"
  grep -F 'reassigned to task other-live' "$dir/close.err" >/dev/null \
    || fail "the close did not name the reassignment: $(cat "$dir/close.err")"
  grep -F 'guarded cleanup completed' "$dir/close.err" >/dev/null \
    || fail "the reassigned-slot close did not report cleanup completion"
  if grep -F 'available again' "$dir/close.err" >/dev/null; then
    fail "the reassigned-slot close claimed pool availability"
  fi
  pass "fm-tasks-axi: a close never returns or mutates a slot reassigned to another task"
}

# --- (e) a failed return preserves the copy and a retry converges ------------

test_failed_return_is_preserved_and_retried() {
  local dir id=task-x1 rc
  dir=$(make_case retry)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"

  FM_TREEHOUSE_FAIL_RETURN=1 run_close "$dir" "$id" > "$dir/first.out" 2> "$dir/first.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "the failed-return close itself failed: $(cat "$dir/first.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "the failed-return close did not land the row"
  assert_present "$dir/home/state/$id.meta" "the failed return removed the task record"
  assert_present "$dir/wt" "the failed return removed the copy"
  grep -F 'copy was preserved' "$dir/first.err" >/dev/null \
    || fail "the failed return was not reported as preserved: $(cat "$dir/first.err")"

  run_close "$dir" "$id" > "$dir/second.out" 2> "$dir/second.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "the retry close failed: $(cat "$dir/second.err")"
  assert_absent "$dir/home/state/$id.meta" "the retry did not remove the task record"
  [ "$(return_count "$dir")" -eq 1 ] \
    || fail "the retry did not return the copy exactly once: $(cat "$dir/runtime.log")"
  pass "fm-tasks-axi: a failed copy return preserves the copy and a repeated close retries it once"
}

# --- (f) a repeated close converges without a second return ------------------

test_repeated_close_converges() {
  local dir id=task-x1 rc
  dir=$(make_case repeat)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"

  run_close "$dir" "$id" > "$dir/first.out" 2> "$dir/first.err"; rc=$?
  [ "$rc" -eq 0 ] || fail "the first close failed: $(cat "$dir/first.err")"
  run_close "$dir" "$id" > "$dir/second.out" 2> "$dir/second.err"; rc=$?

  [ "$rc" -eq 0 ] || fail "the repeated close failed: $(cat "$dir/second.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "the repeated close reopened the row"
  [ "$(return_count "$dir")" -eq 1 ] \
    || fail "the repeated close returned the copy twice: $(cat "$dir/runtime.log")"
  pass "fm-tasks-axi: a repeated close converges without a second copy return"
}

# --- (g) --after-close alone cannot skip an open close -----------------------

test_after_close_refuses_an_open_row() {
  local dir id=task-x1 rc
  dir=$(make_case open)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"

  run_after_close "$dir" "$id" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -ne 0 ] || fail "--after-close accepted a backlog item that is still In flight"
  [ "$(row_state "$dir" "$id")" = "in_flight" ] \
    || fail "the refused --after-close moved the open row: $(row_state "$dir" "$id")"
  assert_present "$dir/home/state/$id.meta" "the refused --after-close removed the task record"
  [ "$(return_count "$dir")" -eq 0 ] \
    || fail "the refused --after-close returned the copy: $(cat "$dir/runtime.log")"
  grep -F 'requires task' "$dir/err" >/dev/null \
    || fail "the refusal did not name the open-row requirement: $(cat "$dir/err")"
  pass "fm-teardown: --after-close refuses an open row and changes nothing"
}

# --- (h) a secondmate record is never torn down by a close -------------------

test_secondmate_record_is_never_torn_down() {
  local dir id=mate-x1 rc
  dir=$(make_case secondmate)
  tasks-axi add "$id" "fixture secondmate" --kind secondmate \
    --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$dir/home/data/backlog.md" >/dev/null
  mkdir -p "$dir/childhome"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/childhome" \
    "project=$dir/childhome" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$dir/childhome" \
    "spawn_gen=fixture-$id"

  run_close "$dir" "$id" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "the secondmate row close failed: $(cat "$dir/err")"
  assert_present "$dir/home/state/$id.meta" "a close tore down a secondmate record"
  assert_present "$dir/childhome" "a close removed a secondmate home"
  [ "$(return_count "$dir")" -eq 0 ] \
    || fail "a close touched a secondmate's copy: $(cat "$dir/runtime.log")"
  pass "fm-tasks-axi: a close never tears down a persistent secondmate record or home"
}

# --- (i) a close in another home's backlog never touches this home's copy ----

test_foreign_backlog_close_preserves_copy() {
  local dir id=task-x1 other rc
  dir=$(make_case foreign)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"
  other="$dir/other"
  mkdir -p "$other/data"
  cp "$ROOT/.tasks.toml" "$other/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$other/data/backlog.md"
  tasks-axi add "$id" "foreign backlog task" --kind ship \
    --file "$other/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$other/data/backlog.md" >/dev/null

  run_close_in_backlog "$dir" "$id" "$other/data" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "the foreign-backlog close failed: $(cat "$dir/err")"
  assert_present "$dir/home/state/$id.meta" "a foreign-backlog close tore down this home's task"
  assert_present "$dir/wt" "a foreign-backlog close removed this home's copy"
  [ "$(return_count "$dir")" -eq 0 ] \
    || fail "a foreign-backlog close returned this home's copy: $(cat "$dir/runtime.log")"
  grep -F 'not this home' "$dir/err" >/dev/null \
    || fail "the close did not name the foreign backlog: $(cat "$dir/err")"
  pass "fm-tasks-axi: a close in another home's backlog preserves this home's copy"
}

# --- (j) concurrent closes converge on one return ---------------------------

test_concurrent_close_converges() {
  local dir id=task-x1 p1 p2 r1 r2
  dir=$(make_case concurrent)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"

  ( run_close "$dir" "$id" > "$dir/first.out" 2> "$dir/first.err" ) &
  p1=$!
  ( run_close "$dir" "$id" > "$dir/second.out" 2> "$dir/second.err" ) &
  p2=$!
  wait "$p1"; r1=$?
  wait "$p2"; r2=$?

  [ "$r1" -eq 0 ] || [ "$r2" -eq 0 ] \
    || fail "neither concurrent close landed the row: $(cat "$dir/first.err" "$dir/second.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "the concurrent close left the row open"
  assert_absent "$dir/home/state/$id.meta" "the concurrent close left the task record behind"
  [ "$(return_count "$dir")" -eq 1 ] \
    || fail "concurrent closes returned the copy more than once: $(cat "$dir/runtime.log")"
  pass "fm-tasks-axi: concurrent closes converge on one copy return"
}

# --- (k) an interrupted close's recovery marker is preserved ----------------

test_recovery_marker_is_preserved() {
  local dir id=task-x1 rc
  dir=$(make_case recovery-marker)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"
  # The durable record an interrupted ordinary close leaves behind. The close
  # hook must not consume or rewrite it; the next session start replays it.
  cat > "$dir/home/state/$id.backlog-close" <<EOF
id=$id
data=$dir/home/data
spawn_gen=fixture-$id
cleanup_incomplete=0
EOF

  run_close "$dir" "$id" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "the close with a pending-close record failed: $(cat "$dir/err")"
  assert_present "$dir/home/state/$id.backlog-close" "the close consumed an interruption's recovery marker"
  assert_absent "$dir/home/state/$id.meta" "the close left the task record behind"
  [ "$(return_count "$dir")" -eq 1 ] \
    || fail "the close did not return the copy once: $(cat "$dir/runtime.log")"
  pass "fm-tasks-axi: a close preserves an existing interruption recovery marker"
}

test_completed_scout_copy_safety() {
  local state=$1 dir id=scout-x1 rc before_head before_status
  dir=$(make_case "scout-$state")
  seed_task "$dir" "$id" scout
  mkdir -p "$dir/home/data/$id"
  printf 'Completed scout report\n' > "$dir/home/data/$id/report.md"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$FIXTURE_ROOT/bin/fm-captain-hold.sh" complete "$id" --none \
    > "$dir/complete.out" 2> "$dir/complete.err" \
    || fail "scout completion inventory failed: $(cat "$dir/complete.err")"

  case "$state" in
    dirty)
      land_task_branch "$dir" "$id"
      printf 'scout scratch work\n' > "$dir/wt/scratch.txt"
      ;;
    unlanded)
      printf 'scout scratch work\n' > "$dir/wt/scratch.txt"
      git -C "$dir/wt" add scratch.txt
      git -C "$dir/wt" -c user.email=t@t -c user.name=t \
        commit -q -m 'unlanded scout work'
      ;;
    landed) land_task_branch "$dir" "$id" ;;
  esac
  before_head=$(git -C "$dir/wt" rev-parse HEAD)
  before_status=$(git -C "$dir/wt" status --porcelain)

  run_close "$dir" "$id" > "$dir/close.out" 2> "$dir/close.err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "scout $state close failed: $(cat "$dir/close.err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "scout $state close left its row open"
  assert_present "$dir/home/data/$id/report.md" "scout $state report was removed"
  if [ "$state" = landed ]; then
    assert_absent "$dir/home/state/$id.meta" "landed scout record was not removed"
    [ "$(return_count "$dir")" -eq 1 ] || fail "landed scout copy was not returned once"
  else
    assert_present "$dir/home/state/$id.meta" "scout $state record was removed"
    [ "$(return_count "$dir")" -eq 0 ] || fail "scout $state copy was returned"
    [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$before_head" ] \
      || fail "scout $state HEAD changed"
    [ "$(git -C "$dir/wt" status --porcelain)" = "$before_status" ] \
      || fail "scout $state working files changed"
    [ "$(git -C "$dir/wt" branch --show-current)" = fm/task-x1 ] \
      || fail "scout $state branch was detached or deleted"
    grep -Fx 'scout scratch work' "$dir/wt/scratch.txt" >/dev/null \
      || fail "scout $state work was lost"
    grep -F 'copy was preserved' "$dir/close.err" >/dev/null \
      || fail "scout $state preservation was not reported"
  fi
  pass "fm-tasks-axi: completed-report scout $state copy obeys automatic return safety"
}

test_equivalent_backlog_path_returns_copy() {
  local spelling=$1 dir id=task-x1 data rc
  dir=$(make_case "backlog-$spelling")
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"
  case "$spelling" in
    trailing-slash) data="$dir/home/data/" ;;
    symlink)
      ln -s home/data "$dir/data-alias"
      data="$dir/data-alias"
      ;;
    dot-segments) data="$dir/home/data/../data/." ;;
  esac

  run_close_in_backlog "$dir" "$id" "$data" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "$spelling close failed: $(cat "$dir/err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "$spelling close left the row open"
  assert_absent "$dir/home/state/$id.meta" "$spelling close left the task record"
  [ "$(return_count "$dir")" -eq 1 ] || fail "$spelling close did not return the copy once"
  pass "fm-tasks-axi: $spelling spelling of this home's backlog returns its copy"
}

test_state_override_returns_copy() {
  local dir id=task-x1 rc state
  dir=$(make_case state-override)
  seed_task "$dir" "$id" ship
  land_task_branch "$dir" "$id"
  state="$dir/home/relocated-state"
  mv "$dir/home/state" "$state"

  run_close "$dir" "$id" "$state" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "state-override close failed: $(cat "$dir/err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "state-override close left row open"
  assert_absent "$state/$id.meta" "state-override close left the task record"
  [ "$(return_count "$dir")" -eq 1 ] || fail "state-override close did not return the copy once"
  pass "fm-tasks-axi: close returns a copy from the configured state directory"
}

test_after_close_preserves_completion() {
  local artifact=$1 dir id=task-x1 rc expected
  dir=$(make_case "completion-$artifact")
  if [ "$artifact" = report ]; then
    seed_task "$dir" "$id" scout
    mkdir -p "$dir/home/data/$id"
    printf 'Completed scout report\n' > "$dir/home/data/$id/report.md"
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
      FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
      "$FIXTURE_ROOT/bin/fm-captain-hold.sh" complete "$id" --none \
      > "$dir/complete.out" 2> "$dir/complete.err" \
      || fail "completion inventory failed: $(cat "$dir/complete.err")"
    expected="data/$id/report.md"
  else
    seed_task "$dir" "$id" ship
    expected='local main'
    if [ "$artifact" = pr ]; then
      perl -pi -e 's/^mode=local-only$/mode=no-mistakes/' "$dir/home/state/$id.meta"
      expected='https://github.com/example/repo/pull/42'
      printf 'pr=%s\n' "$expected" >> "$dir/home/state/$id.meta"
    fi
  fi
  land_task_branch "$dir" "$id"
  tasks-axi done "$id" --file "$dir/home/data/backlog.md" >/dev/null
  perl -pi -e 's/\(done \d{4}-\d{2}-\d{2}\)/(done 2020-01-02)/g' "$dir/home/data/backlog.md"
  tasks-axi show "$id" --file "$dir/home/data/backlog.md" | \
    grep -Fx '  closed: 2020-01-02' >/dev/null \
    || fail "fixture did not establish an earlier close date"

  run_after_close "$dir" "$id" > "$dir/out" 2> "$dir/err"
  rc=$?

  [ "$rc" -eq 0 ] || fail "$artifact backfill failed: $(cat "$dir/err")"
  [ "$(row_state "$dir" "$id")" = done ] || fail "$artifact backfill reopened row"
  grep -F "$expected" "$dir/home/data/backlog.md" >/dev/null \
    || fail "$artifact completion data was lost"
  tasks-axi show "$id" --file "$dir/home/data/backlog.md" | \
    grep -Fx '  closed: 2020-01-02' >/dev/null \
    || fail "$artifact backfill moved the close date"
  assert_absent "$dir/home/state/$id.meta" "$artifact backfill left task record"
  [ "$(return_count "$dir")" -eq 1 ] || fail "$artifact backfill did not return copy once"
  pass "fm-teardown: after-close preserves $artifact completion and the original close date"
}

test_close_returns_clean_landed_copy
test_state_override_returns_copy
test_equivalent_backlog_path_returns_copy trailing-slash
test_equivalent_backlog_path_returns_copy symlink
test_equivalent_backlog_path_returns_copy dot-segments
test_after_close_preserves_completion pr
test_after_close_preserves_completion report
test_after_close_preserves_completion note
test_completed_scout_copy_safety dirty
test_completed_scout_copy_safety unlanded
test_completed_scout_copy_safety landed
test_dirty_copy_is_preserved
test_unlanded_copy_is_preserved
test_reassigned_slot_is_preserved
test_failed_return_is_preserved_and_retried
test_repeated_close_converges
test_after_close_refuses_an_open_row
test_secondmate_record_is_never_torn_down
test_foreign_backlog_close_preserves_copy
test_concurrent_close_converges
test_recovery_marker_is_preserved
