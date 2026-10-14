#!/usr/bin/env bash
# Behavior tests for bin/fm-antidrift-check.sh and the cached heartbeat reader.
#
# Every case drives the real `refresh` producer against throwaway homes whose
# repositories, task metadata, pool-slot claims, fake no-mistakes and fake
# gh-axi decide the outcome, with a pinned clock (FM_WIP_NOW). The producer, the
# WIP checkpoint script and the cache readers run unmodified. No case reaches a
# real forge, and every case that reads a source repository also proves the
# source index, refs, objects and HEAD are byte-identical afterwards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AD="$ROOT/bin/fm-antidrift-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-antidrift-check)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
GIT_GLOBAL="$TMP_ROOT/gitconfig"
: > "$GIT_GLOBAL"
export GIT_CONFIG_GLOBAL="$GIT_GLOBAL" GIT_CONFIG_NOSYSTEM=1
fm_git_identity
T0=1800000000

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
case "$1 $2" in
  "repo view") printf 'repo:\n  visibility: %s\n' "${FAKE_VIS:-private}" ;;
  "pr list")
    [ "${FAKE_PR_FAIL:-0}" != 1 ] || exit 1
    if [ "${FAKE_PR_NOURL:-0}" = 1 ]; then
      printf 'count: 1\npull_requests[1]{number,title,state,author,draft,review}:\n'
    else
      case "$*" in *"--fields url,createdAt"*) ;; *) exit 1 ;; esac
      printf 'count: 1\npull_requests[1]{number,title,state,author,draft,review,url,createdAt}:\n'
    fi
    cat "${FAKE_PR_OUT:-/dev/null}" ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_NM_PUSHED_AT:-}" ] || exit 1
printf 'branch_sync:\n  state: pipeline_owned\n  pipeline:\n    run: "r1"\n    pushed_at: %s\n    pushed_head: %s\n  remote:\n    freshness: pipeline_push\n' "$FAKE_NM_PUSHED_AT" "${FAKE_NM_PUSHED_HEAD:-0000000}"
SH
chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/no-mistakes"

mk_home() {  # <name>
  local h="$TMP_ROOT/$1/home"
  mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"
  printf '%s\n' "$h"
}

# mk_repo <dir> [github]: a repo with one commit; with "github" it tracks a
# github.com URL that git itself rewrites to a local bare repo.
mk_repo() {
  local dir=$1 bare uid
  uid=$(printf '%s' "$dir" | cksum | cut -d' ' -f1)
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  printf 'a\n' > "$dir/a.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm base
  if [ "${2:-}" = github ]; then
    bare="$dir.bare.git"
    git init -q --bare "$bare"
    git config --file "$GIT_GLOBAL" "url.$bare.insteadOf" "https://github.com/acme/r$uid.git"
    git -C "$dir" remote add origin "https://github.com/acme/r$uid.git"
    git -C "$dir" push -q -u origin main
  fi
}

register_project() {  # <home> <name> [mode]
  printf -- '- %s%s - test project (added 2026-01-01)\n' "$2" "${3:+ [$3]}" >> "$1/data/projects.md"
}

# mk_task <home> <id> <kind> [claim-task]: a pool slot repo owned by the task.
mk_task() {
  local home=$1 id=$2 kind=$3 claim=${4:-$2} slot
  slot="$home/../pool/$id"
  mkdir -p "$slot"
  : > "$home/../pool/treehouse-state.json"
  mk_repo "$slot/repo" github
  git -C "$slot/repo" checkout -q -b "fm/$id"
  printf 'worktree=%s\nkind=%s\nproject=%s\n' "$(cd "$slot/repo" && pwd -P)" "$kind" "$home/projects/none" > "$home/state/$id.meta"
  : > "$home/state/$id.status"
  [ -z "$claim" ] || printf 'task=%s\nhome=%s\n' "$claim" "$home" > "$slot/.fm-slot-owner"
  printf '%s\n' "$slot/repo"
}

refresh() {  # <home> <epoch> [env...]
  local home=$1 now=$2
  shift 2
  env "$@" FM_HOME="$home" FM_WIP_NOW="$now" FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=30 \
    FAKE_CALLS="$TMP_ROOT/calls" PATH="$FAKEBIN:$PATH" "$AD" refresh
}

line_of() { sed -n 's/^line=//p' "$1/state/.antidrift"; }

fingerprint() {
  printf '%s %s %s %s\n' "$(shasum "$1/.git/index" | awk '{print $1}')" \
    "$(git -C "$1" for-each-ref | shasum | awk '{print $1}')" \
    "$(find "$1/.git/objects" -type f | wc -l | tr -d ' ')" "$(git -C "$1" rev-parse HEAD)"
}

test_empty_inventory_is_quiet_and_schedules_the_next_run() {
  local home
  home=$(mk_home empty)
  refresh "$home" $T0 || fail "refresh on an empty home must succeed"
  assert_equals "" "$(line_of "$home")" "nothing to report on an empty inventory"
  assert_equals $((T0 + 300)) "$(cat "$home/state/.antidrift-next")" "next run is one tick away"
  pass "fm-antidrift-check: an empty inventory publishes an empty line"
}

test_no_upstream_alarm_and_scout_exclusion() {
  local home line
  home=$(mk_home noup)
  mk_repo "$home/projects/lonely"; register_project "$home" lonely local-only
  mk_repo "$home/projects/tracked" github; register_project "$home" tracked
  mk_task "$home" scout1 scout >/dev/null
  refresh "$home" $T0
  line=$(line_of "$home")
  assert_contains "$line" "no-upstream 1 (lonely[local-only])" "a local-only project is alarmed and annotated"
  assert_not_contains "$line" "no-upstream 2" "a project with a GitHub upstream is not alarmed for upstream"
  assert_not_contains "$line" "tracked[" "a project with a GitHub upstream is not annotated"
  assert_not_contains "$line" "no-upstream 2" "a scout worktree is never alarmed for upstream"
  assert_not_contains "$line" "scout1)" "a scout worktree is not named in the no-upstream list"
  pass "fm-antidrift-check: no-upstream alarm is immediate, annotated for local-only, scouts excluded"
}

test_unpushed_threshold_is_literal() {
  local home p i
  home=$(mk_home many)
  mk_repo "$home/projects/busy" github; register_project "$home" busy
  p="$home/projects/busy"
  for i in 1 2 3 4 5 6 7 8 9 10; do git -C "$p" commit -q --allow-empty -m "c$i"; done
  refresh "$home" $T0
  assert_not_contains "$(line_of "$home")" "unpushed>10" "exactly 10 unpushed is not over the cap"
  git -C "$p" commit -q --allow-empty -m c11
  refresh "$home" $((T0 + 1))
  assert_contains "$(line_of "$home")" "unpushed>10 1 (busy:11)" "11 unpushed commits alarm"
  pass "fm-antidrift-check: more than 10 unpushed commits alarms, exactly 10 does not"
}

test_push_age_applies_to_registry_clones_and_the_home_root_as_unknown() {
  local home
  home=$(mk_home pushscope)
  mk_repo "$home/projects/tracked" github; register_project "$home" tracked
  refresh "$home" $T0
  assert_contains "$(line_of "$home")" "push-age-unknown 1 (tracked)" "a registered clone without a native receipt is reported unknown, not dropped"
  pass "fm-antidrift-check: push-age alarms cover registry clones and the home root as unknown, never silently skipped"
}

test_push_age_uses_the_native_receipt_and_never_guesses() {
  local home repo
  home=$(mk_home push)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$((T0 - 14399))
  assert_not_contains "$(line_of "$home")" "push>4h" "a push 14399s ago is within 4h"
  refresh "$home" $((T0 + 301)) FAKE_NM_PUSHED_AT=$((T0 + 301 - 14401))
  assert_contains "$(line_of "$home")" "push>4h 1 (t1)" "a push older than 4h alarms"
  refresh "$home" $((T0 + 602))
  assert_contains "$(line_of "$home")" "push-age-unknown 1 (t1)" "no receipt means unknown, visibly alarmed"
  assert_not_contains "$(line_of "$home")" "push>4h" "an unknown age is never reported as old"
  pass "fm-antidrift-check: push age comes from the native receipt; absence is unknown, not guessed"
}

test_dirty_duration_is_tracked_and_never_backdated() {
  local home repo
  home=$(mk_home dirty)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  : > "$TMP_ROOT/old-mtime"
  printf 'x\n' > "$repo/new.txt"
  touch -t 200001010000 "$repo/new.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  assert_not_contains "$(line_of "$home")" "dirty>30m" "an old file time never backdates the first observation"
  refresh "$home" $((T0 + 1799)) FAKE_NM_PUSHED_AT=$((T0 + 1799))
  assert_not_contains "$(line_of "$home")" "dirty>30m" "29m59s observed is not yet an alarm"
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$((T0 + 1800))
  assert_contains "$(line_of "$home")" "dirty>30m 1 (t1)" "30 minutes of continuous observation alarms"
  rm "$repo/new.txt"
  refresh "$home" $((T0 + 1900)) FAKE_NM_PUSHED_AT=$((T0 + 1900))
  assert_not_contains "$(line_of "$home")" "dirty>30m" "a clean tree clears the alarm"
  printf 'y\n' > "$repo/new2.txt"
  refresh "$home" $((T0 + 2000)) FAKE_NM_PUSHED_AT=$((T0 + 2000))
  refresh "$home" $((T0 + 2000 + 1799)) FAKE_NM_PUSHED_AT=$((T0 + 3799))
  assert_not_contains "$(line_of "$home")" "dirty>30m" "a new dirty period restarts the clock"
  pass "fm-antidrift-check: dirty duration is observed continuously, persisted, never backdated from file times"
}

test_a_deleted_tracked_file_counts_as_dirty() {
  local home repo
  home=$(mk_home deleted)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  rm "$repo/a.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$((T0 + 1800))
  assert_contains "$(line_of "$home")" "dirty>30m 1 (t1)" "a deletion is an uncommitted change"
  pass "fm-antidrift-check: deletions count as uncommitted changes"
}

test_push_disabled_remote_is_reported() {
  local home
  home=$(mk_home disabled)
  mk_repo "$home/projects/p" github; register_project "$home" p
  git -C "$home/projects/p" remote set-url --push origin DISABLED
  refresh "$home" $T0
  assert_contains "$(line_of "$home")" "push-DISABLED 1 (p:origin)" "a remote whose push URL is DISABLED alarms"
  pass "fm-antidrift-check: push DISABLED remotes are reported"
}

test_pr_age_presentation_and_unknown_forge() {
  local home out="$TMP_ROOT/pr.out"
  home=$(mk_home pr)
  mk_repo "$home/projects/p" github; register_project "$home" p
  printf '  7,"t",open,me,no,none,"https://github.com/acme/p/pull/7",2d ago\n' > "$out"
  refresh "$home" $T0 FAKE_PR_OUT="$out"
  assert_contains "$(line_of "$home")" "PR>48h-unregistered 1 (7)" "an unregistered 2d-old PR alarms"
  printf 'pr=https://github.com/acme/p/pull/7\n' > "$home/state/x.meta"
  refresh "$home" $((T0 + 1900)) FAKE_PR_OUT="$out"
  assert_contains "$(line_of "$home")" "PR>48h-presentation-unproven 1 (7)" "registered is not presented"
  assert_not_contains "$(line_of "$home")" "non-enregistrée" "a registered PR is no longer unregistered"
  printf 'pr=https://github.com/acme/p/pull/7\npr_presented=1:https://github.com/acme/p/pull/7\n' > "$home/state/x.meta"
  refresh "$home" $((T0 + 3800)) FAKE_PR_OUT="$out"
  assert_not_contains "$(line_of "$home")" "PR>48h" "a PR with a presentation receipt is not reminded"
  printf '  8,"t",open,me,no,none,"https://github.com/acme/p/pull/8",1d ago\n' > "$out"
  refresh "$home" $((T0 + 5700)) FAKE_PR_OUT="$out"
  assert_not_contains "$(line_of "$home")" "PR>48h" "a 1d-old PR is under the threshold"
  refresh "$home" $((T0 + 7600)) FAKE_PR_FAIL=1
  assert_contains "$(line_of "$home")" "unknown: PR" "a forge that cannot answer is unknown, not clean"
  printf '  7,"t",open,me,no,none\n' > "$out"
  refresh "$home" $((T0 + 9500)) FAKE_PR_OUT="$out" FAKE_PR_NOURL=1
  assert_contains "$(line_of "$home")" "unknown: PR" "a table with rows but no url/age column is unknown, not clean"
  pass "fm-antidrift-check: PR age, registered-vs-presented, and forge-unknown are distinct"
}

test_foreign_or_reassigned_slots_never_leak_to_snapshots() {
  local home repo before after
  home=$(mk_home slot)
  repo=$(mk_task "$home" t1 ship other-task)
  before=$(fingerprint "$repo")
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  after=$(fingerprint "$repo")
  assert_contains "$(line_of "$home")" "slot-unproven 1 (t1:other)" "a slot claimed by another task is alarmed"
  assert_equals "$before" "$after" "the foreign slot's repository is byte-identical"
  [ -z "$(find "$home/state/wip" -maxdepth 1 -name '*.git' 2>/dev/null)" ] || fail "no snapshot may exist for a reassigned slot"
  rm "$home/../pool/t1/.fm-slot-owner"
  refresh "$home" $((T0 + 10)) FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(line_of "$home")" "slot-unproven 1 (t1:absent)" "an unclaimed slot is not proven"
  pass "fm-antidrift-check: reassigned or unclaimed slots are skipped and alarmed, never snapshotted"
}

test_a_reused_slot_does_not_inherit_the_previous_tasks_state() {
  local home repo shadow
  home=$(mk_home reuse)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w1\n' > "$repo/w.txt"
  printf 'done: first task finished\n' >> "$home/state/t1.status"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  # the pool hands the same slot to the next task
  rm -f "$home/state/t1.meta" "$home/state/t1.status"
  printf 'worktree=%s\nkind=ship\nproject=%s/projects/none\n' "$repo" "$home" > "$home/state/t2.meta"
  : > "$home/state/t2.status"
  printf 'task=t2\nhome=%s\n' "$home" > "$home/../pool/t1/.fm-slot-owner"
  printf 'w2\n' > "$repo/w.txt"
  refresh "$home" $((T0 + 5)) FAKE_NM_PUSHED_AT=$((T0 + 5))
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  assert_contains "$(git --git-dir="$shadow" for-each-ref --format='%(refname)')" "refs/heads/wip/t2/" "the new owner's first checkpoint is not delayed by the old cadence"
  pass "fm-antidrift-check: a reused pool slot starts the new task with fresh WIP state"
}

test_secondmate_records_are_never_inventoried() {
  local home second
  home=$(mk_home mate)
  second="$TMP_ROOT/mate/otherhome"
  mk_repo "$second"
  fm_write_secondmate_meta "$home/state/mate1.meta" "$second"
  refresh "$home" $T0
  assert_equals "" "$(line_of "$home")" "a secondmate record raises no alarm in the parent home"
  [ -z "$(find "$home/state/wip" -maxdepth 1 -name '*.git' 2>/dev/null)" ] || fail "no WIP state may be created for a secondmate home"
  pass "fm-antidrift-check: secondmate records are never adopted as worktrees"
}

test_worktree_list_is_not_an_inventory() {
  local home main
  home=$(mk_home foreign)
  mk_repo "$home/projects/shared" github; register_project "$home" shared
  main="$home/projects/shared"
  git -C "$main" worktree add -q -b other-home-branch "$home/../foreign-pool-copy"
  printf 'dirty\n' > "$home/../foreign-pool-copy/x"
  refresh "$home" $T0
  refresh "$home" $((T0 + 1800))
  assert_not_contains "$(line_of "$home")" "foreign" "another home's pool copy in a shared git dir is not adopted"
  assert_not_contains "$(line_of "$home")" "other-home-branch" "its branch is not inventoried"
  ! grep -rq foreign-pool-copy "$home/state/wip" 2>/dev/null || fail "no WIP state may be created for it"
  pass "fm-antidrift-check: git worktree list is never used as an inventory"
}

test_own_task_roots_are_included_with_an_empty_registry() {
  local home repo
  home=$(mk_home ownroots)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/work.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  [ -n "$(find "$home/state/wip" -maxdepth 1 -name '*.git' 2>/dev/null)" ] || fail "an own task worktree must be snapshotted even with an empty registry"
  pass "fm-antidrift-check: own task worktrees are inventoried without a registry"
}

test_checkpoint_cadence_and_milestone_trigger() {
  local home repo shadow n1 n2 n3
  home=$(mk_home cadence)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'one\n' > "$repo/f.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  n1=$(git --git-dir="$shadow" rev-list --all --count)
  printf 'two\n' > "$repo/f.txt"
  refresh "$home" $((T0 + 1799)) FAKE_NM_PUSHED_AT=$T0
  n2=$(git --git-dir="$shadow" rev-list --all --count)
  assert_equals "$n1" "$n2" "no checkpoint before 30 minutes without a milestone"
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$T0
  n2=$(git --git-dir="$shadow" rev-list --all --count)
  assert_equals $((n1 + 1)) "$n2" "a checkpoint exactly at 30 minutes"
  printf 'three\n' > "$repo/f.txt"
  printf 'done: PR https://github.com/acme/x/pull/1 checks green\n' >> "$home/state/t1.status"
  refresh "$home" $((T0 + 1810)) FAKE_NM_PUSHED_AT=$T0
  n3=$(git --git-dir="$shadow" rev-list --all --count)
  assert_equals $((n2 + 1)) "$n3" "a done: status line triggers an immediate milestone checkpoint"
  pass "fm-antidrift-check: 30-minute cadence and immediate milestone checkpoints"
}

test_publication_cadence_and_daily_action() {
  local home repo
  home=$(mk_home publish)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  git init -q --bare "$TMP_ROOT/publish/wip.git"
  git config --file "$GIT_GLOBAL" --add "url.$TMP_ROOT/publish/wip.git.insteadOf" "https://github.com/acme/wip.git"
  printf 'none acme/wip\n' > "$home/config/wip-remotes"
  # project name for a task is the basename of its project path ("none" here)
  printf 'none acme/wip\n' > "$home/config/wip-remotes"
  printf 'w\n' > "$repo/w.txt"
  : > "$TMP_ROOT/calls"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(git --git-dir="$TMP_ROOT/publish/wip.git" for-each-ref --format='%(refname)')" "refs/heads/wip/t1/" "the first checkpoint is published"
  : > "$TMP_ROOT/calls"
  refresh "$home" $((T0 + 600)) FAKE_NM_PUSHED_AT=$T0
  assert_equals 0 "$(grep -c 'repo view' "$TMP_ROOT/calls")" "nothing new and not yet a day: no push action"
  refresh "$home" $((T0 + 82800)) FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(cat "$TMP_ROOT/calls")" "repo view" "after a day an automatic push action runs even with nothing new"
  pass "fm-antidrift-check: first publication immediate, daily push action even when unchanged"
}

test_blocked_publication_is_visible_not_silent() {
  local home repo
  # a public repository blocks and alarms
  home=$(mk_home blocked)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  printf 'none acme/wip\n' > "$home/config/wip-remotes"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0 FAKE_VIS=public
  assert_contains "$(line_of "$home")" "WIP-blocked 1 (t1:private-unproven)" "a public repository blocks and alarms"
  # no configured remote is reported
  home=$(mk_home noremote)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  : > "$home/config/wip-remotes"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(line_of "$home")" "t1:no-remote" "no configured remote is reported"
  # a project declared 'none' is a posture, not a fault
  home=$(mk_home offsilent)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  printf 'none none\n' > "$home/config/wip-remotes"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  assert_not_contains "$(line_of "$home")" "WIP-blocked" "a project declared 'none' is a posture, not a fault"
  pass "fm-antidrift-check: blocked publication is alarmed with its reason; declared-off is silent"
}

test_source_repositories_are_never_touched_by_a_full_refresh() {
  local home repo before after idx_mtime_before idx_mtime_after
  home=$(mk_home custody)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  printf 'edit\n' >> "$repo/a.txt"
  before=$(fingerprint "$repo")
  idx_mtime_before=$(stat -c %Y "$repo/.git/index" 2>/dev/null || stat -f %m "$repo/.git/index")
  sleep 1
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$T0
  after=$(fingerprint "$repo")
  idx_mtime_after=$(stat -c %Y "$repo/.git/index" 2>/dev/null || stat -f %m "$repo/.git/index")
  assert_equals "$before" "$after" "index, refs, objects and HEAD are unchanged"
  assert_equals "$idx_mtime_before" "$idx_mtime_after" "the source index is not even rewritten"
  pass "fm-antidrift-check: a full refresh leaves the source byte-identical"
}

test_the_cached_reader_reports_news_once() {
  local home out
  home=$(mk_home reader)
  mk_repo "$home/projects/lonely"; register_project "$home" lonely
  refresh "$home" $T0
  out=$(FM_HOME="$home" "$AD" cached)
  assert_contains "$out" "no-upstream 1" "a new cached line is news"
  mark_reported_at "$home" $T0 "$out"
  [ -z "$(cached_at "$home" $T0)" ] || fail "a reported line is not news again"
  mk_repo "$home/projects/second"; register_project "$home" second
  refresh "$home" $((T0 + 10))
  out=$(FM_HOME="$home" "$AD" cached)
  assert_contains "$out" "no-upstream 2" "a changed line is news again"
  pass "fm-antidrift-check: the cached reader reports a line once until it changes"
}

test_the_line_is_one_bounded_line() {
  local home i line
  home=$(mk_home bound)
  for i in $(seq 1 30); do mk_repo "$home/projects/proj$i"; register_project "$home" "proj$i"; done
  refresh "$home" $T0
  line=$(line_of "$home")
  [ "$(printf '%s' "$line" | wc -l | tr -d ' ')" = 0 ] || fail "the line must be a single line"
  [ "${#line}" -le 240 ] || fail "the line must be bounded to 240 characters (got ${#line})"
  assert_contains "$line" "+28" "overflow is summarized, not dropped"
  pass "fm-antidrift-check: thirty findings coalesce into one bounded line"
}

test_a_held_lock_makes_the_producer_a_no_op() {
  local home
  home=$(mk_home lock)
  mk_repo "$home/projects/lonely"; register_project "$home" lonely
  mkdir -p "$home/state/.antidrift.lock"
  printf '%s\n' "$$" > "$home/state/.antidrift.lock/pid"
  refresh "$home" $T0
  assert_absent "$home/state/.antidrift" "a running producer is never overlapped"
  pass "fm-antidrift-check: a held producer lock makes refresh a no-op"
}

# ---- review corrections (A-F matrix): reliability, load, correctness ----

# The antidrift cache reader, run as the real executable with a pinned clock.
cached_at() {  # <home> <epoch>
  FM_HOME="$1" FM_WIP_NOW="$2" FM_CHECK_INTERVAL=300 "$AD" cached
}

mark_reported_at() {  # <home> <epoch> <line> [sig]
  ( STATE="$1/state"; FM_WIP_NOW=$2; export FM_WIP_NOW
    # shellcheck source=bin/fm-wip-lib.sh
    . "$ROOT/bin/fm-wip-lib.sh"; antidrift_mark_reported "$3" "${4-$(sed -n 's/^sig=//p' "$1/state/.antidrift")}" )
}

push_calls() { grep -c 'repo view' "$TMP_ROOT/calls" 2>/dev/null || true; }

# A2/B5/C2/D4: a failed or non-applicable publication is retried only after a backoff.
test_failed_publication_is_retried_only_after_a_backoff() {
  local home repo
  home=$(mk_home backoff)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  printf 'none acme/wip\n' > "$home/config/wip-remotes"
  : > "$TMP_ROOT/calls"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0 FAKE_VIS=public
  assert_equals 1 "$(push_calls)" "the first attempt asks the forge once"
  refresh "$home" $((T0 + 300)) FAKE_NM_PUSHED_AT=$T0 FAKE_VIS=public
  assert_equals 1 "$(push_calls)" "a failed attempt is not retried 300 s later"
  refresh "$home" $((T0 + 900)) FAKE_NM_PUSHED_AT=$T0 FAKE_VIS=public
  assert_equals 2 "$(push_calls)" "it is retried once the 900 s backoff has passed"
  pass "fm-antidrift-check: a failed publication is retried after a backoff, not every tick"
}

test_a_publication_declared_off_is_never_retried_each_tick() {
  local home repo kdir a1 a2
  home=$(mk_home offposture)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  printf 'none none\n' > "$home/config/wip-remotes"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  kdir=$(find "$home/state/wip" -maxdepth 1 -mindepth 1 -type d -not -name '*.git' | head -n 1)
  a1=$(sed -n 's/^last_attempt=//p' "$kdir/push")
  [ -n "$a1" ] || fail "the posture is recorded with the time it was settled"
  refresh "$home" $((T0 + 300)) FAKE_NM_PUSHED_AT=$T0
  a2=$(sed -n 's/^last_attempt=//p' "$kdir/push")
  assert_equals "$a1" "$a2" "a project declared 'none' is not even attempted again on the next tick"
  pass "fm-antidrift-check: a publication declared off is not retried every tick"
}

# A6/B4/C1/D2: the native status read is cached per worktree.
test_native_status_reads_are_cached_per_worktree() {
  local home repo log="$TMP_ROOT/nmcalls"
  home=$(mk_home nmcache)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  mk_repo "$home/projects/clone" github; register_project "$home" clone
  cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "$PWD" >> "${FAKE_NM_LOG:-/dev/null}"
[ -n "${FAKE_NM_PUSHED_AT:-}" ] || exit 1
printf 'branch_sync:\n  state: pipeline_owned\n  pipeline:\n    run: "r1"\n    pushed_at: %s\n    pushed_head: %s\n  remote:\n    freshness: pipeline_push\n' "$FAKE_NM_PUSHED_AT" "${FAKE_NM_PUSHED_HEAD:-0000000}"
SH
  : > "$log"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0 FAKE_NM_LOG="$log"
  refresh "$home" $((T0 + 60)) FAKE_NM_PUSHED_AT=$T0 FAKE_NM_LOG="$log"
  refresh "$home" $((T0 + 400)) FAKE_NM_PUSHED_AT=$T0 FAKE_NM_LOG="$log"
  assert_equals 2 "$(grep -c "pool/t1/repo" "$log")" "the task worktree is asked at T0 and again after 300 s, not at +60 s"
  assert_equals 1 "$(grep -c "projects/clone" "$log")" "a registered clone is asked once inside 1800 s"
  pass "fm-antidrift-check: native status calls are cached (tasks 300 s, other worktrees 1800 s)"
}

# A11/C7/D9 (accepted continuous dirty clock): an unrelated commit does not reset it.
test_dirty_clock_survives_an_unrelated_commit_and_clears_when_clean() {
  local home repo
  home=$(mk_home dirtycommit)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'edit\n' >> "$repo/a.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  printf 'other\n' > "$repo/other.txt"
  git -C "$repo" add other.txt
  git -C "$repo" commit -qm "unrelated commit"
  refresh "$home" $((T0 + 600)) FAKE_NM_PUSHED_AT=$((T0 + 600))
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$((T0 + 1800))
  assert_contains "$(line_of "$home")" "dirty>30m 1 (t1)" "uncommitted edits stay dirty through an unrelated commit"
  git -C "$repo" checkout -q -- a.txt
  refresh "$home" $((T0 + 1900)) FAKE_NM_PUSHED_AT=$((T0 + 1900))
  assert_not_contains "$(line_of "$home")" "dirty>30m" "a clean tree clears the clock"
  pass "fm-antidrift-check: the dirty clock is continuous across unrelated commits"
}

# F5: commits the pipeline already pushed are not counted from a stale tracking ref.
test_unpushed_count_honours_the_native_pushed_head() {
  local home repo i head
  home=$(mk_home pushedhead)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do git -C "$repo" commit -q --allow-empty -m "c$i"; done
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q "$(git -C "$repo" config remote.origin.url)" "HEAD:refs/heads/fm/t1"
  git -C "$repo" update-ref -d refs/remotes/origin/fm/t1 2>/dev/null || true
  git -C "$repo" update-ref refs/remotes/origin/fm/t1 "$(git -C "$repo" rev-parse HEAD~12)"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0 FAKE_NM_PUSHED_HEAD="$head"
  assert_not_contains "$(line_of "$home")" "unpushed>10" "commits the pipeline pushed are not counted against a stale tracking ref"
  refresh "$home" $((T0 + 301)) FAKE_NM_PUSHED_AT=$T0 FAKE_NM_PUSHED_HEAD=0000000
  assert_contains "$(line_of "$home")" "unpushed>10 1 (t1:12)" "without a usable pushed head the tracking ref still counts"
  pass "fm-antidrift-check: the unpushed count uses the native pushed head when it is newer than the tracking ref"
}

# E6: a native receipt that is not a plain epoch is unknown, never clean and never old.
test_a_non_epoch_native_receipt_reads_unknown() {
  local home repo
  home=$(mk_home isoreceipt)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT='"2026-10-14T08:00:00Z"'
  assert_contains "$(line_of "$home")" "push-age-unknown 1 (t1)" "an ISO or quoted timestamp reads unknown"
  assert_not_contains "$(line_of "$home")" "push>4h" "and is never reported as an old push"
  pass "fm-antidrift-check: a non-epoch native receipt is unknown"
}

# E8: scouts are excluded from the push-age alarms, as documented.
test_scouts_are_excluded_from_push_age_alarms() {
  local home repo
  home=$(mk_home scoutage)
  repo=$(mk_task "$home" s1 scout)
  git -C "$repo" push -q -u origin "fm/s1"
  refresh "$home" $T0
  assert_not_contains "$(line_of "$home")" "push-age-unknown" "a scout worktree carries no push-age alarm"
  pass "fm-antidrift-check: scout worktrees carry no push-age alarm"
}

# B8: a truncated or recreated status log must not hide later done: lines.
test_a_truncated_status_log_still_triggers_milestones() {
  local home repo shadow n1 n2
  home=$(mk_home truncstatus)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'working: a long first log line that makes the offset large\ndone: first\n' > "$home/state/t1.status"
  printf 'x\n' > "$repo/x.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  shadow=$(find "$home/state/wip" -maxdepth 1 -name '*.git' | head -n 1)
  n1=$(git --git-dir="$shadow" rev-list --all --count)
  printf 'done: new\n' > "$home/state/t1.status"
  printf 'y\n' > "$repo/y.txt"
  refresh "$home" $((T0 + 10)) FAKE_NM_PUSHED_AT=$T0
  n2=$(git --git-dir="$shadow" rev-list --all --count)
  assert_equals $((n1 + 1)) "$n2" "a recreated, shorter status log still raises a milestone checkpoint"
  pass "fm-antidrift-check: a truncated status log does not hide milestones"
}

# B9: only real GitHub hosts count as a GitHub upstream.
test_only_real_github_hosts_count_as_a_github_upstream() {
  local home p
  home=$(mk_home hosts)
  mk_repo "$home/projects/fake" github; register_project "$home" fake
  p="$home/projects/fake"
  git -C "$p" config remote.origin.url "https://notgithub.com/acme/x.git"
  refresh "$home" $T0
  assert_contains "$(line_of "$home")" "no-upstream 1 (fake)" "notgithub.com is not GitHub"
  git -C "$p" config remote.origin.url "https://github.com.evil.example/acme/x.git"
  refresh "$home" $((T0 + 1))
  assert_contains "$(line_of "$home")" "no-upstream 1 (fake)" "github.com.evil.example is not GitHub"
  git -C "$p" config remote.origin.url "git@github.com:acme/x.git"
  refresh "$home" $((T0 + 2))
  assert_not_contains "$(line_of "$home")" "no-upstream" "git@github.com: is GitHub"
  pass "fm-antidrift-check: the GitHub upstream test is anchored to the real host"
}

# C6: a non-GitHub (GitLab) upstream is alarmed by design (accepted requirement).
test_a_gitlab_upstream_is_alarmed_as_not_github() {
  local home p
  home=$(mk_home gitlab)
  mk_repo "$home/projects/gl" github; register_project "$home" gl
  p="$home/projects/gl"
  git -C "$p" config remote.origin.url "https://gitlab.com/acme/x.git"
  refresh "$home" $T0
  assert_contains "$(line_of "$home")" "no-upstream 1 (gl)" "every produced worktree needs a GitHub upstream, GitLab does not satisfy it"
  pass "fm-antidrift-check: a non-GitHub upstream is alarmed (accepted requirement pinned)"
}

# C5: an unparsable PR age is unknown, never clean.
test_an_unparsable_pr_age_is_unknown() {
  local home out="$TMP_ROOT/pr-badage.out"
  home=$(mk_home badage)
  mk_repo "$home/projects/p" github; register_project "$home" p
  printf '  7,"t",open,me,no,none,"https://github.com/acme/p/pull/7",3x ago\n' > "$out"
  refresh "$home" $T0 FAKE_PR_OUT="$out"
  assert_contains "$(line_of "$home")" "unknown: PR-age" "an age the parser cannot read is reported unknown"
  assert_not_contains "$(line_of "$home")" "PR>48h" "and is not silently treated as a young PR"
  pass "fm-antidrift-check: an unparsable PR age is unknown, not clean"
}

# C9: only a push URL that IS DISABLED is the alarm, not any URL that contains the word.
test_push_disabled_matches_the_value_not_a_substring() {
  local home p
  home=$(mk_home disabledexact)
  mk_repo "$home/projects/p" github; register_project "$home" p
  p="$home/projects/p"
  git -C "$p" remote set-url --push origin "https://github.com/acme/disabled-feature.git"
  refresh "$home" $T0
  assert_not_contains "$(line_of "$home")" "push-DISABLED" "a repository named disabled-feature is not a disabled push"
  git -C "$p" remote set-url --push origin disabled
  refresh "$home" $((T0 + 1))
  assert_contains "$(line_of "$home")" "push-DISABLED 1 (p:origin)" "the value DISABLED (any case) is the alarm"
  pass "fm-antidrift-check: push DISABLED matches the value, not a substring"
}

# D1: ownership of a non-Treehouse (for example Orca) worktree rests on record exclusivity.
test_a_non_treehouse_worktree_is_inventoried_on_record_exclusivity() {
  local home wt
  home=$(mk_home orca)
  wt="$TMP_ROOT/orca/orca-wt"
  mk_repo "$wt" github
  git -C "$wt" checkout -q -b fm/o1
  printf 'worktree=%s\nkind=ship\nproject=%s\n' "$wt" "$home" > "$home/state/o1.meta"
  : > "$home/state/o1.status"
  printf 'w\n' > "$wt/w.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  assert_not_contains "$(line_of "$home")" "slot-unproven" "a worktree outside any Treehouse pool is not alarmed for a missing claim"
  [ -n "$(find "$home/state/wip" -maxdepth 1 -name '*.git' 2>/dev/null)" ] || fail "its work must be checkpointed"
  # two records naming one live path stay ambiguous and are refused
  printf 'worktree=%s\nkind=ship\nproject=%s\n' "$wt" "$home" > "$home/state/o2.meta"
  : > "$home/state/o2.status"
  refresh "$home" $((T0 + 1)) FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(line_of "$home")" "slot-unproven" "two records for one path are ambiguous and refused"
  pass "fm-antidrift-check: non-Treehouse worktrees rely on record exclusivity, ambiguity refuses"
}

# A13: critical segments survive the cap.
test_critical_segments_survive_the_cap() {
  local home n1 n2
  home=$(mk_home critfirst)
  n1=$(printf 'a%.0s' $(seq 1 100)); n2=$(printf 'b%.0s' $(seq 1 100))
  mk_repo "$home/projects/${n1}1"; register_project "$home" "${n1}1"
  mk_repo "$home/projects/${n2}2"; register_project "$home" "${n2}2"
  mk_task "$home" t1 ship other-task >/dev/null
  refresh "$home" $T0
  assert_contains "$(line_of "$home")" "slot-unproven" "the slot alarm survives the 240-character cap"
  pass "fm-antidrift-check: critical segments are composed first and survive the cap"
}

# A13: a change that only touches the truncated tail still wakes (digest of the full composition).
test_a_change_in_the_truncated_tail_is_still_news() {
  local home
  home=$(mk_home tailsig)
  mkdir -p "$home/state"
  printf 'fm-antidrift-v1\nepoch=%s\nline=antidrift: no-upstream 1 (x) [truncated]\nsig=aaaa\n' "$T0" > "$home/state/.antidrift"
  mark_reported_at "$home" $T0 "antidrift: no-upstream 1 (x) [truncated]" aaaa
  [ -z "$(cached_at "$home" $T0)" ] || fail "an identical line and digest is not news"
  printf 'fm-antidrift-v1\nepoch=%s\nline=antidrift: no-upstream 1 (x) [truncated]\nsig=bbbb\n' "$T0" > "$home/state/.antidrift"
  [ -n "$(cached_at "$home" $T0)" ] || fail "the same capped line with a different full digest must be news"
  pass "fm-antidrift-check: a change hidden in the truncated tail is still news"
}

# E10: names in a segment are sorted, so inventory order never makes the line flap.
test_names_in_a_segment_are_sorted() {
  local home n
  home=$(mk_home sorted)
  for n in zeta mid alpha; do mk_repo "$home/projects/$n"; register_project "$home" "$n"; done
  refresh "$home" $T0
  assert_contains "$(line_of "$home")" "no-upstream 3 (alpha,mid,+1)" "names are listed in sorted order"
  pass "fm-antidrift-check: segment names are sorted"
}

# D7: a persistent unchanged alarm is announced again after a reminder interval.
test_a_persistent_alarm_is_reminded_after_the_interval() {
  local home out
  home=$(mk_home remind)
  mk_repo "$home/projects/lonely"; register_project "$home" lonely
  refresh "$home" $T0
  out=$(cached_at "$home" $T0)
  [ -n "$out" ] || fail "the first sight is news"
  mark_reported_at "$home" $T0 "$out"
  refresh "$home" $((T0 + 21599))
  [ -z "$(cached_at "$home" $((T0 + 21599)))" ] || fail "inside the reminder interval the same line is not news"
  refresh "$home" $((T0 + 21600))
  [ -n "$(cached_at "$home" $((T0 + 21600)))" ] || fail "after the reminder interval an unchanged alarm is announced again"
  pass "fm-antidrift-check: a persistent alarm is re-announced after six hours"
}

# F7/C4: a cache that stopped being refreshed is itself visible.
test_a_stale_cache_is_reported_once_as_a_stale_producer() {
  local home out
  home=$(mk_home stale)
  mk_repo "$home/projects/lonely"; register_project "$home" lonely
  refresh "$home" $T0
  out=$(cached_at "$home" $((T0 + 800)))
  assert_not_contains "$out" "producer-stale" "a fresh enough cache is trusted"
  mark_reported_at "$home" $((T0 + 800)) "$out"
  out=$(cached_at "$home" $((T0 + 5000)))
  assert_contains "$out" "unknown: producer-stale" "a cache older than the bound reports a stale producer"
  pass "fm-antidrift-check: a stale cache is reported as a stale producer"
}

# A producer that never published its first cache is visible through its launch time.
test_a_producer_that_never_published_is_reported_stale() {
  local home out
  home=$(mk_home nevercache)
  printf '%s\n' "$T0" > "$home/state/.antidrift-kick"
  out=$(cached_at "$home" $((T0 + 899)))
  [ -z "$out" ] || fail "a kick younger than the bound stays silent: $out"
  out=$(cached_at "$home" $((T0 + 901)))
  assert_contains "$out" "unknown: producer-stale" "a launch that never published is reported stale"
  home=$(mk_home nokick)
  [ -z "$(cached_at "$home" $((T0 + 5000)))" ] || fail "nothing ever launched stays silent"
  printf 'junk\n' > "$home/state/.antidrift-kick"
  [ -z "$(cached_at "$home" $((T0 + 5000)))" ] || fail "a malformed kick stays silent"
  pass "fm-antidrift-check: a producer that never published is reported stale"
}

# C4: a blocked git read cannot silence the guard.
test_a_blocked_git_read_is_reported_unknown() {
  local home real
  home=$(mk_home gitblock)
  mk_repo "$home/projects/p" github; register_project "$home" p
  real=$(command -v git)
  mkdir -p "$TMP_ROOT/slowgit"
  printf '#!/bin/sh\ncase "$*" in *status*) sleep 6 ;; esac\nexec %s "$@"\n' "$real" > "$TMP_ROOT/slowgit/git"
  chmod +x "$TMP_ROOT/slowgit/git"
  env PATH="$TMP_ROOT/slowgit:$PATH" FM_WIP_GIT_TIMEOUT=1 FM_HOME="$home" FM_WIP_NOW=$T0 FM_CHECK_INTERVAL=300 \
    FAKE_CALLS="$TMP_ROOT/calls" "$AD" refresh
  assert_contains "$(line_of "$home")" "git-timeout:p" "a blocked git read is reported unknown by name"
  pass "fm-antidrift-check: a blocked git read is bounded and reported"
}

# E3: one task on two copies must not collide on a single remote reference.
test_the_same_task_on_two_copies_publishes_distinct_references() {
  local home repo1 repo2 remote r1 r2
  home=$(mk_home twocopies)
  repo1=$(mk_task "$home" t1 ship)
  git -C "$repo1" push -q -u origin "fm/t1"
  remote="$TMP_ROOT/twocopies/wip.git"
  git init -q --bare "$remote"
  git config --file "$GIT_GLOBAL" "url.$remote.insteadOf" "https://github.com/acme/twocopies.git"
  printf 'none acme/twocopies\n' > "$home/config/wip-remotes"
  printf 'one\n' > "$repo1/one.txt"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  # the pool hands the same task a different copy
  mkdir -p "$home/../pool2/t1"
  mk_repo "$home/../pool2/t1/repo" github
  git -C "$home/../pool2/t1/repo" checkout -q -b fm/t1
  printf 'task=t1\nhome=%s\n' "$home" > "$home/../pool2/t1/.fm-slot-owner"
  : > "$home/../pool2/treehouse-state.json"
  printf 'worktree=%s\nkind=ship\nproject=%s/projects/none\n' "$(cd "$home/../pool2/t1/repo" && pwd -P)" "$home" > "$home/state/t1.meta"
  printf 'two\n' > "$home/../pool2/t1/repo/two.txt"
  refresh "$home" $((T0 + 5400)) FAKE_NM_PUSHED_AT=$((T0 + 5400))
  r1=$(git --git-dir="$remote" for-each-ref --format='%(refname)' | wc -l | tr -d ' ')
  assert_equals 2 "$r1" "each copy publishes its own reference, no non-fast-forward collision"
  r2=$(git --git-dir="$remote" for-each-ref --format='%(refname)' | sort -u | wc -l | tr -d ' ')
  assert_equals 2 "$r2" "the two references are distinct"
  pass "fm-antidrift-check: one task on two copies publishes distinct references"
}

test_empty_inventory_is_quiet_and_schedules_the_next_run
test_no_upstream_alarm_and_scout_exclusion
test_unpushed_threshold_is_literal
test_push_age_applies_to_registry_clones_and_the_home_root_as_unknown
test_push_age_uses_the_native_receipt_and_never_guesses
test_dirty_duration_is_tracked_and_never_backdated
test_a_deleted_tracked_file_counts_as_dirty
test_push_disabled_remote_is_reported
test_pr_age_presentation_and_unknown_forge
test_foreign_or_reassigned_slots_never_leak_to_snapshots
test_a_reused_slot_does_not_inherit_the_previous_tasks_state
test_secondmate_records_are_never_inventoried
test_worktree_list_is_not_an_inventory
test_own_task_roots_are_included_with_an_empty_registry
test_checkpoint_cadence_and_milestone_trigger
test_publication_cadence_and_daily_action
test_blocked_publication_is_visible_not_silent
test_source_repositories_are_never_touched_by_a_full_refresh
test_the_cached_reader_reports_news_once
test_the_line_is_one_bounded_line
test_a_held_lock_makes_the_producer_a_no_op
test_failed_publication_is_retried_only_after_a_backoff
test_a_publication_declared_off_is_never_retried_each_tick
test_native_status_reads_are_cached_per_worktree
test_dirty_clock_survives_an_unrelated_commit_and_clears_when_clean
test_unpushed_count_honours_the_native_pushed_head
test_a_non_epoch_native_receipt_reads_unknown
test_scouts_are_excluded_from_push_age_alarms
test_a_truncated_status_log_still_triggers_milestones
test_only_real_github_hosts_count_as_a_github_upstream
test_a_gitlab_upstream_is_alarmed_as_not_github
test_an_unparsable_pr_age_is_unknown
test_push_disabled_matches_the_value_not_a_substring
test_a_non_treehouse_worktree_is_inventoried_on_record_exclusivity
test_critical_segments_survive_the_cap
test_a_change_in_the_truncated_tail_is_still_news
test_names_in_a_segment_are_sorted
test_a_persistent_alarm_is_reminded_after_the_interval
test_a_stale_cache_is_reported_once_as_a_stale_producer
test_a_producer_that_never_published_is_reported_stale
test_a_blocked_git_read_is_reported_unknown
test_the_same_task_on_two_copies_publishes_distinct_references
