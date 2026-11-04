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
  if [ "${4:-existing}" = fresh ]; then
    fm_git_init_commit "$proj"
  else
    fm_git_worktree "$proj" "$wt" "wt-$name"
  fi
  fm_test_spawn_brief "$home" "$id"
  printf 'max_trees = %s\n' "$max" > "$proj/treehouse.toml"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_WINDOW_DIR:-}" ]; then
  case "${1:-}" in
    list-windows)
      for window in "$FM_FAKE_WINDOW_DIR"/*; do
        [ ! -f "$window" ] || printf '%s\n' "${window##*/}"
      done
      exit 0
      ;;
    new-window)
      while [ "$#" -gt 0 ]; do
        if [ "$1" = -n ]; then name=$2; break; fi
        shift
      done
      [ ! -e "$FM_FAKE_WINDOW_DIR/$name" ] || exit 1
      printf '@100\n' > "$FM_FAKE_WINDOW_DIR/$name"
      printf '@100\n'
      exit 0
      ;;
    kill-window)
      for window in "$FM_FAKE_WINDOW_DIR"/*; do
        [ -f "$window" ] || continue
        if [ "${3:-}" = "$(< "$window")" ]; then
          rm -- "$window"
          exit 0
        fi
      done
      exit 1
      ;;
  esac
fi
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
if [ -n "${FM_FAKE_ALLOCATE_WT:-}" ]; then
  git -C "${FM_FAKE_ALLOCATE_PROJ:?}" worktree add --quiet --detach "$FM_FAKE_ALLOCATE_WT" HEAD
  exit $?
fi
if [ "${FM_FAKE_TH_GET_RC:-0}" -ne 0 ]; then
  printf 'error: all %s worktrees are in use or dirty (max_trees = %s). Run treehouse status.\n' \
    "${FM_FAKE_TH_MAX:-2}" "${FM_FAKE_TH_MAX:-2}" >&2
  exit "${FM_FAKE_TH_GET_RC}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/df" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_DF_LOG:-/dev/null}"
if [ "${FM_FAKE_DF_RC:-0}" -ne 0 ]; then exit "$FM_FAKE_DF_RC"; fi
pct=${FM_FAKE_DISK_PCT:-20}
if [ -n "${FM_FAKE_DISK_NEXT_PCT:-}" ] && [ "$(wc -l < "${FM_FAKE_DF_LOG:?}")" -gt 1 ]; then
  pct=$FM_FAKE_DISK_NEXT_PCT
fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 100 85 15 %s%% /fake volume\n' "$pct"
SH
  chmod +x "$fakebin/df"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
if [ "${1:-} ${2:-}" = 'repo show' ]; then
  printf '{"ok":true,"result":{"repo":{"id":"fake-repo"}}}\n'
  exit 0
fi
if [ "${1:-} ${2:-}" = 'worktree create' ]; then
  git -C "${FM_FAKE_ALLOCATE_PROJ:?}" worktree add --quiet --detach "${FM_FAKE_ALLOCATE_WT:?}" HEAD
fi
exit 1
SH
  chmod +x "$fakebin/orca"
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
    --mode no-mistakes --yolo off --backend "${7:-tmux}"
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


# These cases allocate a real Git worktree only when spawn reaches the allocator.
test_disk_pressure() (
  local name=$1 pct=$2 want=$3 kind=${4:-ship} backend=${5:-tmux} next_pct=${6:-}
  local id="disk-$name" rec out status
  rec=$(make_pool_case "$name" "$id" 5 fresh)
  read_pool_case "$rec"
  export FM_FAKE_DISK_PCT="$pct" FM_FAKE_DISK_NEXT_PCT="$next_pct"
  export FM_FAKE_ALLOCATE_WT="$WT_DIR" FM_FAKE_ALLOCATE_PROJ="$PROJ_DIR"
  export FM_FAKE_DF_LOG="$CASE_DIR/df.log"
  export FM_FAKE_PANE_LOG="$CASE_DIR/pane.log"
  export FM_FAKE_WINDOW_DIR="$CASE_DIR/windows"
  mkdir -p "$FM_FAKE_WINDOW_DIR"
  printf '@7\n' > "$FM_FAKE_WINDOW_DIR/untouched"
  if [ "$kind" = scout ]; then
    out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --backend "$backend")
  else
    out=$(run_pool_spawn "$id" "$WT_DIR" "$HEALTHY_JSON" 0 0 3 "$backend")
  fi
  status=$?
  if [ "$want" = refuse ]; then
    [ "$status" -ne 0 ] || fail "disk at $pct% unexpectedly spawned"$'\n'"$out"
    [ ! -e "$WT_DIR" ] || fail "disk refusal created a worktree"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "disk refusal published a task"
    assert_contains "$out" "${next_pct:-$pct}%" "refusal omitted measured percent"
    assert_contains "$out" "85%" "refusal omitted threshold"
  else
    expect_code 0 "$status" "disk case $name should spawn"$'\n'"$out"
    git -C "$WT_DIR" rev-parse --is-inside-work-tree >/dev/null || fail "no worktree allocated"
    assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "spawn did not publish its worktree"
  fi
  if [ -n "$next_pct" ]; then
    [ "$(wc -l < "$CASE_DIR/df.log")" -eq 2 ] || fail "allocation did not recheck disk usage"
  fi
  if [ "$(uname -s)" = Darwin ] && [ -d /System/Volumes/Data ]; then
    assert_grep '-P /System/Volumes/Data' "$CASE_DIR/df.log" "spawn measured sealed root instead of Data"
  fi
  [ -f "$FM_FAKE_WINDOW_DIR/untouched" ] || fail "disk check closed an existing endpoint"
  if [ "$backend" = tmux ]; then
    if [ "$want" = refuse ]; then
      [ ! -e "$FM_FAKE_WINDOW_DIR/fm-$id" ] || fail "disk refusal left an orphan endpoint"
    else
      [ -e "$FM_FAKE_WINDOW_DIR/fm-$id" ] || fail "successful spawn lost its endpoint"
    fi
    if [ -n "$next_pct" ]; then
      export FM_FAKE_DISK_PCT=84 FM_FAKE_DISK_NEXT_PCT=''
      if [ "$kind" = scout ]; then
        out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout --backend "$backend")
      else
        out=$(run_pool_spawn "$id" "$WT_DIR" "$HEALTHY_JSON" 0 0 3 "$backend")
      fi
      status=$?
      expect_code 0 "$status" "retry after disk refusal should spawn"$'\n'"$out"
      git -C "$WT_DIR" rev-parse --is-inside-work-tree >/dev/null || fail "retry allocated no worktree"
      assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "retry did not publish its worktree"
      [ -e "$FM_FAKE_WINDOW_DIR/fm-$id" ] || fail "retry lost its new endpoint"
      [ -f "$FM_FAKE_WINDOW_DIR/untouched" ] || fail "retry closed an existing endpoint"
    fi
  fi
  pass "disk pressure $name ($kind)"
)

test_disk_pressure threshold 85 refuse || exit 1
test_disk_pressure below 84 pass || exit 1
test_disk_pressure scout-threshold 96 refuse scout || exit 1
test_disk_pressure full 100 refuse || exit 1
test_disk_pressure rising 84 refuse ship tmux 85 || exit 1
test_disk_pressure scout-rising 84 refuse scout tmux 85 || exit 1
test_disk_pressure orca-rising 84 refuse ship orca 85 || exit 1
test_saturated_pool_warns_and_still_spawns
test_full_pool_failure_reports_effective_capacity
test_unreadable_status_failure_stays_unknown
test_isolation_timeout_distinguishes_capacity
