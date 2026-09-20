#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-console-prepare.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-classify-fake-typesafe.py, a fake typesafe.ai System One
# server bound to 127.0.0.1 on an ephemeral port, serving a multi-question
# `answers` object from an --answers-file. Cases cover a confident prepared
# verdict, code-built candidate lists (including the axis that is not asked when
# its candidate list is empty), a `none` selection, a low-confidence intent and a
# low-confidence project, an API error, a malformed response, an out-of-
# vocabulary intent, a non-finite confidence, invalid input, the wall-clock
# fallback, an unusable bound, a missing key, the .env key fallback, file input,
# and the usage errors. Every request goes to that loopback server, so no case
# reaches the real network, and each classified case asserts exactly one call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-console-prepare.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-classify-fake-typesafe.py"
SHARED_CORE=${FM_JV_PREPARE_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-console-prepare.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_PREPARE_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-console-prepare)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
ANSWERS="$TMP_ROOT/answers.json"
mkdir -p "$HOME_DIR/data" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-9f21-never-on-argv'
PAYLOAD='{"message":"where does the folium email lot stand","label":"Internal","projects":[{"id":"firstmate","summary":"the fleet tooling"},{"id":"folium","summary":"the Folium client product"}],"tasks":[{"id":"task-a","title":"A test task"},{"id":"task-b","title":"Another task"}]}'

BASE=''
FAKE_PID=''
TOOL_OUT=''
TOOL_RC=''
TOOL_ERR=''

reap_fake() {
  if [ -n "$FAKE_PID" ]; then
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=''
  fi
}

# The exit trap keeps the real status, so a failing assertion still fails the
# suite instead of being masked by cleanup.
cleanup_all() {
  local code=$?
  reap_fake
  fm_test_cleanup
  exit "$code"
}
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT

start_fake() {
  local port_file="$TMP_ROOT/port" i=0
  rm -f "$port_file"
  # The fake server's output goes to a file: a leaked child must never hold the
  # suite's stdout open, and a pipe-reading runner would then wait forever.
  python3 "$FAKE_SERVER" --port-file "$port_file" --log-dir "$LOG" "$@" \
    > "$LOG/fake-server.out" 2>&1 &
  FAKE_PID=$!
  while [ ! -s "$port_file" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$port_file" ] || fail "fake typesafe server did not start (pid $FAKE_PID)"
  BASE="http://127.0.0.1:$(cat "$port_file")"
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

# answers <intent-choice> <intent-confidence> <project-choice> <project-confidence>
#         <entity-choice> <entity-confidence>: writes the multi-question answers
# object the fake server serves; an empty choice omits that axis.
answers() {
  local intent=$1 confidence=$2 project=${3:-} pconf=${4:-} entity=${5:-} econf=${6:-}
  local quote='import json,sys;print(json.dumps(sys.argv[1]))'
  {
    printf '{"intent":{"type":"choice","choice":%s,"confidence":%s,"probabilities":{%s:%s}}' \
      "$(python3 -c "$quote" "$intent")" "$confidence" \
      "$(python3 -c "$quote" "$intent")" "$confidence"
    if [ -n "$project" ]; then
      printf ',"project":{"type":"choice","choice":%s,"confidence":%s,"probabilities":{%s:%s}}' \
        "$(python3 -c "$quote" "$project")" "$pconf" \
        "$(python3 -c "$quote" "$project")" "$pconf"
    fi
    if [ -n "$entity" ]; then
      printf ',"entity":{"type":"choice","choice":%s,"confidence":%s,"probabilities":{%s:%s}}' \
        "$(python3 -c "$quote" "$entity")" "$econf" \
        "$(python3 -c "$quote" "$entity")" "$econf"
    fi
    printf '}'
  } >"$ANSWERS"
}

# run_prepare <core> <key> <timeout> <payload> [tool args...]
run_prepare() {
  local core=$1 key=$2 timeout=$3 payload=$4 _out _rc
  shift 4
  if [ -n "$core" ]; then
    _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$HOME_DIR" \
      FM_JV_PREPARE_CORE="$core" FM_JV_PREPARE_TIMEOUT="$timeout" \
      TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  else
    _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$HOME_DIR" \
      FM_JV_PREPARE_TIMEOUT="$timeout" \
      TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  fi
  _rc=$?
  TOOL_OUT=$_out
  TOOL_RC=$_rc
  TOOL_ERR=$(cat "$STDERR_FILE")
}

json_get() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.argv[1]).get(sys.argv[2])))' "$1" "$2"
}

json_keys() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sorted(json.loads(sys.argv[1]).keys())))' "$1"
}

assert_typed_output() {
  assert_equals '["entity", "flag", "intent", "intent_confidence", "project", "reason"]' \
    "$(json_keys "$TOOL_OUT")" "$1: typed output keys"
  expect_code 0 "$TOOL_RC" "$1: a classified outcome exits 0"
}

assert_one_call() {
  local count
  count=$(wc -l <"$LOG/requests" 2>/dev/null || printf '0')
  assert_equals 1 "$count" "$1: exactly one System One call"
}

assert_strict_json() {
  python3 - "$TOOL_OUT" <<'PY' || fail "$1: output is not strict JSON"
import json
import sys


def reject(constant):
    raise ValueError("non-finite JSON constant: " + constant)


json.loads(sys.argv[1], parse_constant=reject)
PY
}

# --- a confident verdict prepares every axis --------------------------------
reset_log
answers state_question 0.96 none 0.96 task-a 0.96
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "prepared verdict"
assert_equals '"state_question"' "$(json_get "$TOOL_OUT" intent)" "the intent is reported"
assert_equals 'null' "$(json_get "$TOOL_OUT" project)" "a none project selection is reported as null"
assert_equals '"task-a"' "$(json_get "$TOOL_OUT" entity)" "the selected task is reported"
assert_equals 'null' "$(json_get "$TOOL_OUT" flag)" "a settled verdict carries no flag"
assert_equals '"ok"' "$(json_get "$TOOL_OUT" reason)" "a settled verdict carries a plain reason"
assert_one_call "prepared verdict"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_contains "$(cat "$LOG/body")" '"state_question"' "the intent options reach the model"
assert_contains "$(cat "$LOG/body")" '"new_work"' "every intent option reaches the model"
assert_contains "$(cat "$LOG/body")" 'the Folium client product' "a project candidate reaches the model"
assert_contains "$(cat "$LOG/body")" 'A test task' "a task candidate reaches the model"
assert_contains "$(cat "$LOG/body")" 'where does the folium email lot stand' "the captain's message is the state"
pass "a confident verdict: intent, project, entity in one loopback request"

# --- an empty candidate list is not asked for --------------------------------
reset_log
answers new_work 0.95
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 '{"message":"please add a retry"}' -
reap_fake
assert_typed_output "no candidates"
assert_equals '"new_work"' "$(json_get "$TOOL_OUT" intent)" "the intent is still answered"
assert_equals 'null' "$(json_get "$TOOL_OUT" project)" "no project candidate means no selection"
assert_equals 'null' "$(json_get "$TOOL_OUT" entity)" "no task candidate means no selection"
python3 - "$LOG/body" <<'PY' || fail "an absent candidate list must not be asked about"
import json, sys
body = json.load(open(sys.argv[1]))
questions = set(body["questions"])
assert "project" not in questions, f"no project question may be asked: {sorted(questions)}"
assert "entity" not in questions, f"no entity question may be asked: {sorted(questions)}"
assert questions == {"intent"}, f"only the intent is asked: {sorted(questions)}"
PY
pass "an empty candidate list is never asked, and both axes answer null"

# --- a low-confidence intent degrades the whole verdict ----------------------
reset_log
answers state_question 0.4 none 0.96 task-a 0.96
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "low-confidence intent"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "an uncertain intent is reported as unclear"
assert_equals '"low_confidence"' "$(json_get "$TOOL_OUT" flag)" "an uncertain intent sets the flag"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below the 0.9 floor' "the reason names the confidence gap"
pass "a low-confidence intent: unclear plus the low-confidence flag"

# --- a low-confidence axis selection degrades the whole verdict --------------
reset_log
answers state_question 0.96 firstmate 0.5 task-a 0.96
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "low-confidence project"
assert_equals 'null' "$(json_get "$TOOL_OUT" project)" "an uncertain project selection is dropped"
assert_equals '"low_confidence"' "$(json_get "$TOOL_OUT" flag)" "an uncertain selection sets the flag"
assert_equals '"task-a"' "$(json_get "$TOOL_OUT" entity)" "a settled entity is still reported"
pass "a low-confidence selection: dropped, flagged, and never guessed"

# --- an API error is a fail-safe, never a guess ------------------------------
reset_log
start_fake --answers-file "$ANSWERS" --status 400
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "api error"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "an API error reports an unclear intent"
assert_equals '"api_error"' "$(json_get "$TOOL_OUT" flag)" "an API error sets the api_error flag"
assert_equals '0.0' "$(json_get "$TOOL_OUT" intent_confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'api_error' "the reason names the API failure"
pass "API error: unclear, flagged, exit 0"

# --- a malformed response is a fail-safe -------------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "malformed response"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "a malformed response reports an unclear intent"
assert_equals '"api_error"' "$(json_get "$TOOL_OUT" flag)" "a malformed response sets the flag"
pass "a malformed success response: unclear, flagged, exit 0"

# --- an out-of-vocabulary intent is a fail-safe ------------------------------
reset_log
answers something_else 0.99 none 0.99 task-a 0.99
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "unexpected intent"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "an unexpected intent is refused, never passed through"
assert_equals '"api_error"' "$(json_get "$TOOL_OUT" flag)" "an unexpected intent sets the flag"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'unknown intent' "the reason names the unexpected answer"
pass "an out-of-vocabulary intent: unclear, flagged, exit 0"

# --- a non-finite confidence is refused by the wrapper -----------------------
reset_log
printf '{"intent":{"type":"choice","choice":"chat","confidence":NaN,"probabilities":{"chat":NaN}}}' >"$ANSWERS"
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "non-finite confidence"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "a non-finite confidence never reaches stdout as a verdict"
assert_equals '0.0' "$(json_get "$TOOL_OUT" intent_confidence)" "a non-finite confidence is reported as numeric zero"
assert_strict_json "non-finite confidence"
pass "a non-finite confidence: fail-safe, strict JSON"

# --- invalid input falls back without any network call -----------------------
reset_log
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 '{"label":"Internal"}' -
reap_fake
assert_typed_output "missing message"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "input without a message is a fail-safe"
assert_absent "$LOG/requests" "input without a message never reaches the network"
pass "input without a message: fail-safe, exit 0, no network"

# --- the wall-clock bound fires inside a finite window -----------------------
reset_log
answers state_question 0.97 none 0.97 task-a 0.97
start_fake --answers-file "$ANSWERS" --delay 30
started=$(date +%s)
run_prepare '' "$API_KEY" 1 "$PAYLOAD" -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "the wall-clock bound reports an unclear intent"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: fail-safe inside the bound, exit 0"

# --- an unusable bound never leaves the call unbounded -----------------------
for bad_timeout in nan inf 1e30; do
  reset_log
  answers state_question 0.97 none 0.97 task-a 0.97
  start_fake --answers-file "$ANSWERS" --delay 30
  started=$(date +%s)
  run_prepare '' "$API_KEY" "$bad_timeout" "$PAYLOAD" -
  elapsed=$(( $(date +%s) - started ))
  reap_fake
  assert_typed_output "timeout $bad_timeout"
  assert_equals '"unclear"' "$(json_get "$TOOL_OUT" intent)" "timeout $bad_timeout reports an unclear intent"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'fail_safe' "the $bad_timeout reason names the fail-safe"
  assert_absent "$LOG/requests" "timeout $bad_timeout never reaches the network"
  [ "$elapsed" -lt 10 ] || fail "timeout $bad_timeout did not return inside a finite bound (elapsed ${elapsed}s)"
  pass "timeout $bad_timeout: fail-safe, finite bound, no request"
done

# --- a missing key falls back without any network call -----------------------
reset_log
start_fake --answers-file "$ANSWERS"
run_prepare '' '' 20 "$PAYLOAD" -
reap_fake
assert_typed_output "absent key"
assert_equals '"api_error"' "$(json_get "$TOOL_OUT" flag)" "a missing key sets the flag"
assert_absent "$LOG/requests" "a missing key makes no network call"
pass "absent key: fail-safe, no network call"

# --- the .env key is used, and the environment wins over it ------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
answers state_question 0.97 none 0.97 task-a 0.97
start_fake --answers-file "$ANSWERS"
run_prepare '' '' 20 "$PAYLOAD" -
reap_fake
assert_equals '"state_question"' "$(json_get "$TOOL_OUT" intent)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- file input behaves exactly like stdin -----------------------------------
printf '%s\n' "$PAYLOAD" >"$TMP_ROOT/request.json"
reset_log
answers decision_answer 0.95 folium 0.95 task-b 0.95
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 '' "$TMP_ROOT/request.json"
reap_fake
assert_typed_output "file input"
assert_equals '"folium"' "$(json_get "$TOOL_OUT" project)" "file input selects like stdin"
assert_equals '"task-b"' "$(json_get "$TOOL_OUT" entity)" "file input selects a task like stdin"
assert_present "$LOG/requests" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- usage errors refuse loudly with no network call -------------------------
reset_log
start_fake --answers-file "$ANSWERS"
run_prepare '' "$API_KEY" 20 "$PAYLOAD" --bogus
reap_fake
expect_code 2 "$TOOL_RC" "an unknown flag is a usage error"
assert_equals '' "$TOOL_OUT" "a usage error prints nothing on stdout"
assert_contains "$TOOL_ERR" 'unknown flag --bogus' "the usage error names the flag"
assert_absent "$LOG/requests" "a usage error never reaches the network"
pass "usage errors exit 2 with a named diagnostic and no network call"

# --- an unusable confidence floor is a usage error ---------------------------
for bad_threshold in 0 1.2 nan; do
  reap_fake
  reset_log
  start_fake --answers-file "$ANSWERS"
  _out=$(printf '%s' "$PAYLOAD" | TYPESAFE_API_KEY="$API_KEY" FM_HOME="$HOME_DIR" \
    FM_JV_PREPARE_THRESHOLD="$bad_threshold" TYPESAFE_BASE_URL="$BASE" "$TOOL" - 2>"$STDERR_FILE")
  _rc=$?
  expect_code 2 "$_rc" "threshold $bad_threshold is a usage error"
  assert_equals '' "$_out" "threshold $bad_threshold prints nothing on stdout"
  assert_absent "$LOG/requests" "threshold $bad_threshold never reaches the network"
  pass "threshold $bad_threshold: usage error, no network call"
done
reap_fake

TOOL_OUT=$("$TOOL" --help)
TOOL_RC=$?
expect_code 0 "$TOOL_RC" "--help exits 0"
assert_contains "$TOOL_OUT" 'Usage:' "--help prints the usage"
pass "--help exits 0"

printf '# all fm-jev-console-prepare tests passed\n'
