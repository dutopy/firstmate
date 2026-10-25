#!/usr/bin/env bash
# Behavior tests for bin/fm-pool-status.sh and its owner bin/fm-pool-lib.sh.
#
# The pool inventory is driven by a fake `treehouse` that prints a JSON fixture,
# so every bucket and failure shape is deterministic:
#   (a) available + in-use + dirty + leased -> occupied/available split
#   (b) >=80% occupied                       -> saturated
#   (c) no available and materialized=max    -> full
#   (d) unreadable status                    -> every count unknown, never 0
#   (e) malformed JSON                       -> unknown, not available
#   (f) unrecognized status                  -> unknown count, never available
#   (g) absent config                        -> Treehouse default 16
#   (h) invalid max_trees                    -> max unknown
#   (i) linked worktree                      -> primary checkout config is read
#
# The last case is the contract that matters in practice: Treehouse ignores a
# worktree-local treehouse.toml, so the reader must read the primary root too.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POOL="$ROOT/bin/fm-pool-status.sh"
TMP_ROOT=$(fm_test_tmproot fm-pool-status)
FAKEBIN="$TMP_ROOT/fakebin"
STATUS_FILE="$TMP_ROOT/status.json"
ERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = status ] || exit 9
if [ -n "${FM_FAKE_TH_STATUS_FILE:-}" ]; then
  cat "$FM_FAKE_TH_STATUS_FILE"
fi
if [ -n "${FM_FAKE_TH_STATUS_ERR:-}" ]; then
  printf '%s\n' "$FM_FAKE_TH_STATUS_ERR" >&2
fi
exit "${FM_FAKE_TH_STATUS_RC:-0}"
SH
chmod +x "$FAKEBIN/treehouse"

run_pool() { # <project> <json> <status-rc> [status-stderr]
  printf '%s\n' "$2" > "$STATUS_FILE"
  OUT=$(FM_FAKE_TH_STATUS_FILE="$STATUS_FILE" \
    FM_FAKE_TH_STATUS_RC="$3" \
    FM_FAKE_TH_STATUS_ERR="${4:-}" \
    PATH="$FAKEBIN:$PATH" \
    "$POOL" --project "$1" 2>"$ERR_FILE")
  RC=$?
  ERR=$(cat "$ERR_FILE")
}

new_repo() { # <name> [max]
  local dir="$TMP_ROOT/$1"
  fm_git_init_commit "$dir"
  if [ "${2-}" != "" ]; then
    printf 'max_trees = %s\n' "$2" > "$dir/treehouse.toml"
  fi
  printf '%s\n' "$dir"
}

test_buckets_are_split() {
  local repo out
  repo=$(new_repo buckets 4)
  run_pool "$repo" '[{"status":"available"},{"status":"in-use"},{"status":"dirty"},{"status":"leased"}]' 0
  expect_code 0 "$RC" "complete inventory"
  assert_contains "$OUT" "max=4 occupied=3 available=1 unknown=0 entries=4 saturation=75% state=ok" \
    "available, occupied, and entries were not split correctly"
  assert_contains "$OUT" "observed_at=" "the line omitted its UTC observation time"
  assert_contains "$OUT" "read_s=" "the line omitted its monotonic read duration"
  [ -z "$ERR" ] || fail "a healthy pool wrote stderr: $ERR"
  pass "(a) available/occupied/entries split"
}

test_80_percent_is_saturated() {
  local repo
  repo=$(new_repo saturated 5)
  run_pool "$repo" '[{"status":"in-use"},{"status":"leased"},{"status":"dirty"},{"status":"in-use"},{"status":"available"}]' 0
  expect_code 0 "$RC" "saturated is still a complete inventory"
  assert_contains "$OUT" "max=5 occupied=4 available=1 unknown=0 entries=5 saturation=80% state=saturated" \
    "80% occupancy was not reported as saturated"
  assert_contains "$ERR" "close a finished task" "saturated guidance did not name the safe action"
  assert_contains "$ERR" "never changes max_trees" "saturated guidance implied raising the ceiling"
  pass "(b) 80% occupancy is saturated with safe guidance"
}

test_full_means_no_available_and_no_room() {
  local repo
  repo=$(new_repo full 2)
  run_pool "$repo" '[{"status":"in-use"},{"status":"dirty"}]' 0
  expect_code 0 "$RC" "full is still a complete inventory"
  assert_contains "$OUT" "max=2 occupied=2 available=0 unknown=0 entries=2 saturation=100% state=full" \
    "a pool with no available slot and no room to grow was not reported full"
  assert_contains "$ERR" "no copy can be handed out" "full guidance did not name the outcome"
  pass "(c) full is reported distinctly"
}

test_unreadable_status_is_unknown_not_available() {
  local repo
  repo=$(new_repo unreadable 2)
  run_pool "$repo" '' 3 'provider socket refused'
  expect_code 1 "$RC" "unknown inventory exits 1"
  assert_contains "$OUT" "max=2 occupied=unknown available=unknown unknown=unknown entries=unknown saturation=unknown state=unknown" \
    "an unreadable status invented counts"
  assert_not_contains "$OUT" "available=0" "an unreadable status looked like zero available copies"
  assert_contains "$ERR" "must not be treated as available" "unknown guidance did not warn against treating it as available"
  assert_contains "$ERR" "provider socket refused" "the provider's own error was dropped"
  pass "(d) unreadable status is unknown, never available"
}

test_malformed_json_is_unknown() {
  local repo
  repo=$(new_repo malformed 2)
  run_pool "$repo" 'not-json' 0
  expect_code 1 "$RC" "malformed inventory exits 1"
  assert_contains "$OUT" "available=unknown" "malformed JSON looked like a known availability"
  assert_contains "$ERR" "not a valid slot inventory" "the malformed-inventory reason was not actionable"
  pass "(e) malformed JSON is unknown"
}

test_unrecognized_status_is_unknown() {
  local repo
  repo=$(new_repo unrecognized 2)
  run_pool "$repo" '[{"status":"mystery"},{"status":"available"}]' 0
  expect_code 1 "$RC" "an unrecognized entry makes the inventory incomplete"
  assert_contains "$OUT" "max=2 occupied=0 available=1 unknown=1 entries=2" \
    "an unrecognized status was folded into a known bucket"
  assert_contains "$ERR" "unrecognized status" "the unrecognized entry was not named"
  pass "(f) unrecognized status is counted unknown, never available"
}

test_absent_config_uses_treehouse_default() {
  local repo
  repo=$(new_repo no-config)
  run_pool "$repo" '[]' 0
  expect_code 0 "$RC" "an empty pool is a complete inventory"
  assert_contains "$OUT" "max=16 occupied=0 available=0 unknown=0 entries=0 saturation=0% state=ok" \
    "the documented Treehouse default maximum was not used"
  pass "(g) absent config uses Treehouse's default 16"
}

test_invalid_max_is_unknown() {
  local repo
  repo=$(new_repo invalid-max)
  printf 'max_trees = banana\n' > "$repo/treehouse.toml"
  run_pool "$repo" '[{"status":"available"}]' 0
  expect_code 1 "$RC" "an invalid maximum makes saturation unknowable"
  assert_contains "$OUT" "max=unknown occupied=0 available=1 unknown=0 entries=1 saturation=unknown state=unknown" \
    "an invalid maximum was replaced by a guess"
  assert_contains "$ERR" "max_trees is unreadable or invalid" "the invalid config was not named"
  pass "(h) invalid max_trees is unknown"
}

test_linked_worktree_reads_primary_config() {
  local repo wt
  repo=$(new_repo linked 3)
  wt="$TMP_ROOT/linked/wt"
  git -C "$repo" worktree add --quiet --detach "$wt"
  [ ! -e "$wt/treehouse.toml" ] || fail "fixture unexpectedly placed config in the linked worktree"
  run_pool "$wt" '[{"status":"available"}]' 0
  expect_code 0 "$RC" "linked worktree inventory"
  assert_contains "$OUT" "max=3" "a linked worktree did not read the primary checkout's config"
  pass "(i) linked worktree reads the primary checkout config"
}

test_table_scoped_max_is_not_top_level() {
  local repo
  repo=$(new_repo table-max)
  printf '[pool]\nmax_trees = 3\n' > "$repo/treehouse.toml"
  run_pool "$repo" '[]' 0
  expect_code 0 "$RC" "an empty pool is a complete inventory"
  assert_contains "$OUT" "max=16" "a table-scoped max_trees was treated as Treehouse's top-level key"
  pass "(j) a table-scoped max_trees is not the effective top-level maximum"
}

test_buckets_are_split
test_80_percent_is_saturated
test_full_means_no_available_and_no_room
test_unreadable_status_is_unknown_not_available
test_malformed_json_is_unknown
test_unrecognized_status_is_unknown
test_absent_config_uses_treehouse_default
test_invalid_max_is_unknown
test_linked_worktree_reads_primary_config
test_table_scoped_max_is_not_top_level
