#!/usr/bin/env bash
# Behavior tests for the explicit presentation receipt: fm-pr-check.sh
# <id> <url> --presented. Registration never implies presentation, so the
# receipt is written only on request, only for the exact registered URL, and a
# failure records nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-presented)
URL=https://github.com/acme/widgets/pull/7

make_state() {  # <name> <meta lines...>
  local state="$TMP_ROOT/$1/state"
  shift
  mkdir -p "$state"
  chmod 700 "$state"
  printf '%s\n' "$@" > "$state/t1.meta"
  chmod 600 "$state/t1.meta"
  printf '%s\n' "$state"
}

test_receipt_is_written_only_for_the_registered_url() {
  local state rc=0
  state=$(make_state ok "worktree=/x" "pr=$URL" "pr_head=0123456789abcdef0123456789abcdef01234567")
  assert_not_contains "$(cat "$state/t1.meta")" "pr_presented" "registration alone carries no receipt"
  FM_STATE_OVERRIDE="$state" FM_PR_PRESENTED_NOW=1700000000 "$PR_CHECK" t1 "$URL" --presented >/dev/null || fail "receipt must succeed"
  assert_contains "$(cat "$state/t1.meta")" "pr_presented=1700000000:$URL" "the receipt names its time and URL"
  assert_contains "$(cat "$state/t1.meta")" "pr_head=0123456789abcdef0123456789abcdef01234567" "other metadata is preserved"
  fm_pr_metadata_identity_parse "$state/t1.meta" || fail "a receipt must leave the registration parseable"
  FM_STATE_OVERRIDE="$state" FM_PR_PRESENTED_NOW=1700000500 "$PR_CHECK" t1 "$URL" --presented >/dev/null
  assert_equals 1 "$(grep -c '^pr_presented=' "$state/t1.meta")" "a repeated receipt replaces, never duplicates"
  FM_STATE_OVERRIDE="$state" "$PR_CHECK" t1 https://github.com/acme/widgets/pull/8 --presented >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a PR the task did not register gets no receipt"
  assert_not_contains "$(cat "$state/t1.meta")" "pull/8" "nothing was recorded for the other PR"
  pass "fm-pr-check --presented: explicit, exact-URL, idempotent receipt"
}

test_unregistered_task_gets_no_receipt() {
  local state rc=0
  state=$(make_state none "worktree=/x")
  FM_STATE_OVERRIDE="$state" "$PR_CHECK" t1 "$URL" --presented >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a task with no registered PR gets no receipt"
  assert_not_contains "$(cat "$state/t1.meta")" "pr_presented" "no receipt was written"
  rc=0
  FM_STATE_OVERRIDE="$TMP_ROOT/none/state" "$PR_CHECK" nope "$URL" --presented >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an unknown task gets no receipt"
  pass "fm-pr-check --presented: no registered PR means no receipt"
}

test_receipt_is_written_only_for_the_registered_url
test_unregistered_task_gets_no_receipt
