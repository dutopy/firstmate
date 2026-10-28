#!/usr/bin/env bash
# End-to-end tests for the Treehouse pool diagnostics at the spawn boundary.
#
# bin/fm-spawn.sh reads the effective pool before allocation and reports the
# same inventory when an allocation fails or an isolation timeout expires. The
# fake tmux actually RUNS the `treehouse get` line it is sent, so the allocator's
# own refusal path is exercised, while a fake treehouse serves both `status
# --json` and the allocator result:
#   (a) saturated pool + successful allocation -> warning, spawn continues
#   (b) full pool + refused allocation         -> effective max/counts + action
#   (c) unreadable status + refused allocation -> available=unknown, never 0
#   (d) isolation timeout with a healthy pool  -> capacity is not the refusal
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-diagnostic)

make_pool_case() { # <name> <id> <max>
  local name=$1 id=$2 max=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin="$case_dir/fake"
  mkdir -p "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf 'max_trees = %s\n' "$max" > "$proj/treehouse.toml"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  capture-pane) cat "${FM_FAKE_PANE_LOG:-/dev/null}" 2>/dev/null; exit 0 ;;
  send-keys)
    text=${*: -2:1}
    case "$text" in
      "treehouse get"*)
        printf '$ %s\n' "$text" >> "${FM_FAKE_PANE_LOG:?}"
        bash -c "$text" >> "$FM_FAKE_PANE_LOG" 2>&1
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = status ]; then
  if [ -n "${FM_FAKE_TH_STATUS_FILE:-}" ]; then
    cat "$FM_FAKE_TH_STATUS_FILE"
  fi
  if [ -n "${FM_FAKE_TH_STATUS_ERR:-}" ]; then
    printf '%s\n' "$FM_FAKE_TH_STATUS_ERR" >&2
  fi
  exit "${FM_FAKE_TH_STATUS_RC:-0}"
fi
if [ "${FM_FAKE_TH_GET_RC:-0}" -ne 0 ]; then
  printf 'error: all %s worktrees are in use or dirty (max_trees = %s). Run treehouse status.\n' \
    "${FM_FAKE_TH_MAX:-2}" "${FM_FAKE_TH_MAX:-2}" >&2
  exit "${FM_FAKE_TH_GET_RC}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_pool_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_pool_spawn <id> <pane-path> <status-json> <status-rc> <get-rc> <wait>
run_pool_spawn() {
  local id=$1 pane=$2 status_json=$3 status_rc=$4 get_rc=$5 wait=$6
  printf '%s\n' "$status_json" > "$CASE_DIR/status.json"
  FM_FAKE_TH_STATUS_FILE="$CASE_DIR/status.json"
  FM_FAKE_TH_STATUS_RC=$status_rc
  FM_FAKE_TH_GET_RC=$get_rc
  FM_FAKE_TH_MAX=2
  FM_FAKE_TH_STATUS_ERR=''
  FM_FAKE_PANE_LOG="$CASE_DIR/pane.log"
  FM_SPAWN_ISOLATION_WAIT_SECS=$wait
  export FM_FAKE_TH_STATUS_FILE FM_FAKE_TH_STATUS_RC FM_FAKE_TH_GET_RC FM_FAKE_TH_MAX
  export FM_FAKE_TH_STATUS_ERR FM_FAKE_PANE_LOG FM_SPAWN_ISOLATION_WAIT_SECS
  : > "$FM_FAKE_PANE_LOG"
  fm_test_run_spawn "$HOME_DIR" "$pane" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off
}

SATURATED_JSON='[{"status":"in-use"},{"status":"leased"},{"status":"dirty"},{"status":"in-use"},{"status":"available"}]'
FULL_JSON='[{"status":"in-use"},{"status":"dirty"}]'
HEALTHY_JSON='[{"status":"available"}]'

test_saturated_pool_warns_and_still_spawns() {
  local rec id out status
  id=pool-warn-s1
  rec=$(make_pool_case pool-warn "$id" 5)
  read_pool_case "$rec"
  out=$(run_pool_spawn "$id" "$WT_DIR" "$SATURATED_JSON" 0 0 3)
  status=$?
  expect_code 0 "$status" "a saturated but allocatable pool should still spawn"$'\n'"$out"
  assert_contains "$out" "warning: treehouse-pool:" "spawn did not warn before dispatch"
  assert_contains "$out" "max=5 occupied=4 available=1 unknown=0 entries=5 saturation=80% state=saturated" \
    "the warning did not carry the effective maximum and buckets"
  assert_contains "$out" "close a finished task" "the warning did not give the safe action"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the warning"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "the spawn did not record its isolated worktree"
  pass "(a) a saturated pool warns before dispatch and still spawns"
}

test_full_pool_failure_reports_effective_capacity() {
  local rec id out status
  id=pool-full-f1
  rec=$(make_pool_case pool-full "$id" 2)
  read_pool_case "$rec"
  out=$(run_pool_spawn "$id" "$PROJ_DIR" "$FULL_JSON" 0 1 3)
  status=$?
  [ "$status" -ne 0 ] || fail "a refused allocation unexpectedly succeeded"$'\n'"$out"
  assert_contains "$out" "error: treehouse get failed (exit 1)" "the allocator refusal was not reported"
  assert_contains "$out" "treehouse-pool:" "the refusal did not report the pool state"
  assert_contains "$out" "max=2 occupied=2 available=0 unknown=0 entries=2 saturation=100% state=full" \
    "the refusal did not carry the effective maximum and buckets"
  assert_contains "$out" "no copy can be handed out" "the refusal did not give the safe action"
  pass "(b) a full-pool refusal reports effective capacity and action"
}

test_unreadable_status_failure_stays_unknown() {
  local rec id out status
  id=pool-unknown-u1
  rec=$(make_pool_case pool-unknown "$id" 2)
  read_pool_case "$rec"
  out=$(run_pool_spawn "$id" "$PROJ_DIR" '' 1 1 3)
  status=$?
  [ "$status" -ne 0 ] || fail "a refused allocation unexpectedly succeeded"$'\n'"$out"
  assert_contains "$out" "error: treehouse get failed (exit 1)" "the allocator refusal was not reported"
  assert_contains "$out" "available=unknown" "an unreadable status did not stay unknown"
  assert_not_contains "$out" "available=0" "an unreadable status looked like zero available copies"
  assert_contains "$out" "state=unknown" "an unreadable status did not report an unknown state"
  assert_contains "$out" "must not be treated as available" "the unknown action was not actionable"
  pass "(c) an unreadable pool stays unknown, never zero-available"
}

test_isolation_timeout_distinguishes_capacity() {
  local rec id out status
  id=pool-timeout-i1
  rec=$(make_pool_case pool-timeout "$id" 2)
  read_pool_case "$rec"
  # The allocator succeeds, but the pane never leaves the project, so the
  # isolation wait expires while the pool itself is healthy.
  out=$(run_pool_spawn "$id" "$PROJ_DIR" "$HEALTHY_JSON" 0 0 2)
  status=$?
  [ "$status" -ne 0 ] || fail "an unsettled pane unexpectedly spawned"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" "the isolation timeout was not reported"
  assert_contains "$out" "state=ok" "the healthy pool state was not reported"
  assert_contains "$out" "not a capacity refusal" "the timeout did not distinguish capacity from isolation"
  pass "(d) an isolation timeout with a healthy pool says capacity is not the refusal"
}

test_saturated_pool_warns_and_still_spawns
test_full_pool_failure_reports_effective_capacity
test_unreadable_status_failure_stays_unknown
test_isolation_timeout_distinguishes_capacity
