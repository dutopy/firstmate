#!/usr/bin/env bash
# Tests for the shared-slot reconciliation in bin/fm-teardown.sh.
#
# A Treehouse pool slot is reused across tasks, and two FINISHED task records can
# end up naming one slot (a stale duplicate record, a scout that ran in a ship's
# slot, and so on). Before this change the exclusivity refusal was a deadlock:
# each record named the other as its blocker and neither task could be cleaned
# up, so the finished tasks kept their records, their panes lingered, and the
# watcher kept reporting them stale.
#
# The reconciliation that breaks it must never become a way to reset preserved
# unlanded work, so the matrix below pins BOTH directions:
#   (a) settled shared slot (both finished, other endpoint gone, deliverables
#       outside, copy landed)              -> ALLOW, slot returned once, receipt
#   (b) co-owner holds uncommitted work    -> REFUSE, even under --force
#   (c) co-owner holds unmerged commits    -> REFUSE, even under --force
#   (d) co-owner endpoint still live       -> REFUSE
#   (e) co-owner deliverable only inside   -> REFUSE, even under --force
#   (f) co-owner status not finished       -> REFUSE
#   (g) a co-owner's later teardown skips the already-returned slot (no second
#       return, no reset) and still cleans up its own record
#   (h) a new claim on the slot supersedes an old receipt
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-shared-slot)

# Build a sandbox: $CASE/home with state/data/config, $CASE/project, and a
# tmux mock that logs every call to $CASE/runtime.log. The mock reports the pool
# slot's neighbour windows as ABSENT by default (no output from list-windows),
# which is the common "endpoint is gone" state; a test that needs a live
# endpoint sets FM_FAKE_TMUX_WINDOW and FM_FAKE_TMUX_CURRENT_COMMAND.
make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/project" "$TMP_ROOT/$dir/wt"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
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
# kill-window and every other call succeed silently.
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

# Turn $CASE/wt into a real Treehouse pool slot checkout at $CASE/pool/1/project,
# leaving a clean landed copy with a `main` default branch so the slot's
# landed-work proof is satisfiable when a test wants it.
mark_case_as_treehouse_pool() {  # <case>
  local dir=$1
  rm -rf "$dir/wt"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" branch -f main HEAD
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s pool/1/project "$dir/wt"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
}

write_data_report() {  # <case> <id>
  mkdir -p "$1/home/data/$2"
  printf 'deliverable for %s\n' "$2" > "$1/home/data/$2/report.md"
}

run_teardown() {  # <case> <id> [--force]
  local dir=$1 id=$2; shift 2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

# --- (a) the settled shared slot is released once -----------------------------

test_settled_shared_slot_releases_and_records() {
  local dir a=shared-a b=shared-b rc
  dir=$(make_case settled)
  mark_case_as_treehouse_pool "$dir"
  # A ship pair, so the current task's own teardown needs no scout report gate.
  fm_write_meta "$dir/home/state/$a.meta" \
    "window=firstmate:fm-$a" "endpoint_task_id=$a" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  fm_write_meta "$dir/home/state/$b.meta" \
    "window=firstmate:fm-$b" "endpoint_task_id=$b" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready on local main\n' > "$dir/home/state/$a.status"
  printf 'done: ready on local main\n' > "$dir/home/state/$b.status"

  set +e
  run_teardown "$dir" "$a" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the settled shared slot was not released: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$a.meta" "settled release left its own record"
  assert_present "$dir/home/state/$b.meta" "settled release removed the co-owner's record"
  [ "$(grep -c 'treehouse <return>' "$dir/runtime.log" || true)" = 1 ] \
    || fail "the settled slot was not returned exactly once: $(cat "$dir/runtime.log")"
  [ -f "$dir/pool/1/.fm-slot-reconciled" ] \
    || fail "the release recorded no durable reconciliation receipt"
  grep -F "released_by=$a" "$dir/pool/1/.fm-slot-reconciled" >/dev/null \
    || fail "the receipt does not name the releasing task: $(cat "$dir/pool/1/.fm-slot-reconciled")"
  grep -F "owner=$a" "$dir/pool/1/.fm-slot-reconciled" >/dev/null \
    || fail "the receipt does not name the current owner: $(cat "$dir/pool/1/.fm-slot-reconciled")"
  grep -F "owner=$b" "$dir/pool/1/.fm-slot-reconciled" >/dev/null \
    || fail "the receipt does not name the co-owner: $(cat "$dir/pool/1/.fm-slot-reconciled")"
  pass "fm-teardown: a settled shared slot is returned once and recorded durably"
}

# --- (g) a co-owner's later teardown never re-touches the released slot -------

test_coowner_teardown_skips_an_already_returned_slot() {
  local dir a=shared-a b=shared-b rc returns
  dir=$(make_case coowner)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$a.meta" \
    "window=firstmate:fm-$a" "endpoint_task_id=$a" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  fm_write_meta "$dir/home/state/$b.meta" \
    "window=firstmate:fm-$b" "endpoint_task_id=$b" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready on local main\n' > "$dir/home/state/$a.status"
  printf 'done: ready on local main\n' > "$dir/home/state/$b.status"
  run_teardown "$dir" "$a" >/dev/null 2>&1 || fail "the first settled release failed"
  returns=$(grep -c 'treehouse <return>' "$dir/runtime.log" || true)

  set +e
  run_teardown "$dir" "$b" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the co-owner's own cleanup was not completed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$b.meta" "the co-owner's own record was not cleaned up"
  [ "$(grep -c 'treehouse <return>' "$dir/runtime.log" || true)" = "$returns" ] \
    || fail "the co-owner's teardown returned the already-released slot again"
  grep -F "already returned to its pool" "$dir/stderr" >/dev/null \
    || fail "the co-owner's teardown did not report why it skipped the slot: $(cat "$dir/stderr")"
  pass "fm-teardown: a co-owner's later teardown skips an already-returned slot"
}

# --- (h) a new claim supersedes an old receipt --------------------------------

test_new_claim_supersedes_the_reconciliation_receipt() {
  local dir a=shared-a
  dir=$(make_case reclaim)
  mark_case_as_treehouse_pool "$dir"
  printf 'slot=%s\nreleased=1\nreleased_by=%s\nowner=%s\n' \
    "$dir/wt" "$a" "$a" > "$dir/pool/1/.fm-slot-reconciled"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_treehouse_slot_owner_claim "$dir/wt" "new-holder" "$dir/home"
  )
  [ ! -e "$dir/pool/1/.fm-slot-reconciled" ] \
    || fail "a new claim left a previous generation's reconciliation receipt in place"
  pass "fm-wake-lib: a new slot claim drops an old reconciliation receipt"
}

# --- (d) the receipt is never a bypass for an unreadable one -----------------

test_unreadable_receipt_refuses_before_touching_the_slot() {
  local dir id=claim-a rc
  dir=$(make_case unreadable-receipt)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready on local main\n' > "$dir/home/state/$id.status"
  # A directory where the receipt file belongs is unreadable as a receipt.
  mkdir -p "$dir/pool/1/.fm-slot-reconciled"
  set +e
  run_teardown "$dir" "$id" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unreadable reconciliation receipt did not refuse"
  assert_present "$dir/home/state/$id.meta" "an unreadable receipt removed the record"
  pass "fm-teardown: an unreadable reconciliation receipt refuses without touching the slot"
}

# --- unsafe cases -------------------------------------------------------------

# The shared-slot helpers every unsafe case starts from: two finished ship
# records on one pool slot with a gone co-owner endpoint.
stage_settled_pair() {  # <case> <a> <b>
  local dir=$1 a=$2 b=$3
  fm_write_meta "$dir/home/state/$a.meta" \
    "window=firstmate:fm-$a" "endpoint_task_id=$a" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  fm_write_meta "$dir/home/state/$b.meta" \
    "window=firstmate:fm-$b" "endpoint_task_id=$b" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  printf 'done: ready on local main\n' > "$dir/home/state/$a.status"
  printf 'done: ready on local main\n' > "$dir/home/state/$b.status"
}

assert_refused_and_intact() {  # <case> <a> <b> <description>
  local dir=$1 a=$2 b=$3 description=$4 rc
  set +e
  run_teardown "$dir" "$a" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$a.meta" "$description: the current record was removed"
  assert_present "$dir/home/state/$b.meta" "$description: the co-owner record was removed"
  [ -d "$dir/pool/1/project" ] || fail "$description: the shared pool checkout was removed"
  ! grep -Fq 'treehouse' "$dir/runtime.log" || fail "$description: the shared slot was returned"
}

test_uncommitted_work_refuses_under_force() {
  local dir a=stale-a b=parked-b
  dir=$(make_case uncommitted)
  mark_case_as_treehouse_pool "$dir"
  : > "$dir/wt/sentinel"
  stage_settled_pair "$dir" "$a" "$b"
  assert_refused_and_intact "$dir" "$a" "$b" "uncommitted co-owner work"
  grep -F "has not landed" "$dir/stderr" >/dev/null \
    || fail "the uncommitted refusal did not name the unlanded copy: $(cat "$dir/stderr")"
  pass "fm-teardown: uncommitted work in a shared slot refuses even under --force"
}

test_unmerged_commits_refuse_under_force() {
  local dir a=stale-a b=parked-b
  dir=$(make_case unmerged)
  mark_case_as_treehouse_pool "$dir"
  git -C "$dir/wt" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm 'parked unlanded work'
  stage_settled_pair "$dir" "$a" "$b"
  assert_refused_and_intact "$dir" "$a" "$b" "unmerged co-owner commits"
  pass "fm-teardown: unmerged commits in a shared slot refuse even under --force"
}

test_live_coowner_endpoint_refuses() {
  local dir a=stale-a b=live-b
  dir=$(make_case live-endpoint)
  mark_case_as_treehouse_pool "$dir"
  stage_settled_pair "$dir" "$a" "$b"
  # The co-owner's window is present and its foreground command is a live agent.
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
case "\${1:-}" in
  list-windows) printf '%s\n' "fm-$b"; exit 0 ;;
  display-message) case "\$*" in *pane_current_command*) printf '%s\n' pi ;; esac; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  set +e
  run_teardown "$dir" "$a" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a shared slot with a live co-owner endpoint did not refuse"
  assert_present "$dir/home/state/$b.meta" "the live co-owner record was removed"
  [ -d "$dir/pool/1/project" ] || fail "the shared pool checkout was removed under a live co-owner"
  ! grep -Fq 'treehouse' "$dir/runtime.log" || fail "the shared slot was returned under a live co-owner"
  grep -F "still has a live or unproven endpoint" "$dir/stderr" >/dev/null \
    || fail "the live-endpoint refusal did not say so: $(cat "$dir/stderr")"
  pass "fm-teardown: a shared slot with a live co-owner endpoint refuses"
}

test_coowner_deliverable_inside_only_refuses_under_force() {
  local dir a=ship-a b=scout-b
  dir=$(make_case deliverable-inside)
  mark_case_as_treehouse_pool "$dir"
  : > "$dir/wt/sentinel"   # the scout's only finding is still inside the copy
  fm_write_meta "$dir/home/state/$a.meta" \
    "window=firstmate:fm-$a" "endpoint_task_id=$a" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  fm_write_meta "$dir/home/state/$b.meta" \
    "window=firstmate:fm-$b" "endpoint_task_id=$b" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=scout" "yolo=off"
  printf 'done: ready on local main\n' > "$dir/home/state/$a.status"
  printf 'done: report written\n' > "$dir/home/state/$b.status"
  set +e
  run_teardown "$dir" "$a" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a co-owner whose deliverable exists only inside the copy did not refuse"
  assert_present "$dir/home/state/$b.meta" "the scout record was removed without its report"
  [ -e "$dir/wt/sentinel" ] \
    || fail "the shared copy was reset with the scout's only deliverable inside"
  grep -F "deliverable is not recorded outside" "$dir/stderr" >/dev/null \
    || fail "the refusal did not name the missing outside deliverable: $(cat "$dir/stderr")"
  pass "fm-teardown: a co-owner deliverable that exists only inside the copy refuses even under --force"
}

test_unfinished_coowner_refuses() {
  local dir a=done-a b=working-b
  dir=$(make_case unfinished)
  mark_case_as_treehouse_pool "$dir"
  stage_settled_pair "$dir" "$a" "$b"
  printf 'working: still writing the report\n' > "$dir/home/state/$b.status"
  assert_refused_and_intact "$dir" "$a" "$b" "unfinished co-owner"
  grep -F "not a finished task" "$dir/stderr" >/dev/null \
    || fail "the unfinished refusal did not say so: $(cat "$dir/stderr")"
  pass "fm-teardown: an unfinished co-owner record refuses the shared-slot release"
}

test_scout_deliverable_outside_still_settles() {
  local dir a=ship-a b=scout-b rc
  dir=$(make_case scout-report)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$a.meta" \
    "window=firstmate:fm-$a" "endpoint_task_id=$a" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=ship" "mode=local-only" "yolo=off"
  fm_write_meta "$dir/home/state/$b.meta" \
    "window=firstmate:fm-$b" "endpoint_task_id=$b" \
    "worktree=$dir/wt" "project=$dir/project" "harness=pi" \
    "kind=scout" "yolo=off"
  printf 'done: ready on local main\n' > "$dir/home/state/$a.status"
  printf 'done: report written\n' > "$dir/home/state/$b.status"
  write_data_report "$dir" "$b"
  set +e
  run_teardown "$dir" "$a" --force > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a scout whose report is recorded outside the copy still refused: $(cat "$dir/stderr")"
  [ "$(grep -c 'treehouse <return>' "$dir/runtime.log" || true)" = 1 ] \
    || fail "the settled slot was not returned exactly once: $(cat "$dir/runtime.log")"
  assert_present "$dir/home/data/$b/report.md" "the settlement removed the scout's outside report"
  pass "fm-teardown: a co-owner deliverable recorded outside the copy still settles"
}

test_settled_shared_slot_releases_and_records
test_coowner_teardown_skips_an_already_returned_slot
test_new_claim_supersedes_the_reconciliation_receipt
test_unreadable_receipt_refuses_before_touching_the_slot
test_uncommitted_work_refuses_under_force
test_unmerged_commits_refuse_under_force
test_live_coowner_endpoint_refuses
test_coowner_deliverable_inside_only_refuses_under_force
test_unfinished_coowner_refuses
test_scout_deliverable_outside_still_settles
