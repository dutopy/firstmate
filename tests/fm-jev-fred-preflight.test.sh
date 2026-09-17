#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-fred-preflight.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-fred-preflight-fake-typesafe.py, a fake typesafe.ai System
# One server bound to 127.0.0.1 on an ephemeral port. Cases cover all three
# classes, a low-confidence answer in the safe class that must never stay
# routine, a low-confidence answer in the unsafe class, an API error, a
# malformed success response, an unexpected class, NaN and Infinity (plus
# out-of-range) confidences, invalid input JSON, the wall-clock fallback, a
# missing key, the .env key fallback (and the environment winning over it),
# file input, the read-only advisory promise, and the usage errors. Every
# request goes to that loopback server, so no case reaches the real network,
# and each classification case asserts exactly one System One call.
#
# The classifier is a thin wrapper over the captain-private shared core, which
# this repository does not track: the suite skips cleanly when that core is not
# readable, and FM_JV_FRED_PREFLIGHT_CORE points it at another copy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-fred-preflight.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-fred-preflight-fake-typesafe.py"
SHARED_CORE=${FM_JV_FRED_PREFLIGHT_CORE:-/home/dutopy/atelier/data/jev_decide.py}
STALE_CORE="$ROOT/tests/assets/jev-fred-preflight-stale-core.py"

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-fred-preflight.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_FRED_PREFLIGHT_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-fred-preflight)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$HOME_DIR/data" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-7c14-never-on-argv'
ACTION_PAYLOAD='{"action":"reply to the supplier about the invoice","target":"supplier thread","context":"the thread Fred already owns","note":"draft for review"}'

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

# cleanup_all preserves the status that triggered it, so an assertion failure
# still fails this script: an EXIT trap that exits 0 unconditionally would
# report every failure as a pass to bin/fm-test-run.sh, which keys off the
# script's exit code alone.
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

# run_tool <key> <home> <timeout> <payload> [tool args...]: <payload> is piped
# to the tool, and stays unused by the cases that read an input file instead.
run_tool() {
  local key=$1 home=$2 timeout=$3 payload=$4 _out _rc
  shift 4
  _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_FRED_PREFLIGHT_TIMEOUT="$timeout" TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  _rc=$?
  TOOL_OUT=$_out
  TOOL_RC=$_rc
  TOOL_ERR=$(cat "$STDERR_FILE")
}

# run_tool_tmpdir <tmpdir> <key> <home> <payload>: like run_tool, but with
# TMPDIR pointed at a fixture directory so a case can prove the tool leaves no
# temporary artifact behind.
run_tool_tmpdir() {
  local tmpdir=$1 key=$2 home=$3 payload=$4 _out _rc
  _out=$(printf '%s' "$payload" | TMPDIR="$tmpdir" TYPESAFE_API_KEY="$key" \
    FM_HOME="$home" FM_JV_FRED_PREFLIGHT_TIMEOUT=20 TYPESAFE_BASE_URL="$BASE" \
    "$TOOL" - 2>"$STDERR_FILE")
  _rc=$?
  TOOL_OUT=$_out
  TOOL_RC=$_rc
  TOOL_ERR=$(cat "$STDERR_FILE")
}

# run_tool_core <core> <key> <home> <timeout> <payload> [tool args...]: like
# run_tool, but against an explicit shared core so a stale-core case never
# depends on the real core's current behavior.
run_tool_core() {
  local core=$1 key=$2 home=$3 timeout=$4 payload=$5 _out _rc
  shift 5
  _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_FRED_PREFLIGHT_CORE="$core" FM_JV_FRED_PREFLIGHT_TIMEOUT="$timeout" \
    TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
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
  assert_equals '["confidence", "flag", "reason", "verdict"]' "$(json_keys "$TOOL_OUT")" "$1: typed output keys"
  expect_code 0 "$TOOL_RC" "$1: a classified outcome exits 0"
}

assert_one_call() {
  local count
  count=$(wc -l <"$LOG/requests" 2>/dev/null || printf '0')
  assert_equals 1 "$count" "$1: exactly one System One call"
}

# assert_fail_safe <label>: the fallback verdict is consequential with the
# hold-for-review flag, and never the routine class.
assert_fail_safe() {
  local label=$1
  assert_equals '"consequential"' "$(json_get "$TOOL_OUT" verdict)" "$label: the fallback verdict is consequential"
  assert_equals '"hold_for_review"' "$(json_get "$TOOL_OUT" flag)" "$label: the fallback flag holds for review"
  assert_not_equals '"routine_reversible"' "$(json_get "$TOOL_OUT" verdict)" "$label: no fail-safe path is ever routine"
}

# assert_strict_json <text> <msg>: the text parses as strict JSON, so no NaN or
# Infinity constant slipped into the typed output.
assert_strict_json() {
  local out=$1 msg=$2
  python3 - "$out" <<'PY' || fail "$msg: output is not strict JSON"
import json
import sys


def reject(constant):
    raise ValueError("non-finite JSON constant: " + constant)


json.loads(sys.argv[1], parse_constant=reject)
PY
}

# --- a routine, reversible action proceeds at high confidence ----------------
reset_log
start_fake --choice routine_reversible --confidence 0.96
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "routine reversible"
assert_equals '"routine_reversible"' "$(json_get "$TOOL_OUT" verdict)" "the routine class is reported"
assert_equals '"proceed"' "$(json_get "$TOOL_OUT" flag)" "routine work carries the proceed recommendation"
assert_equals '"ok"' "$(json_get "$TOOL_OUT" reason)" "a valid classification carries a plain reason"
assert_one_call "routine reversible"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_contains "$(cat "$LOG/body")" '"consequential"' "the class options reach the model"
assert_contains "$(cat "$LOG/body")" '"irreversible_or_secret"' "the irreversible class reaches the model"
assert_contains "$(cat "$LOG/body")" 'reply to the supplier about the invoice' "the intended action reaches the model"
pass "routine_reversible at high confidence: proceed, typed JSON, one loopback request"

# --- a consequential action holds for review ---------------------------------
reset_log
start_fake --choice consequential --confidence 0.95
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "consequential"
assert_equals '"consequential"' "$(json_get "$TOOL_OUT" verdict)" "the consequential class is reported"
assert_equals '"hold_for_review"' "$(json_get "$TOOL_OUT" flag)" "a consequential action holds for review"
assert_one_call "consequential"
pass "consequential at high confidence: hold_for_review"

# --- an irreversible or secret-exposing action goes to the human portal ------
reset_log
start_fake --choice irreversible_or_secret --confidence 0.97
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "irreversible or secret"
assert_equals '"irreversible_or_secret"' "$(json_get "$TOOL_OUT" verdict)" "the irreversible class is reported"
assert_equals '"human_portal"' "$(json_get "$TOOL_OUT" flag)" "an irreversible action routes to the human portal"
assert_one_call "irreversible or secret"
pass "irreversible_or_secret at high confidence: human_portal"

# --- a low-confidence routine answer must never stay routine -----------------
reset_log
start_fake --choice routine_reversible --confidence 0.4
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "low-confidence routine"
assert_fail_safe "low-confidence routine"
assert_equals '0.4' "$(json_get "$TOOL_OUT" confidence)" "the low confidence is still reported as evidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below threshold' "the reason names the confidence gap"
assert_one_call "low-confidence routine"
pass "low-confidence routine_reversible: consequential, never routine"

# --- a low-confidence unsafe answer also fails safe to consequential ---------
reset_log
start_fake --choice irreversible_or_secret --confidence 0.6
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "low-confidence irreversible"
assert_fail_safe "low-confidence irreversible"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below threshold' "the reason names the confidence gap"
pass "low-confidence irreversible_or_secret: consequential fallback"

# --- an API error fails safe --------------------------------------------------
reset_log
start_fake --status 400
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "api error"
assert_fail_safe "api error"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'api_error' "the reason names the API failure"
pass "API error: consequential, exit 0"

# --- a malformed success response fails safe ---------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "malformed response"
assert_fail_safe "malformed response"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'core_error' "the reason names the core failure"
pass "malformed success response: fail-safe, exit 0"

# --- an unexpected class fails safe ------------------------------------------
reset_log
start_fake --choice something_else --confidence 0.99
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "unexpected class"
assert_fail_safe "unexpected class"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'unexpected class' "the reason names the unexpected class"
pass "unexpected class: fail-safe, exit 0"

# --- a non-finite or out-of-range confidence from the API is a fail-safe -----
# The reported case is NaN: without strict validation, `nan < 0.9` is false and
# Infinity is above the floor, so either one would be reported as a confident
# routine action, and NaN would emit non-standard JSON. The shared core already
# refuses such a confidence, so every one of these answers carries the core's
# own invalid_confidence reason rather than a class.
for bad in nan inf -0.1 1.1; do
  reset_log
  start_fake --choice routine_reversible --confidence "$bad"
  run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
  reap_fake
  assert_typed_output "invalid confidence $bad"
  assert_fail_safe "invalid confidence $bad"
  assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "confidence $bad is reported as a numeric zero"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'invalid_confidence' "confidence $bad is refused, not classified"
  assert_strict_json "$TOOL_OUT" "invalid confidence $bad"
  pass "invalid confidence $bad: fail-safe fallback, strict JSON"
done

# --- a stale core cannot push an invalid confidence past the wrapper ---------
# The real core already refuses these, so the wrapper's own boundary is proven
# against a stand-in core that answers a class at `proceed` with a confidence
# the core would have rejected. FM_JV_STALE_ROUTE names the routine class: a
# wrapper that emitted it would look exactly like a silent wave-through.
for bad in nan inf -0.1 1.1; do
  reset_log
  start_fake --choice irreversible_or_secret --confidence 0.97
  export FM_JV_STALE_CONFIDENCE="$bad"
  export FM_JV_STALE_ROUTE=routine_reversible
  run_tool_core "$STALE_CORE" "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
  unset FM_JV_STALE_CONFIDENCE FM_JV_STALE_ROUTE
  assert_typed_output "stale core $bad"
  assert_fail_safe "stale core $bad"
  assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a stale core's confidence $bad is reported as numeric zero"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'invalid or missing confidence' "a stale core's $bad confidence is rejected at the wrapper boundary"
  assert_strict_json "$TOOL_OUT" "stale core $bad"
  assert_absent "$LOG/requests" "the stale-core case with $bad makes no network call"
  reap_fake
  pass "stale core with confidence $bad: wrapper fail-safe, no network"
done

# --- invalid input JSON fails safe without any network call ------------------
reset_log
start_fake --choice routine_reversible --confidence 0.99
run_tool "$API_KEY" "$HOME_DIR" 20 '{"action": "x",' -
reap_fake
assert_typed_output "invalid JSON"
assert_fail_safe "invalid JSON"
assert_absent "$LOG/requests" "invalid input JSON never reaches the network"
pass "invalid input JSON: fail-safe, exit 0, no network"

# --- the wall-clock bound fails safe and fast --------------------------------
reset_log
start_fake --choice routine_reversible --confidence 0.97 --delay 30
started=$(date +%s)
run_tool "$API_KEY" "$HOME_DIR" 1 "$ACTION_PAYLOAD" -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_fail_safe "timeout"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: fail-safe inside the bound, exit 0"

# --- a missing key fails safe without any network call -----------------------
reset_log
start_fake --choice routine_reversible --confidence 0.97
run_tool '' "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_typed_output "absent key"
assert_fail_safe "absent key"
assert_absent "$LOG/requests" "a missing key makes no network call"
pass "absent key: fail-safe, no network call"

# --- the .env key is used, and the environment wins over it ------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --choice routine_reversible --confidence 0.97
run_tool '' "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_equals '"routine_reversible"' "$(json_get "$TOOL_OUT" verdict)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --choice routine_reversible --confidence 0.97
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- file input behaves exactly like stdin -----------------------------------
printf '%s\n' "$ACTION_PAYLOAD" >"$TMP_ROOT/action.json"
reset_log
start_fake --choice consequential --confidence 0.95
run_tool "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/action.json"
reap_fake
assert_typed_output "file input"
assert_equals '"consequential"' "$(json_get "$TOOL_OUT" verdict)" "file input classifies like stdin"
assert_present "$LOG/requests" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- advisory and read-only: no live mutation and no leftover artifact -------
# A dedicated home is used here, and the tool runs in it for the first time, so
# any file the tool writes into the home it reads shows up as a difference. A
# home that earlier cases had already visited could hide one.
reset_log
ADVISORY_TMP="$TMP_ROOT/advisory-tmp"
ADVISORY_HOME="$TMP_ROOT/advisory-home"
mkdir -p "$ADVISORY_TMP" "$ADVISORY_HOME/data"
ln -s "$SHARED_CORE" "$ADVISORY_HOME/data/jev_decide.py"
find "$ADVISORY_HOME" | LC_ALL=C sort >"$TMP_ROOT/home-before"
start_fake --choice irreversible_or_secret --confidence 0.97
run_tool_tmpdir "$ADVISORY_TMP" "$API_KEY" "$ADVISORY_HOME" "$ACTION_PAYLOAD"
reap_fake
find "$ADVISORY_HOME" | LC_ALL=C sort >"$TMP_ROOT/home-after"
assert_equals "$(cat "$TMP_ROOT/home-before")" "$(cat "$TMP_ROOT/home-after")" "the tool writes nothing into the home it reads, not even beside the shared core"
assert_equals '' "$(ls -A "$ADVISORY_TMP")" "the tool leaves no temporary artifact behind"
assert_equals '"human_portal"' "$(json_get "$TOOL_OUT" flag)" "an irreversible action still routes to the human portal"
pass "read-only advisory: no write into the home, no leftover temporary file"

# --- usage errors refuse loudly with no network call -------------------------
reset_log
start_fake --choice routine_reversible --confidence 0.97
run_tool "$API_KEY" "$HOME_DIR" 20 "$ACTION_PAYLOAD" --bogus
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

printf '# all fm-jev-fred-preflight tests passed\n'
