#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-finding.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-finding-fake-typesafe.py, a fake typesafe.ai System One
# server bound to 127.0.0.1 on an ephemeral port. Cases cover the three
# severities, the one-atomic-question request shape, a low-confidence answer
# that falls back to the default severity with a flag, an API error, a
# malformed success response, an unexpected severity, the wall-clock fallback,
# a missing key, the .env key fallback (and the environment winning over it),
# file input, and the usage errors (invalid JSON, empty input, an empty finding
# object, and an unknown flag). Every request goes to that loopback server, so
# no case reaches the real network, and each classification case asserts
# exactly one call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-finding.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-finding-fake-typesafe.py"
SHARED_CORE=${FM_JV_FINDING_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-finding.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_FINDING_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-finding)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$HOME_DIR/data" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-4c17-never-on-argv'
FINDING_PAYLOAD='{"title":"the retry loop swallows the error","description":"a failed call returns success instead of surfacing the failure","context":"review of the queue worker diff"}'

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

# run_finding <key> <home> <timeout> <payload> [tool args...]: <payload> is
# piped to the tool, and stays unused by the cases that read an input file
# instead.
run_finding() {
  local key=$1 home=$2 timeout=$3 payload=$4 _out _rc
  shift 4
  _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_FINDING_TIMEOUT="$timeout" TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
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
  assert_equals '["confidence", "flag", "reason", "severity"]' "$(json_keys "$TOOL_OUT")" "$1: typed output keys"
  expect_code 0 "$TOOL_RC" "$1: a classified outcome exits 0"
}

assert_one_call() {
  local count
  count=$(wc -l <"$LOG/requests" 2>/dev/null || printf '0')
  assert_equals 1 "$count" "$1: exactly one System One call"
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

# The brief's contract is one atomic forced-choice question per finding and
# never a state list, so the request body itself is checked: exactly one
# question, keyed `route`, with the three severities as its only options, and a
# single finding object as the state.
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
    "state_is_object": isinstance(state, dict),
    "state_title": state.get("title") if isinstance(state, dict) else None,
}
sys.stdout.write(json.dumps(checks))
PY
)
  assert_equals 1 "$(json_get "$shape" question_count)" "$label: exactly one question"
  assert_equals '"choice"' "$(json_get "$shape" question_type)" "$label: the question is a choice"
  assert_equals '["blocking", "cosmetic", "important"]' "$(json_get "$shape" options)" "$label: the three severities are the only options"
  assert_equals 'true' "$(json_get "$shape" state_is_object)" "$label: the state is one finding object, never a list"
  assert_equals '"the retry loop swallows the error"' "$(json_get "$shape" state_title)" "$label: the finding reaches the model"
}

# --- blocking at high confidence is batched as a required fix ----------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "blocking"
assert_equals '"blocking"' "$(json_get "$TOOL_OUT" severity)" "the model severity is reported"
assert_equals '"fix_now"' "$(json_get "$TOOL_OUT" flag)" "blocking asks for a required fix in the batch"
assert_equals '"ok"' "$(json_get "$TOOL_OUT" reason)" "a valid classification carries a plain reason"
assert_one_call "blocking"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_atomic_question "blocking"
pass "blocking: severity, fix_now, one atomic question, one loopback request"

# --- important is batched in the same single batch --------------------------
reset_log
start_fake --choice important --confidence 0.95
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "important"
assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "the important severity is reported"
assert_equals '"fix_in_batch"' "$(json_get "$TOOL_OUT" flag)" "important joins the same single batch"
assert_one_call "important"
pass "important: severity, fix_in_batch"

# --- cosmetic is listed but may be deferred ---------------------------------
reset_log
start_fake --choice cosmetic --confidence 0.96
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "cosmetic"
assert_equals '"cosmetic"' "$(json_get "$TOOL_OUT" severity)" "the cosmetic severity is reported"
assert_equals '"optional_polish"' "$(json_get "$TOOL_OUT" flag)" "cosmetic is optional polish, never a drop"
assert_one_call "cosmetic"
pass "cosmetic: severity, optional_polish"

# --- low confidence falls back to the default severity with a flag -----------
reset_log
start_fake --choice blocking --confidence 0.4
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "low confidence"
assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "an uncertain finding takes the default severity"
assert_equals '"needs_review"' "$(json_get "$TOOL_OUT" flag)" "an uncertain finding is flagged for review"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below threshold' "the reason names the confidence gap"
assert_not_contains "$(json_get "$TOOL_OUT" flag)" 'fix_now' "an uncertain finding is never promoted to blocking"
pass "low confidence: important plus needs_review, never a drop"

# --- a non-finite or out-of-range confidence never bypasses the floor --------
# NaN compares false against every bound and Infinity or a value above 1
# compares above the floor, so each must resolve to the default severity with a
# valid in-range confidence instead of to the model's blocking answer.
for boundary in nan inf -0.1 1.1; do
  reset_log
  start_fake --choice blocking --confidence "$boundary"
  run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
  reap_fake
  assert_typed_output "confidence $boundary"
  assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "confidence $boundary keeps the default severity"
  assert_equals '"needs_review"' "$(json_get "$TOOL_OUT" flag)" "confidence $boundary is flagged for review"
  assert_strict_confidence "confidence $boundary"
  assert_one_call "confidence $boundary"
  pass "confidence $boundary: important plus needs_review, in-range confidence, exit 0"
done

# --- an API error falls back to the default severity with a flag -------------
reset_log
start_fake --status 400
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "api error"
assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "an API error keeps the default severity"
assert_equals '"needs_review"' "$(json_get "$TOOL_OUT" flag)" "an API error is flagged for review"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'api_error' "the reason names the API failure"
pass "API error: important plus needs_review, exit 0"

# --- a malformed success response fails safe ---------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "malformed response"
assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "a malformed success response keeps the default severity"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'core_error' "the reason names the core failure"
pass "malformed success response: fail-safe, exit 0"

# --- an unexpected severity fails safe ---------------------------------------
reset_log
start_fake --choice something_else --confidence 0.99
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "unexpected severity"
assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "an unexpected severity keeps the default"
assert_equals '"needs_review"' "$(json_get "$TOOL_OUT" flag)" "an unexpected severity is flagged for review"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'unexpected severity' "the reason names the unexpected severity"
pass "unexpected severity: fail-safe, exit 0"

# --- the wall-clock bound fails safe and fast --------------------------------
reset_log
start_fake --choice blocking --confidence 0.97 --delay 30
started=$(date +%s)
run_finding "$API_KEY" "$HOME_DIR" 1 "$FINDING_PAYLOAD" -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "the wall-clock bound keeps the default severity"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: fail-safe inside the bound, exit 0"

# --- a non-finite or absurd bound never leaves the call unbounded -------------
# NaN would make `timeout > 0` false and so silently arm nothing, and Infinity
# or a huge finite value overflows the platform timer; each must resolve to the
# default severity inside a finite bound, with no request reaching the delayed
# server.
for bad_timeout in nan inf 1e30; do
  reset_log
  start_fake --choice blocking --confidence 0.97 --delay 30
  started=$(date +%s)
  run_finding "$API_KEY" "$HOME_DIR" "$bad_timeout" "$FINDING_PAYLOAD" -
  elapsed=$(( $(date +%s) - started ))
  reap_fake
  assert_typed_output "timeout $bad_timeout"
  assert_equals '"important"' "$(json_get "$TOOL_OUT" severity)" "timeout $bad_timeout keeps the default severity"
  assert_equals '"needs_review"' "$(json_get "$TOOL_OUT" flag)" "timeout $bad_timeout keeps the fail-safe flag"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'fail_safe' "the $bad_timeout reason names the fail-safe"
  assert_absent "$LOG/requests" "timeout $bad_timeout never reaches the network"
  [ "$elapsed" -lt 10 ] || fail "timeout $bad_timeout did not return inside a finite bound (elapsed ${elapsed}s)"
  pass "timeout $bad_timeout: fail-safe, finite bound, no request"
done

# --- a missing key fails safe without any network call -----------------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding '' "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_typed_output "absent key"
assert_equals '"needs_review"' "$(json_get "$TOOL_OUT" flag)" "a missing key is flagged for review"
assert_absent "$LOG/requests" "a missing key makes no network call"
pass "absent key: fail-safe, no network call"

# --- the .env key is used, and the environment wins over it ------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --choice blocking --confidence 0.97
run_finding '' "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_equals '"blocking"' "$(json_get "$TOOL_OUT" severity)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- file input behaves exactly like stdin -----------------------------------
printf '%s\n' "$FINDING_PAYLOAD" >"$TMP_ROOT/finding.json"
reset_log
start_fake --choice cosmetic --confidence 0.95
run_finding "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/finding.json"
reap_fake
assert_typed_output "file input"
assert_equals '"cosmetic"' "$(json_get "$TOOL_OUT" severity)" "file input classifies like stdin"
assert_present "$LOG/requests" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- invalid input JSON is a usage error with no network call ----------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 '{"title": "x",' -
reap_fake
expect_code 2 "$TOOL_RC" "invalid input JSON is a usage error"
assert_equals '' "$TOOL_OUT" "invalid input JSON prints nothing on stdout"
assert_contains "$TOOL_ERR" 'invalid JSON input' "the usage error names the invalid JSON"
assert_absent "$LOG/requests" "invalid input JSON never reaches the network"
pass "invalid input JSON: usage error, exit 2, no network"

# --- empty input is a usage error with no network call -----------------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 '' -
reap_fake
expect_code 2 "$TOOL_RC" "empty input is a usage error"
assert_equals '' "$TOOL_OUT" "empty input prints nothing on stdout"
assert_contains "$TOOL_ERR" 'empty input' "the usage error names the empty input"
assert_absent "$LOG/requests" "empty input never reaches the network"
pass "empty input: usage error, exit 2, no network"

# --- a JSON object with no finding text is a usage error ---------------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 '{"title": "  ", "description": null}' -
reap_fake
expect_code 2 "$TOOL_RC" "a JSON object with no finding text is a usage error"
assert_equals '' "$TOOL_OUT" "an empty finding prints nothing on stdout"
assert_contains "$TOOL_ERR" 'empty finding' "the usage error names the empty finding"
assert_absent "$LOG/requests" "an empty finding never reaches the network"
pass "empty finding object: usage error, exit 2, no network"

# --- a non-object JSON input is a usage error --------------------------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 '["one", "list"]' -
reap_fake
expect_code 2 "$TOOL_RC" "a JSON list is a usage error"
assert_contains "$TOOL_ERR" 'must be a JSON object' "the usage error names the shape"
assert_absent "$LOG/requests" "a JSON list never reaches the network"
pass "JSON list input: usage error, exit 2, no network"

# --- usage errors refuse loudly with no network call -------------------------
reset_log
start_fake --choice blocking --confidence 0.97
run_finding "$API_KEY" "$HOME_DIR" 20 "$FINDING_PAYLOAD" --bogus
reap_fake
expect_code 2 "$TOOL_RC" "an unknown flag is a usage error"
assert_equals '' "$TOOL_OUT" "a usage error prints nothing on stdout"
assert_contains "$TOOL_ERR" 'unknown flag --bogus' "the usage error names the flag"
assert_absent "$LOG/requests" "a usage error never reaches the network"
pass "usage errors exit 2 with a named diagnostic and no network call"

TOOL_OUT=$("$TOOL" --help)
TOOL_RC=$?
expect_code 0 "$TOOL_RC" "--help exits 0"
assert_contains "$TOOL_OUT" 'Usage:' "--help prints the usage"
pass "--help exits 0"

printf '# all fm-jev-finding tests passed\n'
