#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-blocker.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-classify-fake-typesafe.py, a fake typesafe.ai System One
# server bound to 127.0.0.1 on an ephemeral port. Cases cover every class, a
# high-confidence fixture-noise suppression, a low-confidence answer that must
# never suppress, an API error, a malformed success response, invalid input
# JSON, the wall-clock fallback, a missing key, the .env key fallback (and the
# environment winning over it), an unexpected class, file input, and the usage
# errors. Every request goes to that loopback server, so no case reaches the
# real network, and each classification case asserts exactly one call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-blocker.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-classify-fake-typesafe.py"
STALE_CORE="$ROOT/tests/assets/jev-stale-core.py"
SHARED_CORE=${FM_JV_BLOCKER_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-blocker.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_BLOCKER_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-blocker)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$HOME_DIR/data" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-9f21-never-on-argv'
BLOCK_PAYLOAD='{"block":"the package registry returned 500 for the fourth time","task":"t-1234","note":"retried twice"}'

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

# run_blocker <key> <home> <timeout> <payload> [tool args...]: <payload> is piped
# to the tool, and stays unused by the cases that read an input file instead.
run_blocker() {
  local key=$1 home=$2 timeout=$3 payload=$4 _out _rc
  shift 4
  _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_BLOCKER_TIMEOUT="$timeout" TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
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

# run_core <core> <key> <home> <timeout> <payload> [tool args...]: like
# run_blocker, but against an explicit shared core so a stale-core case never
# depends on the real core's current behavior.
run_core() {
  local core=$1 key=$2 home=$3 timeout=$4 payload=$5 _out _rc
  shift 5
  _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_BLOCKER_CORE="$core" FM_JV_BLOCKER_TIMEOUT="$timeout" \
    TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  _rc=$?
  TOOL_OUT=$_out
  TOOL_RC=$_rc
  TOOL_ERR=$(cat "$STDERR_FILE")
}

# --- a real business blocker at high confidence is reported as an ordinary blocker
reset_log
start_fake --choice real_business_blocker --confidence 0.97
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "real business blocker"
assert_equals '"real_business_blocker"' "$(json_get "$TOOL_OUT" verdict)" "the model class is reported"
assert_equals '"none"' "$(json_get "$TOOL_OUT" flag)" "a real blocker needs no special advisory action"
assert_equals '"ok"' "$(json_get "$TOOL_OUT" reason)" "a valid classification carries a plain reason"
assert_one_call "real business blocker"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_contains "$(cat "$LOG/body")" '"transient_retryable"' "the class options reach the model"
assert_contains "$(cat "$LOG/body")" '"test_fixture_noise"' "the noise option reaches the model"
pass "real business blocker: verdict, typed JSON, one loopback request"

# --- needs_captain_decision routes to a keyed captain card -------------------
reset_log
start_fake --choice needs_captain_decision --confidence 0.95
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "needs captain decision"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "the captain-decision class is reported"
assert_equals '"captain_card"' "$(json_get "$TOOL_OUT" flag)" "the captain-decision class asks for a keyed card"
pass "needs_captain_decision: captain_card"

# --- transient_retryable suggests a bounded retry ---------------------------
reset_log
start_fake --choice transient_retryable --confidence 0.96
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "transient retryable"
assert_equals '"transient_retryable"' "$(json_get "$TOOL_OUT" verdict)" "the transient class is reported"
assert_equals '"bounded_retry"' "$(json_get "$TOOL_OUT" flag)" "the transient class suggests a bounded retry"
pass "transient_retryable: bounded_retry"

# --- high-confidence fixture noise marks the wake suppressible ---------------
reset_log
start_fake --choice test_fixture_noise --confidence 0.98
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "fixture noise"
assert_equals '"test_fixture_noise"' "$(json_get "$TOOL_OUT" verdict)" "the fixture-noise class is reported"
assert_equals '"suppress_wake"' "$(json_get "$TOOL_OUT" flag)" "high-confidence noise may suppress its wake"
assert_one_call "fixture noise"
pass "test_fixture_noise at high confidence: suppress_wake"

# --- low-confidence noise must never suppress; it surfaces to the captain ----
reset_log
start_fake --choice test_fixture_noise --confidence 0.4
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "low-confidence noise"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "an uncertain noise answer still surfaces to the captain"
assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "an uncertain answer never suppresses the wake"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below threshold' "the reason names the confidence gap"
assert_not_contains "$(json_get "$TOOL_OUT" flag)" 'suppress_wake' "no suppression below the floor"
pass "low-confidence fixture noise: surface_captain, never suppress"

# --- an API error fails safe --------------------------------------------------
reset_log
start_fake --status 400
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "api error"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "an API error surfaces to the captain"
assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "an API error carries the surface flag"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'api_error' "the reason names the API failure"
pass "API error: needs_captain_decision, exit 0"

# --- a malformed success response fails safe ---------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "malformed response"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "a malformed success response surfaces to the captain"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'core_error' "the reason names the core failure"
pass "malformed success response: fail-safe, exit 0"

# --- an unexpected class fails safe ------------------------------------------
reset_log
start_fake --choice something_else --confidence 0.99
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "unexpected class"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "an unexpected class surfaces to the captain"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'unexpected class' "the reason names the unexpected class"
pass "unexpected class: fail-safe, exit 0"

# --- an invalid confidence is a fail-safe, never a suppression ---------------
# NaN is the reported case: without strict validation, `nan < 0.9` is false, so
# a fixture-noise answer would suppress its wake and emit non-standard JSON.
for bad in nan inf -0.1 1.1; do
  reset_log
  start_fake --choice test_fixture_noise --confidence "$bad"
  run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
  reap_fake
  assert_typed_output "invalid confidence $bad"
  assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "confidence $bad surfaces to the captain"
  assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "confidence $bad never suppresses"
  assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "confidence $bad is reported as a numeric zero"
  assert_strict_json "$TOOL_OUT" "invalid confidence $bad"
  pass "invalid confidence $bad: fail-safe default, strict JSON"
done

# --- a stale core cannot push an invalid confidence past the wrapper ---------
reset_log
export FM_JV_STALE_ROUTE=test_fixture_noise
run_core "$STALE_CORE" "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
unset FM_JV_STALE_ROUTE
assert_typed_output "stale core"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "a stale core's non-finite confidence surfaces to the captain"
assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "a stale core cannot suppress a wake"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a stale core's confidence is reported as numeric zero"
assert_strict_json "$TOOL_OUT" "stale core"
assert_absent "$LOG/requests" "the stale-core case makes no network call"
pass "stale core with a non-finite confidence: wrapper fail-safe, no network"

# --- invalid input JSON fails safe without any network call ------------------
reset_log
start_fake --choice test_fixture_noise --confidence 0.99
run_blocker "$API_KEY" "$HOME_DIR" 20 '{"block": "x",' -
reap_fake
assert_typed_output "invalid JSON"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "invalid input JSON surfaces to the captain"
assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "invalid input JSON carries the surface flag"
assert_absent "$LOG/requests" "invalid input JSON never reaches the network"
pass "invalid input JSON: fail-safe, exit 0, no network"

# --- the wall-clock bound fails safe and fast --------------------------------
reset_log
start_fake --choice real_business_blocker --confidence 0.97 --delay 30
started=$(date +%s)
run_blocker "$API_KEY" "$HOME_DIR" 1 "$BLOCK_PAYLOAD" -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "the wall-clock bound surfaces to the captain"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: fail-safe inside the bound, exit 0"

# --- a non-finite or absurd bound never leaves the call unbounded -------------
# NaN would make `timeout > 0` false and so silently arm nothing, and Infinity
# or a huge finite value overflows the platform timer; each must resolve to the
# fail-safe verdict inside a finite bound, with no request reaching the delayed
# server.
for bad_timeout in nan inf 1e30; do
  reset_log
  start_fake --choice real_business_blocker --confidence 0.97 --delay 30
  started=$(date +%s)
  run_blocker "$API_KEY" "$HOME_DIR" "$bad_timeout" "$BLOCK_PAYLOAD" -
  elapsed=$(( $(date +%s) - started ))
  reap_fake
  assert_typed_output "timeout $bad_timeout"
  assert_equals '"needs_captain_decision"' "$(json_get "$TOOL_OUT" verdict)" "timeout $bad_timeout surfaces to the captain"
  assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "timeout $bad_timeout keeps the fail-safe flag"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'fail_safe' "the $bad_timeout reason names the fail-safe"
  assert_absent "$LOG/requests" "timeout $bad_timeout never reaches the network"
  [ "$elapsed" -lt 10 ] || fail "timeout $bad_timeout did not return inside a finite bound (elapsed ${elapsed}s)"
  pass "timeout $bad_timeout: fail-safe, finite bound, no request"
done

# --- a missing key fails safe without any network call -----------------------
reset_log
start_fake --choice real_business_blocker --confidence 0.97
run_blocker '' "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_typed_output "absent key"
assert_equals '"surface_captain"' "$(json_get "$TOOL_OUT" flag)" "a missing key surfaces to the captain"
assert_absent "$LOG/requests" "a missing key makes no network call"
pass "absent key: fail-safe, no network call"

# --- the .env key is used, and the environment wins over it ------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --choice real_business_blocker --confidence 0.97
run_blocker '' "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_equals '"real_business_blocker"' "$(json_get "$TOOL_OUT" verdict)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --choice real_business_blocker --confidence 0.97
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- file input behaves exactly like stdin -----------------------------------
printf '%s\n' "$BLOCK_PAYLOAD" >"$TMP_ROOT/block.json"
reset_log
start_fake --choice transient_retryable --confidence 0.95
run_blocker "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/block.json"
reap_fake
assert_typed_output "file input"
assert_equals '"transient_retryable"' "$(json_get "$TOOL_OUT" verdict)" "file input classifies like stdin"
assert_present "$LOG/requests" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- usage errors refuse loudly with no network call -------------------------
reset_log
start_fake --choice real_business_blocker --confidence 0.97
run_blocker "$API_KEY" "$HOME_DIR" 20 "$BLOCK_PAYLOAD" --bogus
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

printf '# all fm-jev-blocker tests passed\n'
