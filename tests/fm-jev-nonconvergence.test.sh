#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-nonconvergence.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-nonconvergence-fake-typesafe.py, a fake typesafe.ai System
# One server bound to 127.0.0.1 on an ephemeral port. Cases cover the two
# verdicts, the deterministic feature extraction, the one-atomic-question
# request shape, a low-confidence answer that never escalates, the confidence
# boundary, an API error, a malformed response, an unexpected verdict, the
# wall-clock fallback, a missing key, the .env key fallback (and the
# environment winning over it), `--task` resolution, `--lines` windowing, both
# no-model-call shortcuts (insufficient history and a terminal declaration),
# and the usage errors. Every request goes to that loopback server, so no case
# reaches the real network, and each judged case asserts exactly one call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-nonconvergence.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-nonconvergence-fake-typesafe.py"
SHARED_CORE=${FM_JV_NONCONVERGENCE_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-nonconvergence.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_NONCONVERGENCE_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-nonconvergence)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
STALL_FILE="$TMP_ROOT/stall.status"
PROGRESS_FILE="$TMP_ROOT/progress.status"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-4c17-never-on-argv'

# A worker that has failed the same review finding three times and reapplied
# the same fix twice: repeated identical findings plus a failed/working loop.
STALL_HISTORY='working: validate the change and run the suite
failed: same review finding: the queue worker drops the retry budget
working: reapply the fix for the dropped retry budget
failed: same review finding: the queue worker drops the retry budget
working: reapply the fix for the dropped retry budget
failed: same review finding: the queue worker drops the retry budget'
printf '%s\n' "$STALL_HISTORY" >"$STALL_FILE"

# A worker that keeps moving: new states, a resolved decision, no repeated note.
PROGRESS_HISTORY='working: read the brief and the failing test
working: fix the null check in the queue worker
needs-decision: which retry budget should the queue use
resolved: retry budget confirmed at three attempts
working: implement the retry budget and re-run the suite'
printf '%s\n' "$PROGRESS_HISTORY" >"$PROGRESS_FILE"

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

cleanup_all() {
  local code=${1:-0}
  reap_fake
  fm_test_cleanup
  exit "$code"
}
trap 'cleanup_all 0' EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM
trap 'cleanup_all 129' HUP
trap 'cleanup_all 131' QUIT

start_fake() {
  local port_file="$TMP_ROOT/port" i=0
  rm -f "$port_file"
  python3 "$FAKE_SERVER" --port-file "$port_file" --log-dir "$LOG" "$@" &
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

# run_detector <key> <home> <timeout> <stdin-data> [tool args...]: <stdin-data>
# is piped to the tool and stays unused by the cases that read a file or a task.
run_detector() {
  local key=$1 home=$2 timeout=$3 data=$4 _out _rc
  shift 4
  _out=$(printf '%s' "$data" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_NONCONVERGENCE_TIMEOUT="$timeout" TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
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

features_of() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.argv[1])["features"]))' "$1"
}

assert_typed_output() {
  assert_equals '["confidence", "features", "flag", "reason", "verdict"]' "$(json_keys "$TOOL_OUT")" "$1: typed output keys"
  expect_code 0 "$TOOL_RC" "$1: a judged outcome exits 0"
}

assert_one_call() {
  local count
  count=$(wc -l <"$LOG/requests" 2>/dev/null || printf '0')
  assert_equals 1 "$count" "$1: exactly one System One call"
}

assert_no_call() {
  assert_absent "$LOG/requests" "$1: no network call"
}

# The emitted confidence must always be a finite JSON number in [0, 1], and the
# output must always be strict JSON: NaN and Infinity are not JSON literals, so
# the parse must reject them as constants rather than accepting them leniently.
assert_strict_confidence() {
  local label=$1 result
  result=$(python3 - "$TOOL_OUT" <<'PY'
import json
import math
import sys


def reject_constant(name):
    raise ValueError("non-strict constant %s" % name)


try:
    payload = json.loads(sys.argv[1], parse_constant=reject_constant)
except ValueError:
    sys.stdout.write("non-strict")
    raise SystemExit(0)
value = payload.get("confidence")
ok = (
    isinstance(value, (int, float))
    and not isinstance(value, bool)
    and math.isfinite(value)
    and 0.0 <= value <= 1.0
)
sys.stdout.write("ok" if ok else "out-of-range")
PY
)
  assert_equals 'ok' "$result" "$label: the confidence is a finite number in [0, 1] in strict JSON"
}

# The brief's contract is one atomic forced-choice question per worker and never
# a list of workers, so the request body itself is checked: exactly one
# question, keyed `route`, with the two verdicts as its only options, one worker
# object as the state carrying the deterministic features and the window.
assert_atomic_question() {
  local label=$1 shape
  shape=$(python3 - "$LOG/body" <<'PY'
import json, sys
body = json.load(open(sys.argv[1], encoding="utf-8"))
questions = body.get("questions")
state = body.get("state")
criteria = questions.get("route", {}).get("criteria", {}) if isinstance(questions, dict) else {}
checks = {
    "question_count": len(questions) if isinstance(questions, dict) else -1,
    "question_type": questions.get("route", {}).get("type") if isinstance(questions, dict) else None,
    "options": sorted(criteria) if isinstance(criteria, dict) else None,
    "state_keys": sorted(state) if isinstance(state, dict) else None,
    "task": state.get("task") if isinstance(state, dict) else None,
    "history": state.get("history") if isinstance(state, dict) else None,
    "features_is_object": isinstance(state.get("features"), dict) if isinstance(state, dict) else False,
}
sys.stdout.write(json.dumps(checks))
PY
)
  assert_equals 1 "$(json_get "$shape" question_count)" "$label: exactly one question"
  assert_equals '"choice"' "$(json_get "$shape" question_type)" "$label: the question is a choice"
  assert_equals '["progressing", "stalled_looping"]' "$(json_get "$shape" options)" "$label: the two verdicts are the only options"
  assert_equals '["features", "history", "task"]' "$(json_get "$shape" state_keys)" "$label: the state is one worker object with its features and window"
  assert_equals 'true' "$(json_get "$shape" features_is_object)" "$label: the deterministic features reach the model"
}

# --- a stalled, looping worker at high confidence escalates -----------------
reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_typed_output "stalled"
assert_equals '"stalled_looping"' "$(json_get "$TOOL_OUT" verdict)" "the model verdict is reported"
assert_equals '"escalate_recovery"' "$(json_get "$TOOL_OUT" flag)" "a high-confidence stall escalates through the recovery playbook"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'stuck-crewmate-recovery' "the reason names the escalation playbook"
assert_one_call "stalled"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_atomic_question "stalled"
FEATURES=$(features_of "$TOOL_OUT")
assert_equals '6' "$(json_get "$FEATURES" cycles)" "every event in the window is a cycle"
assert_equals 'false' "$(json_get "$FEATURES" no_state_change)" "an alternating worker is not a single frozen state"
assert_equals 'true' "$(json_get "$FEATURES" oscillating)" "the failed/working alternation is detected in code"
assert_equals '"failed <> working"' "$(json_get "$FEATURES" oscillation_pair)" "the oscillating state pair is reported"
assert_equals '3' "$(json_get "$FEATURES" max_note_repeat)" "the repeated finding is counted in code"
assert_contains "$(json_get "$FEATURES" repeated_notes)" 'the queue worker drops the retry budget' "the repeated note text is reported"
assert_equals '"working>failed>working>failed>working>failed"' "$(json_get "$FEATURES" state_sequence)" "the state sequence is reported in order"
pass "stalled_looping: escalate_recovery, deterministic features, one atomic question, one loopback request"

# --- a progressing worker stays put -----------------------------------------
reset_log
start_fake --choice progressing --confidence 0.95
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$PROGRESS_FILE"
reap_fake
assert_typed_output "progressing"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "the progressing verdict is reported"
assert_equals '"continue"' "$(json_get "$TOOL_OUT" flag)" "a progressing worker needs no recovery action"
assert_equals '"ok"' "$(json_get "$TOOL_OUT" reason)" "a valid verdict carries a plain reason"
assert_one_call "progressing"
FEATURES=$(features_of "$TOOL_OUT")
assert_equals 'false' "$(json_get "$FEATURES" oscillating)" "a moving worker is not oscillating"
assert_equals 'false' "$(json_get "$FEATURES" no_state_change)" "a moving worker changes state"
assert_equals '0' "$(json_get "$FEATURES" max_note_repeat)" "a moving worker repeats no note"
pass "progressing: continue, one loopback request"

# --- no state change across the window is extracted deterministically -------
reset_log
printf '%s\n' 'working: still validating the same path' 'working: still validating the same path' 'working: nothing changed this cycle' >"$TMP_ROOT/frozen.status"
start_fake --choice progressing --confidence 0.95
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/frozen.status"
reap_fake
FEATURES=$(features_of "$TOOL_OUT")
assert_equals 'true' "$(json_get "$FEATURES" no_state_change)" "a frozen state window is detected"
assert_equals '1' "$(json_get "$FEATURES" distinct_states)" "a frozen window has one distinct state"
assert_equals '2' "$(json_get "$FEATURES" max_note_repeat)" "the identical note is counted"
assert_one_call "frozen"
pass "frozen state window: no_state_change and repeated note, in code"

# --- a note-level fix/revert alternation under one state is detected --------
reset_log
printf '%s\n' 'working: revert the retry change' 'working: reapply the retry change' 'working: revert the retry change' 'working: reapply the retry change' >"$TMP_ROOT/notes.status"
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/notes.status"
reap_fake
FEATURES=$(features_of "$TOOL_OUT")
assert_equals 'true' "$(json_get "$FEATURES" oscillating)" "a note-level fix/revert alternation is detected"
assert_equals '"reapply the retry change <> revert the retry change"' "$(json_get "$FEATURES" oscillation_pair)" "the oscillating note pair is reported"
assert_equals 'true' "$(json_get "$FEATURES" no_state_change)" "the single state is also reported"
pass "note-level oscillation: detected in code"

# --- low confidence never escalates -----------------------------------------
reset_log
start_fake --choice stalled_looping --confidence 0.4
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_typed_output "low confidence"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "an uncertain stall takes the fail-safe verdict"
assert_equals '"review_history"' "$(json_get "$TOOL_OUT" flag)" "an uncertain stall is handed back to firstmate"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below threshold' "the reason names the confidence gap"
assert_not_contains "$(json_get "$TOOL_OUT" flag)" 'escalate' "an uncertain stall is never an automatic escalation"
pass "low confidence: progressing plus review_history, never an escalation"

# --- a non-finite or out-of-range confidence never escalates ----------------
# NaN compares false against every bound and Infinity or a value above 1
# compares above the floor, so each must resolve to the fail-safe verdict with a
# valid in-range confidence instead of to the model's stalled answer.
for boundary in nan inf -0.1 1.1; do
  reset_log
  start_fake --choice stalled_looping --confidence "$boundary"
  run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
  reap_fake
  assert_typed_output "confidence $boundary"
  assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "confidence $boundary keeps the fail-safe verdict"
  assert_equals '"review_history"' "$(json_get "$TOOL_OUT" flag)" "confidence $boundary is handed back to firstmate"
  assert_strict_confidence "confidence $boundary"
  assert_one_call "confidence $boundary"
  pass "confidence $boundary: progressing plus review_history, in-range confidence, exit 0"
done

# --- an API error never escalates -------------------------------------------
reset_log
start_fake --status 400
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_typed_output "api error"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "an API error keeps the fail-safe verdict"
assert_equals '"review_history"' "$(json_get "$TOOL_OUT" flag)" "an API error is handed back to firstmate"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'api_error' "the reason names the API failure"
assert_not_contains "$(json_get "$TOOL_OUT" flag)" 'escalate' "an API error never escalates"
pass "API error: progressing plus review_history, exit 0"

# --- a malformed success response fails safe --------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_typed_output "malformed response"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "a malformed success response keeps the fail-safe verdict"
assert_contains_any "$(json_get "$TOOL_OUT" reason)" "the reason names the core failure" 'core_error' 'defect'
pass "malformed success response: fail-safe, exit 0"

# --- an unexpected verdict fails safe ---------------------------------------
reset_log
start_fake --choice something_else --confidence 0.99
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_typed_output "unexpected verdict"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "an unexpected verdict keeps the fail-safe verdict"
assert_equals '"review_history"' "$(json_get "$TOOL_OUT" flag)" "an unexpected verdict is handed back to firstmate"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'unexpected verdict' "the reason names the unexpected verdict"
pass "unexpected verdict: fail-safe, exit 0"

# --- the wall-clock bound fails safe and fast --------------------------------
reset_log
start_fake --choice stalled_looping --confidence 0.97 --delay 30
started=$(date +%s)
run_detector "$API_KEY" "$HOME_DIR" 1 '' "$STALL_FILE"
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "the wall-clock bound keeps the fail-safe verdict"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: fail-safe inside the bound, exit 0"

# --- a non-finite or unrepresentable bound never leaves the call unbounded ---
# NaN would make `timeout > 0` false and so silently arm nothing, and Infinity
# or a huge finite value overflows the platform timer; each must resolve to the
# fail-safe verdict carrying the real history, inside a finite bound, with no
# request reaching the delayed server.
for bad_timeout in nan inf 1e30; do
  reset_log
  start_fake --choice stalled_looping --confidence 0.97 --delay 30
  started=$(date +%s)
  run_detector "$API_KEY" "$HOME_DIR" "$bad_timeout" '' "$STALL_FILE"
  elapsed=$(( $(date +%s) - started ))
  reap_fake
  assert_typed_output "timeout $bad_timeout"
  assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "timeout $bad_timeout keeps the fail-safe verdict"
  assert_equals '"review_history"' "$(json_get "$TOOL_OUT" flag)" "timeout $bad_timeout hands the history back"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'fail_safe' "the reason names the fail-safe"
  assert_equals '6' "$(json_get "$(features_of "$TOOL_OUT")" cycles)" "timeout $bad_timeout still carries the real history"
  assert_no_call "timeout $bad_timeout"
  [ "$elapsed" -lt 10 ] || fail "timeout $bad_timeout did not return inside a finite bound (elapsed ${elapsed}s)"
  pass "timeout $bad_timeout: fail-safe, real features, finite bound, no request"
done

# --- a missing key fails safe without any network call ----------------------
reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector '' "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_typed_output "absent key"
assert_equals '"review_history"' "$(json_get "$TOOL_OUT" flag)" "a missing key is handed back to firstmate"
assert_no_call "absent key"
pass "absent key: fail-safe, no network call"

# --- the .env key is used, and the environment wins over it -----------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector '' "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_equals '"stalled_looping"' "$(json_get "$TOOL_OUT" verdict)" "the .env key judges normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$STALL_FILE"
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- --task resolves the home's state/<id>.status ---------------------------
printf '%s\n' "$STALL_HISTORY" >"$HOME_DIR/state/t_stall.status"
reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' --task t_stall
reap_fake
assert_typed_output "--task"
assert_equals '"stalled_looping"' "$(json_get "$TOOL_OUT" verdict)" "--task reads the recorded status history"
assert_one_call "--task"
assert_atomic_question "--task"
TASK_IN_STATE=$(python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.load(open(sys.argv[1]))["state"]))' "$LOG/body")
assert_equals '"t_stall"' "$(json_get "$TASK_IN_STATE" task)" "the task id reaches the model"
pass "--task: resolves the home's state directory"

# --- --lines bounds the window to the last n events -------------------------
reset_log
printf '%s\n' 'done: PR https://example.test/pr/1 checks green' 'working: reopen the work for one more review round' 'working: address the last review note' >"$TMP_ROOT/late.status"
start_fake --choice progressing --confidence 0.95
run_detector "$API_KEY" "$HOME_DIR" 20 '' --lines 2 "$TMP_ROOT/late.status"
reap_fake
assert_one_call "--lines 2"
FEATURES=$(features_of "$TOOL_OUT")
assert_equals '2' "$(json_get "$FEATURES" cycles)" "--lines bounds the window"
assert_equals '"working>working"' "$(json_get "$FEATURES" state_sequence)" "only the last two events are judged"
assert_equals 'null' "$(json_get "$FEATURES" terminal_state)" "a terminal event outside the window is excluded"
pass "--lines: the window is the last n events"

# --- fewer than two events is a no-call shortcut ----------------------------
reset_log
printf '%s\n' 'working: just started' >"$TMP_ROOT/short.status"
start_fake --choice stalled_looping --confidence 0.99
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/short.status"
reap_fake
assert_typed_output "insufficient history"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "one event cannot be a stall"
assert_equals '"insufficient_history"' "$(json_get "$TOOL_OUT" flag)" "one event is reported as insufficient history"
assert_no_call "insufficient history"
pass "insufficient history: progressing plus insufficient_history, no call"

# --- an empty history is a no-call shortcut ---------------------------------
reset_log
: >"$TMP_ROOT/empty.status"
start_fake --choice stalled_looping --confidence 0.99
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/empty.status"
reap_fake
assert_typed_output "empty history"
assert_equals '"insufficient_history"' "$(json_get "$TOOL_OUT" flag)" "no events is reported as insufficient history"
assert_no_call "empty history"
pass "empty history: progressing plus insufficient_history, no call"

# --- a terminal declaration is a no-call shortcut ---------------------------
reset_log
printf '%s\n' 'working: apply the fix' 'done: ready in branch fm/example' >"$TMP_ROOT/terminal.status"
start_fake --choice stalled_looping --confidence 0.99
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/terminal.status"
reap_fake
assert_typed_output "terminal"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "a finished worker is not stalled"
assert_equals '"terminal"' "$(json_get "$TOOL_OUT" flag)" "a done declaration is reported as terminal"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'terminal state done' "the reason names the terminal state"
assert_no_call "terminal"
pass "terminal: progressing plus terminal, no call"

# --- a lone failure declaration is terminal, a repeated one is judged -------
reset_log
printf '%s\n' 'working: apply the fix' 'failed: the queue worker cannot be fixed' >"$TMP_ROOT/onefail.status"
start_fake --choice stalled_looping --confidence 0.99
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/onefail.status"
reap_fake
assert_typed_output "single failure"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "a lone failure is not a stall loop"
assert_equals '"terminal"' "$(json_get "$TOOL_OUT" flag)" "a lone failure declaration is terminal"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'terminal state failed' "the reason names the terminal failure"
assert_no_call "single failure"
pass "single failure: progressing plus terminal, no call"

# --- stdin behaves exactly like a file --------------------------------------
reset_log
start_fake --choice progressing --confidence 0.95
run_detector "$API_KEY" "$HOME_DIR" 20 "$PROGRESS_HISTORY" -
reap_fake
assert_typed_output "stdin"
assert_equals '"progressing"' "$(json_get "$TOOL_OUT" verdict)" "stdin judges like a file"
assert_one_call "stdin"
pass "stdin behaves exactly like a file"

# --- usage errors refuse loudly with no network call ------------------------
reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' --bogus "$STALL_FILE"
reap_fake
expect_code 2 "$TOOL_RC" "an unknown flag is a usage error"
assert_equals '' "$TOOL_OUT" "a usage error prints nothing on stdout"
assert_contains "$TOOL_ERR" 'unknown flag --bogus' "the usage error names the flag"
assert_no_call "unknown flag"
pass "unknown flag: usage error, exit 2, no network"

for bad_lines in 0 abc 10001; do
  reset_log
  start_fake --choice stalled_looping --confidence 0.97
  run_detector "$API_KEY" "$HOME_DIR" 20 '' --lines "$bad_lines" "$STALL_FILE"
  reap_fake
  expect_code 2 "$TOOL_RC" "--lines $bad_lines is a usage error"
  assert_contains "$TOOL_ERR" '--lines must be a positive integer' "the usage error names --lines"
  assert_no_call "--lines $bad_lines"
  pass "--lines $bad_lines: usage error, exit 2, no network"
done

reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' --task
reap_fake
expect_code 2 "$TOOL_RC" "--task without a value is a usage error"
assert_contains "$TOOL_ERR" '--task needs a value' "the usage error names the missing value"
assert_no_call "--task without a value"
pass "--task without a value: usage error, exit 2, no network"

reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' --task t_missing
reap_fake
expect_code 2 "$TOOL_RC" "a missing task status file is a usage error"
assert_contains "$TOOL_ERR" 'cannot read the status history' "the usage error names the unreadable history"
assert_no_call "missing task history"
pass "missing task history: usage error, exit 2, no network"

reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' --task t_stall "$STALL_FILE"
reap_fake
expect_code 2 "$TOOL_RC" "--task with a history file is a usage error"
assert_contains "$TOOL_ERR" 'mutually exclusive' "the usage error names the conflict"
assert_no_call "--task with a history file"
pass "--task with a history file: usage error, exit 2, no network"

reset_log
start_fake --choice stalled_looping --confidence 0.97
run_detector "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/absent.status"
reap_fake
expect_code 2 "$TOOL_RC" "an unreadable history file is a usage error"
assert_equals '' "$TOOL_OUT" "an unreadable history prints nothing on stdout"
assert_contains "$TOOL_ERR" 'cannot read the status history' "the usage error names the unreadable file"
assert_no_call "unreadable history file"
pass "unreadable history file: usage error, exit 2, no network"

TOOL_OUT=$("$TOOL" --help)
TOOL_RC=$?
expect_code 0 "$TOOL_RC" "--help exits 0"
assert_contains "$TOOL_OUT" 'Usage:' "--help prints the usage"
pass "--help exits 0"

printf '# all fm-jev-nonconvergence tests passed\n'
