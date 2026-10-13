#!/usr/bin/env bash
# Behavior tests for bin/fm-secondmates.sh, the read-only secondmate registry
# inventory. Everything goes through the executable public interface; the
# registry file is the only input and nothing is resolved or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SECONDMATES="$ROOT/bin/fm-secondmates.sh"
TMP_ROOT=$(fm_test_tmproot fm-secondmates)

write_registry() { # write_registry <home> <line>...
  local home=$1 line
  mkdir -p "$home/data"
  : > "$home/data/secondmates.md"
  shift
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/data/secondmates.md"
  done
}

test_lists_local_and_remote_records() {
  local home="$TMP_ROOT/local-and-remote" out rc=0
  write_registry "$home" \
    '- alpha - Own the alpha domain. (home: /tmp/homes/alpha; scope: alpha work; projects: alpha; added 2026-01-02)' \
    '- beta - Remote beta. (host: beta-host; root: /srv/fm; home: /srv/fm-homes/beta; scope: beta work; projects: beta, gamma; added 2026-02-03)'
  out=$(FM_HOME="$home" "$SECONDMATES" list) || rc=$?
  expect_code 0 "$rc" "list exits 0"
  assert_contains "$out" "schema=fm-secondmates.list.v1" "list declares its schema"
  assert_contains "$out" "count=2" "list reports the record count"
  assert_contains "$out" "id=alpha" "list names the local mate"
  assert_contains "$out" "remote=0" "list marks a local record"
  assert_contains "$out" "home=/tmp/homes/alpha" "list reports the local home"
  assert_contains "$out" "scope=alpha work" "list reports the local scope"
  assert_contains "$out" "id=beta" "list names the remote mate"
  assert_contains "$out" "remote=1" "list marks a remote record"
  assert_contains "$out" "host=beta-host" "list reports the remote host"
  assert_contains "$out" "root=/srv/fm" "list reports the remote root"
  assert_contains "$out" "projects=beta, gamma" "list reports the projects"
  assert_contains "$out" "added=2026-02-03" "list reports the added date"
  pass "fm-secondmates: list enumerates local and remote records"
}

test_empty_registry_reports_zero() {
  local home="$TMP_ROOT/empty" out rc=0
  write_registry "$home"
  out=$(FM_HOME="$home" "$SECONDMATES" list) || rc=$?
  expect_code 0 "$rc" "an empty registry exits 0"
  assert_contains "$out" "count=0" "an empty registry reports zero records"
  pass "fm-secondmates: an empty registry reports zero records"
}

test_help_and_usage_envelope() {
  local home="$TMP_ROOT/envelope" out rc=0
  write_registry "$home"
  out=$(FM_HOME="$home" "$SECONDMATES" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "fm-secondmates.sh list" "--help prints usage"
  assert_contains "$out" "schema=fm-secondmates.list.v1" "--help documents the output"

  rc=0
  out=$(FM_HOME="$home" "$SECONDMATES" frobnicate 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action exits 2"
  assert_contains "$out" "fm-secondmates.sh list" "an unknown action prints usage"

  rc=0
  FM_HOME="$home" "$SECONDMATES" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no action exits 2"

  rc=0
  FM_HOME="$home" "$SECONDMATES" list extra >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "list with extra arguments exits 2"
  pass "fm-secondmates: help exits 0 and usage errors exit 2"
}

test_malformed_record_fails_loudly() {
  local home="$TMP_ROOT/malformed" out rc=0
  write_registry "$home" '- broken with no structured suffix'
  out=$(FM_HOME="$home" "$SECONDMATES" list 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed registry record was accepted"
  assert_contains "$out" "malformed secondmate registry entry" "a malformed record is reported"
  pass "fm-secondmates: a malformed record fails loudly"
}

test_missing_registry_fails_loudly() {
  local home="$TMP_ROOT/missing" out rc=0
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" "$SECONDMATES" list 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing registry was accepted"
  assert_contains "$out" "no safe secondmate registry" "a missing registry is reported"
  pass "fm-secondmates: a missing registry fails loudly"
}

test_lists_local_and_remote_records
test_empty_registry_reports_zero
test_help_and_usage_envelope
test_malformed_record_fails_loudly
test_missing_registry_fails_loudly

echo "all fm-secondmates tests passed"
