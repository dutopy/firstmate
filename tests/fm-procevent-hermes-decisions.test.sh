#!/usr/bin/env bash
# Behavior tests for the Hermes #decisions process-event adapter
# (bin/fm-procevent-hermes-decisions.sh).
#
# Everything is exercised through the adapter's public commands plus the real
# keyed-answer intake, against a fixture profile CLI and an isolated home;
# nothing here asserts implementation-source bytes. The suite proves the
# load-bearing guarantees: a keyed record becomes exactly the keyed line the
# register's one intake reads, a keyless record feeds nothing and never becomes a
# wake, the source keeps its silent no-result contract while a genuine failure is
# loud, the answer is acknowledged in the profile store without suppressing the
# handler's wake, the same answer replayed creates no second record, and arming
# binds before it registers and refuses a profile that cannot capture.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-hermes-decisions-tests)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ADAPTER="$ROOT/bin/fm-procevent-hermes-decisions.sh"

adapter() {  # <argv...>
  FM_ROOT_OVERRIDE="$ROOT" "$ADAPTER" "$@"
}

# A fixture profile CLI: the adapter must read the profile's own contract and
# parse nothing itself, so the test scripts exactly what that CLI would print.
write_profile_cli() {  # <dir> <mode>
  local dir=$1 mode=$2
  mkdir -p "$dir"
  cat > "$dir/hermes" <<SH
#!/usr/bin/env bash
mode="$mode"
printf 'fixture profile CLI invoked: %s\n' "\$*" >> "$dir/cli.log"
case "\$mode" in
  answer)
    printf '%s\n' '{"schema":"decisions-register.answer.v1","message_id":"1552000000000000001","key":"sample-call","answer":"Option A, validée.","label":"#decisions","captured_at":"2026-09-20T12:00:00Z"}'
    exit 0
    ;;
  keyless)
    printf '%s\n' '{"schema":"decisions-register.answer.v1","message_id":"1552000000000000002","key":"","answer":"","label":"#decisions"}'
    exit 0
    ;;
  empty)
    exit 75
    ;;
  broken)
    printf 'hermes: the profile store is unreadable\n' >&2
    exit 1
    ;;
esac
exit 1
SH
  chmod +x "$dir/hermes"
}

write_result() {  # <file> <json>
  printf '%s' "$2" > "$1"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-call - Existing task the captain owns (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

test_classify_silent_and_terminal_are_total() {
  local keyed keyless malformed rc
  keyed="$TMP_ROOT/keyed.json"
  keyless="$TMP_ROOT/keyless.json"
  malformed="$TMP_ROOT/malformed.json"
  write_result "$keyed" '{"schema":"decisions-register.answer.v1","message_id":"m1","key":"sample-call","answer":"oui","label":"#decisions"}'
  write_result "$keyless" '{"schema":"decisions-register.answer.v1","message_id":"m2","key":"","answer":"","label":"#decisions"}'
  write_result "$malformed" 'not json at all'

  [ "$(adapter classify "$keyed")" = answer ] || fail "a keyed record must classify as answer"
  [ "$(adapter classify "$keyless")" = keyless ] || fail "a keyless record must classify as keyless"
  [ "$(adapter classify "$malformed")" = malformed ] || fail "an unreadable record must classify as malformed"
  [ "$(adapter classify "$TMP_ROOT/absent.json")" = malformed ] || fail "a missing record must classify as malformed"

  if adapter silent "$keyed"; then fail "a real answer must never be silenced"; fi
  adapter silent "$keyless" || fail "a keyless record is a routine no-op and must be silenced"
  if adapter silent "$malformed"; then fail "an unreadable record must stay announced"; fi

  if adapter terminal "$keyed"; then fail "the source must stay armed"; fi
  pass "classify, silent and terminal are total over every record shape"
}

test_answers_prints_exactly_the_keyed_line_the_intake_reads() {
  local keyed keyless malformed out
  keyed="$TMP_ROOT/answers-keyed.json"
  keyless="$TMP_ROOT/answers-keyless.json"
  malformed="$TMP_ROOT/answers-malformed.json"
  write_result "$keyed" '{"schema":"decisions-register.answer.v1","message_id":"m1","key":"sample-call","answer":"Option A, validée.","label":"#decisions"}'
  write_result "$keyless" '{"schema":"decisions-register.answer.v1","message_id":"m2","key":"","answer":"","label":"#decisions"}'
  write_result "$malformed" '{}'

  out=$(adapter answers "$keyed")
  [ "$out" = "$(printf 'sample-call\tOption A, validée.\t#decisions')" ] \
    || fail "the keyed line drifted: $out"

  [ -z "$(adapter answers "$keyless")" ] || fail "a keyless record must print no keyed line"
  [ -z "$(adapter answers "$malformed")" ] || fail "an unreadable record must print no keyed line"
  pass "answers prints one keyed line for a keyed record and nothing otherwise"
}

test_source_keeps_the_silent_no_result_contract_and_is_loud_on_failure() {
  local bin out rc
  bin="$TMP_ROOT/bin-answer"
  write_profile_cli "$bin" answer
  out=$(FM_HERMES_DECISIONS_BIN="$bin/hermes" adapter source --profile p --profile-home "$bin")
  rc=$?
  [ "$rc" = 0 ] || fail "a captured answer must exit 0 (got $rc)"
  printf '%s' "$out" | grep -q '"key":"sample-call"' || fail "the captured answer was not printed: $out"

  bin="$TMP_ROOT/bin-empty"
  write_profile_cli "$bin" empty
  out=$(FM_HERMES_DECISIONS_BIN="$bin/hermes" adapter source --profile p --profile-home "$bin")
  rc=$?
  [ "$rc" = 75 ] || fail "no result must exit 75 (got $rc)"
  [ -z "$out" ] || fail "no result must print nothing: $out"

  bin="$TMP_ROOT/bin-broken"
  write_profile_cli "$bin" broken
  out=$(FM_HERMES_DECISIONS_BIN="$bin/hermes" adapter source --profile p --profile-home "$bin")
  rc=$?
  [ "$rc" != 0 ] || fail "a genuine failure must not exit 0"
  printf '%s' "$out" | grep -q 'unreadable' || fail "a genuine failure must print an actionable line: $out"
  pass "the source stays silent on no result and loud on a genuine failure"
}

test_a_captured_answer_closes_its_captain_call_through_the_one_intake() {
  local home keyed show
  home=$(make_home intake)
  run_captain "$home" hold sample-call --reason "the captain owns this choice" >/dev/null \
    || fail "could not hold the fixture task for the captain"
  show=$(tasks_in "$home" show sample-call --full)
  assert_contains "$show" "hold_kind: captain" "the fixture task was not captain-held"

  keyed="$TMP_ROOT/intake.json"
  write_result "$keyed" '{"schema":"decisions-register.answer.v1","message_id":"m1","key":"sample-call","answer":"Option A, validée.","label":"#decisions"}'

  adapter answers "$keyed" \
    | run_captain "$home" answers --source "the captured result hermes-decisions sequence 1" >/dev/null \
    || fail "the captured answer did not feed the keyed-answer intake"

  show=$(tasks_in "$home" show sample-call --full)
  assert_contains "$show" "Option A, validée." "the captain's own words were not recorded"
  assert_contains "$show" "state: done" "the answered captain call was not closed"
  pass "a captured #decisions answer reaches the register's one intake and closes its call"
}

test_the_same_answer_replayed_creates_no_second_record_and_a_different_one_is_refused() {
  local home keyed other before after out rc
  home=$(make_home replay)
  run_captain "$home" hold sample-call --reason "the captain owns this choice" >/dev/null \
    || fail "could not hold the replay fixture"

  keyed="$TMP_ROOT/replay.json"
  write_result "$keyed" '{"schema":"decisions-register.answer.v1","message_id":"m1","key":"sample-call","answer":"Option A, validée.","label":"#decisions"}'
  adapter answers "$keyed" | run_captain "$home" answers --source "the captured result hermes-decisions sequence 1" >/dev/null \
    || fail "the first delivery did not feed the intake"
  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')

  # An exact replay carries the same provenance, so the intake recognises its own
  # record and reports an already-closed no-op.
  out=$(adapter answers "$keyed" | run_captain "$home" answers --source "the captured result hermes-decisions sequence 1" 2>&1)
  rc=$?
  assert_contains "$out" "closed:" "an exact replay must report the already-closed record: $out"
  [ "$rc" = 0 ] || fail "an exact replay must be a no-op, not a failure: $out"

  # The same answer arriving another way (a second capture, a card, chat) carries
  # different provenance. It is refused loudly rather than appended.
  out=$(adapter answers "$keyed" | run_captain "$home" answers --source "the captured result hermes-decisions sequence 2" 2>&1)
  assert_contains "$out" "skipped:" "a second delivery of an answered call must be refused: $out"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a replay wrote a second record"

  other="$TMP_ROOT/replay-other.json"
  write_result "$other" '{"schema":"decisions-register.answer.v1","message_id":"m2","key":"sample-call","answer":"Finalement, option B.","label":"#decisions"}'
  out=$(adapter answers "$other" | run_captain "$home" answers --source "the captured result hermes-decisions sequence 3" 2>&1)
  assert_contains "$out" "skipped:" "a different answer for an answered call must be refused"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a refused answer still wrote a record"
  [ "$(grep -c 'Resolution recorded by fm-captain-hold.' "$home/data/backlog.md")" = 1 ] \
    || fail "more than one resolution record exists for the answered call"
  pass "an exact replay is a no-op, a second delivery is refused, and no second record is created"
}

test_autohandle_acknowledges_the_profile_store_without_suppressing_the_wake() {
  local home bin seq
  home=$(make_home autohandle)
  mkdir -p "$home/state/procevent"
  bin="$TMP_ROOT/bin-autohandle"
  write_profile_cli "$bin" answer
  cat > "$home/state/procevent/hermes-decisions.source" <<EOF
adapter=hermes-decisions
argc=6
argv:
$bin/hermes
source
--profile
fixture
--profile-home
$bin
EOF
  seq="$TMP_ROOT/autohandle.json"
  write_result "$seq" '{"schema":"decisions-register.answer.v1","message_id":"m1","key":"sample-call","answer":"oui","label":"#decisions"}'

  FM_HERMES_DECISIONS_BIN="$bin/hermes" FM_STATE_OVERRIDE="$home/state" \
    adapter autohandle hermes-decisions 7 "$seq" >/dev/null \
    || fail "autohandle did not acknowledge the captured answer"
  grep -q 'decisions-register consume m1' "$bin/cli.log" \
    || fail "autohandle did not ask the profile store to consume the answer"

  if [ -e "$home/state/procevent-inbox/hermes-decisions.7.handled" ]; then
    fail "autohandle acknowledged the result to the runner, which would suppress the handler's wake"
  fi
  if FM_HERMES_DECISIONS_BIN="$bin/hermes" FM_STATE_OVERRIDE="$home/state" \
      adapter autohandle other-source 7 "$seq" >/dev/null 2>&1; then
    fail "autohandle accepted a foreign source id"
  fi
  pass "autohandle consumes the answer in the profile store and leaves the wake unacknowledged"
}

test_arm_binds_before_it_registers_and_refuses_a_profile_that_cannot_capture() {
  local home bin out
  home=$(make_home arm)
  bin="$TMP_ROOT/bin-arm"
  write_profile_cli "$bin" empty

  out=$(FM_HERMES_DECISIONS_BIN="$bin/hermes" adapter arm --dry-run --profile fixture --profile-home "$bin")
  assert_contains "$out" "fm-captain-hold.sh bind hermes-decisions" "the dry run must name the binding"
  assert_contains "$out" "register hermes-decisions hermes-decisions" "the dry run must name the registration"
  case "$out" in
    *"bind hermes-decisions"*"register hermes-decisions"*) ;;
    *) fail "the dry run must show the binding before the registration" ;;
  esac

  if FM_HERMES_DECISIONS_BIN="$bin/hermes" adapter arm --profile fixture --profile-home "$TMP_ROOT/absent" >/dev/null 2>&1; then
    fail "arm accepted a profile home that does not exist"
  fi
  if FM_HERMES_DECISIONS_BIN="$bin/missing-hermes" adapter arm --profile fixture --profile-home "$bin" >/dev/null 2>&1; then
    fail "arm registered a source whose profile CLI cannot capture"
  fi
  [ ! -e "$home/state/procevent/hermes-decisions.source" ] || fail "a refused arm registered the source"
  pass "arm binds before registering and refuses a profile that cannot capture"
}

test_classify_silent_and_terminal_are_total
test_answers_prints_exactly_the_keyed_line_the_intake_reads
test_source_keeps_the_silent_no_result_contract_and_is_loud_on_failure
test_a_captured_answer_closes_its_captain_call_through_the_one_intake
test_the_same_answer_replayed_creates_no_second_record_and_a_different_one_is_refused
test_autohandle_acknowledges_the_profile_store_without_suppressing_the_wake
test_arm_binds_before_it_registers_and_refuses_a_profile_that_cannot_capture

echo
echo "ALL HERMES DECISIONS ADAPTER TESTS PASSED"
