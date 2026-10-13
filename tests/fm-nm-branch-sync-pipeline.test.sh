#!/usr/bin/env bash
# Behavior tests for the nested branch_sync.pipeline readers in
# bin/fm-nm-run-lib.sh, run against the real `no-mistakes axi status` TOON shape
# (captured read-only from a live pipeline-pushed branch), including the
# version banner the CLI prints before the document.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

REAL_STATUS=$'\033[33mA new version of no-mistakes is available: v1.79.0 -> v1.84.0\nRun "no-mistakes update" to update\033[0m
run:
  id: "01M4VBPN6QC9G8Y7WG1EX6XWWX"
  status: running
  head: a6817211
branch_sync:
  state: diverged
  changed: false
  local:
    branch: firstmate/t_x
    head: a5ea80f255b8fe8ccd9486fb50746fcb232e40f7
    clean: true
  pipeline:
    run: "01M4VBPN6QC9G8Y7WG1EX6XWWX"
    status: running
    phase: ""
    submitted_head: a5ea80f255b8fe8ccd9486fb50746fcb232e40f7
    current_head: a681721105e40ec96a9c4fa333c0a0b99693dea6
    pushed_head: a681721105e40ec96a9c4fa333c0a0b99693dea6
    pushed_at: 1791920369
    push_generation: 1
  target:
    kind: upstream
    remote: origin
    ref: refs/heads/firstmate/t_x
  remote:
    observed_head: a681721105e40ec96a9c4fa333c0a0b99693dea6
    freshness: pipeline_push
    observed_at: 1791920369
  relation: diverged
'
OTHER_BRANCH_STATUS='run:
  id: "x"
  status: completed
  pushed_at: 111
'

test_reads_pushed_at_and_head_from_the_pipeline_block() {
  assert_equals 1791920369 "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" pushed_at)" "pushed_at is the pipeline receipt"
  assert_equals a681721105e40ec96a9c4fa333c0a0b99693dea6 "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" pushed_head)" "pushed_head is read"
  assert_equals 1 "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" push_generation)" "push_generation is read"
  assert_equals 01M4VBPN6QC9G8Y7WG1EX6XWWX "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" run)" "quoted values are unquoted"
  pass "fm-nm-run-lib: pipeline receipt fields read from the real TOON shape"
}

test_does_not_confuse_sibling_blocks() {
  assert_equals "" "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" observed_at)" "remote.observed_at is not a pipeline field"
  assert_equals "" "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" ref)" "target.ref is not a pipeline field"
  assert_equals "" "$(fm_nm_branch_sync_pipeline_field "$REAL_STATUS" branch)" "local.branch is not a pipeline field"
  pass "fm-nm-run-lib: pipeline reader never matches sibling sub-blocks"
}

test_absent_block_is_unknown_not_zero() {
  assert_equals "" "$(fm_nm_branch_sync_pipeline_field "$OTHER_BRANCH_STATUS" pushed_at)" "a run object without branch_sync yields empty"
  assert_equals "" "$(fm_nm_branch_sync_pipeline_field "" pushed_at)" "empty output yields empty"
  pass "fm-nm-run-lib: absent branch_sync reads as unknown"
}

test_freshness_comes_from_the_remote_block() {
  assert_equals pipeline_push "$(fm_nm_branch_sync_freshness "$REAL_STATUS")" "remote.freshness is read"
  assert_equals "" "$(fm_nm_branch_sync_freshness "$OTHER_BRANCH_STATUS")" "absent block yields empty"
  pass "fm-nm-run-lib: remote.freshness read from branch_sync.remote"
}

test_reads_pushed_at_and_head_from_the_pipeline_block
test_does_not_confuse_sibling_blocks
test_absent_block_is_unknown_not_zero
test_freshness_comes_from_the_remote_block
