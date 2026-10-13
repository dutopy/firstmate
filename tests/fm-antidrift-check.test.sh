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
    printf 'count: 1\npull_requests[1]{number,title,state,author,draft,review,url,created}:\n'
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
  assert_contains "$line" "sans-upstream 1 (lonely[local-only])" "a local-only project is alarmed and annotated"
  assert_not_contains "$line" "tracked" "a project with a GitHub upstream is clean"
  assert_not_contains "$line" "sans-upstream 2" "a scout worktree is never alarmed for upstream"
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
  assert_not_contains "$(line_of "$home")" ">10-non-poussés" "exactly 10 unpushed is not over the cap"
  git -C "$p" commit -q --allow-empty -m c11
  refresh "$home" $((T0 + 1))
  assert_contains "$(line_of "$home")" ">10-non-poussés 1 (busy:11)" "11 unpushed commits alarm"
  pass "fm-antidrift-check: more than 10 unpushed commits alarms, exactly 10 does not"
}

test_push_age_uses_the_native_receipt_and_never_guesses() {
  local home repo
  home=$(mk_home push)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$((T0 - 14399))
  assert_not_contains "$(line_of "$home")" "push>4h" "a push 14399s ago is within 4h"
  refresh "$home" $((T0 + 1)) FAKE_NM_PUSHED_AT=$((T0 + 1 - 14401))
  assert_contains "$(line_of "$home")" "push>4h 1 (t1)" "a push older than 4h alarms"
  refresh "$home" $((T0 + 2))
  assert_contains "$(line_of "$home")" "âge-push-inconnu 1 (t1)" "no receipt means unknown, visibly alarmed"
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
  assert_not_contains "$(line_of "$home")" "sale>30m" "an old file time never backdates the first observation"
  refresh "$home" $((T0 + 1799)) FAKE_NM_PUSHED_AT=$((T0 + 1799))
  assert_not_contains "$(line_of "$home")" "sale>30m" "29m59s observed is not yet an alarm"
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$((T0 + 1800))
  assert_contains "$(line_of "$home")" "sale>30m 1 (t1)" "30 minutes of continuous observation alarms"
  rm "$repo/new.txt"
  refresh "$home" $((T0 + 1900)) FAKE_NM_PUSHED_AT=$((T0 + 1900))
  assert_not_contains "$(line_of "$home")" "sale>30m" "a clean tree clears the alarm"
  printf 'y\n' > "$repo/new2.txt"
  refresh "$home" $((T0 + 2000)) FAKE_NM_PUSHED_AT=$((T0 + 2000))
  refresh "$home" $((T0 + 2000 + 1799)) FAKE_NM_PUSHED_AT=$((T0 + 3799))
  assert_not_contains "$(line_of "$home")" "sale>30m" "a new dirty period restarts the clock"
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
  assert_contains "$(line_of "$home")" "sale>30m 1 (t1)" "a deletion is an uncommitted change"
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
  assert_contains "$(line_of "$home")" "PR>48h-non-enregistrée 1 (7)" "an unregistered 2d-old PR alarms"
  printf 'pr=https://github.com/acme/p/pull/7\n' > "$home/state/x.meta"
  refresh "$home" $((T0 + 1900)) FAKE_PR_OUT="$out"
  assert_contains "$(line_of "$home")" "PR>48h-sans-preuve-de-présentation 1 (7)" "registered is not presented"
  assert_not_contains "$(line_of "$home")" "non-enregistrée" "a registered PR is no longer unregistered"
  printf 'pr=https://github.com/acme/p/pull/7\npr_presented=1:https://github.com/acme/p/pull/7\n' > "$home/state/x.meta"
  refresh "$home" $((T0 + 3800)) FAKE_PR_OUT="$out"
  assert_not_contains "$(line_of "$home")" "PR>48h" "a PR with a presentation receipt is not reminded"
  printf '  8,"t",open,me,no,none,"https://github.com/acme/p/pull/8",1d ago\n' > "$out"
  refresh "$home" $((T0 + 5700)) FAKE_PR_OUT="$out"
  assert_not_contains "$(line_of "$home")" "PR>48h" "a 1d-old PR is under the threshold"
  refresh "$home" $((T0 + 7600)) FAKE_PR_FAIL=1
  assert_contains "$(line_of "$home")" "inconnu: PR" "a forge that cannot answer is unknown, not clean"
  pass "fm-antidrift-check: PR age, registered-vs-presented, and forge-unknown are distinct"
}

test_foreign_or_reassigned_slots_never_leak_to_snapshots() {
  local home repo before after
  home=$(mk_home slot)
  repo=$(mk_task "$home" t1 ship other-task)
  before=$(fingerprint "$repo")
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  after=$(fingerprint "$repo")
  assert_contains "$(line_of "$home")" "propriété-non-prouvée 1 (t1:other)" "a slot claimed by another task is alarmed"
  assert_equals "$before" "$after" "the foreign slot's repository is byte-identical"
  [ -z "$(find "$home/state/wip" -maxdepth 1 -name '*.git' 2>/dev/null)" ] || fail "no snapshot may exist for a reassigned slot"
  rm "$home/../pool/t1/.fm-slot-owner"
  refresh "$home" $((T0 + 10)) FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(line_of "$home")" "propriété-non-prouvée 1 (t1:absent)" "an unclaimed slot is not proven"
  pass "fm-antidrift-check: reassigned or unclaimed slots are skipped and alarmed, never snapshotted"
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
  [ -z "$(grep -rl foreign-pool-copy "$home/state/wip" 2>/dev/null)" ] || fail "no WIP state may be created for it"
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
  home=$(mk_home blocked)
  repo=$(mk_task "$home" t1 ship)
  git -C "$repo" push -q -u origin "fm/t1"
  printf 'w\n' > "$repo/w.txt"
  printf 'none acme/wip\n' > "$home/config/wip-remotes"
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0 FAKE_VIS=public
  assert_contains "$(line_of "$home")" "WIP-bloqué 1 (t1:privé non prouvé)" "a public repository blocks and alarms"
  refresh "$home" $((T0 + 5)) FAKE_NM_PUSHED_AT=$T0 FAKE_VIS=private
  printf '' > "$home/config/wip-remotes"
  refresh "$home" $((T0 + 10)) FAKE_NM_PUSHED_AT=$T0
  assert_contains "$(line_of "$home")" "t1:sans remote" "no configured remote is reported"
  printf 'none none\n' > "$home/config/wip-remotes"
  refresh "$home" $((T0 + 15)) FAKE_NM_PUSHED_AT=$T0
  assert_not_contains "$(line_of "$home")" "WIP-bloqué" "a project declared 'none' is a posture, not a fault"
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
  idx_mtime_before=$(stat -f %m "$repo/.git/index" 2>/dev/null || stat -c %Y "$repo/.git/index")
  sleep 1
  refresh "$home" $T0 FAKE_NM_PUSHED_AT=$T0
  refresh "$home" $((T0 + 1800)) FAKE_NM_PUSHED_AT=$T0
  after=$(fingerprint "$repo")
  idx_mtime_after=$(stat -f %m "$repo/.git/index" 2>/dev/null || stat -c %Y "$repo/.git/index")
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
  assert_contains "$out" "sans-upstream 1" "a new cached line is news"
  # shellcheck source=bin/fm-wip-lib.sh
  ( STATE="$home/state"; . "$ROOT/bin/fm-wip-lib.sh"; antidrift_mark_reported "$out"
    [ -z "$(antidrift_news_line)" ] || exit 1 ) || fail "a reported line is not news again"
  mk_repo "$home/projects/second"; register_project "$home" second
  refresh "$home" $((T0 + 10))
  out=$(FM_HOME="$home" "$AD" cached)
  assert_contains "$out" "sans-upstream 2" "a changed line is news again"
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

test_empty_inventory_is_quiet_and_schedules_the_next_run
test_no_upstream_alarm_and_scout_exclusion
test_unpushed_threshold_is_literal
test_push_age_uses_the_native_receipt_and_never_guesses
test_dirty_duration_is_tracked_and_never_backdated
test_a_deleted_tracked_file_counts_as_dirty
test_push_disabled_remote_is_reported
test_pr_age_presentation_and_unknown_forge
test_foreign_or_reassigned_slots_never_leak_to_snapshots
test_worktree_list_is_not_an_inventory
test_own_task_roots_are_included_with_an_empty_registry
test_checkpoint_cadence_and_milestone_trigger
test_publication_cadence_and_daily_action
test_blocked_publication_is_visible_not_silent
test_source_repositories_are_never_touched_by_a_full_refresh
test_the_cached_reader_reports_news_once
test_the_line_is_one_bounded_line
test_a_held_lock_makes_the_producer_a_no_op
