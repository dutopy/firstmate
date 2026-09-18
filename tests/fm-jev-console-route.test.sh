#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-console-route.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-classify-fake-typesafe.py, a fake typesafe.ai System One
# server bound to 127.0.0.1 on an ephemeral port. Cases cover the fast_answer
# and full_turn routes, a low-confidence fast_answer that must fall back, an API
# error, a malformed success response, an unexpected route, an invalid
# confidence, invalid input JSON, the wall-clock fallback, a missing key, the
# .env key fallback (and the environment winning over it), file input, and the
# usage errors. Every request goes to that loopback server, so no case reaches
# the real network, and each classification case asserts exactly one call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-console-route.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-classify-fake-typesafe.py"
STALE_CORE="$ROOT/tests/assets/jev-stale-core.py"
SHARED_CORE=${FM_JV_CONSOLE_ROUTE_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-console-route.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_CONSOLE_ROUTE_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-console-route)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$HOME_DIR/data" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-9f21-never-on-argv'
PAYLOAD='{"message":"where does the folium email lot stand","label":"Internal"}'

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

# run_route <core> <key> <timeout> <payload> [tool args...]: <payload> is piped
# to the tool. An empty <core> uses the tool's default resolution.
run_route() {
  local core=$1 key=$2 timeout=$3 payload=$4 _out _rc
  shift 4
  if [ -n "$core" ]; then
    _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$HOME_DIR" \
      FM_JV_CONSOLE_ROUTE_CORE="$core" FM_JV_CONSOLE_ROUTE_TIMEOUT="$timeout" \
      TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  else
    _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$HOME_DIR" \
      FM_JV_CONSOLE_ROUTE_TIMEOUT="$timeout" \
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
  assert_equals '["confidence", "flag", "reason", "verdict"]' "$(json_keys "$TOOL_OUT")" "$1: typed output keys"
  expect_code 0 "$TOOL_RC" "$1: a classified outcome exits 0"
}

assert_one_call() {
  local count
  count=$(wc -l <"$LOG/requests" 2>/dev/null || printf '0')
  assert_equals 1 "$count" "$1: exactly one System One call"
}

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

# --- a confident fast_answer is reported as answer_from_records --------------
reset_log
start_fake --choice fast_answer --confidence 0.97
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "fast answer"
assert_equals '"fast_answer"' "$(json_get "$TOOL_OUT" verdict)" "the model route is reported"
assert_equals '"answer_from_records"' "$(json_get "$TOOL_OUT" flag)" "the fast route carries the record-backed flag"
assert_equals '"ok"' "$(json_get "$TOOL_OUT" reason)" "a valid classification carries a plain reason"
assert_one_call "fast answer"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_contains "$(cat "$LOG/body")" '"full_turn"' "the full-turn option reaches the model"
assert_contains "$(cat "$LOG/body")" '"fast_answer"' "the fast option reaches the model"
pass "fast_answer: verdict, typed JSON, one loopback request"

# --- a confident full_turn is reported as the full turn ----------------------
reset_log
start_fake --choice full_turn --confidence 0.96
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "full turn"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "the full-turn route is reported"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" flag)" "the full-turn route carries its own flag"
pass "full_turn: verdict and flag"

# --- a low-confidence fast_answer falls back to the full turn ----------------
reset_log
start_fake --choice fast_answer --confidence 0.4
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "low-confidence fast answer"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "an uncertain fast answer routes to the full turn"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" flag)" "an uncertain answer never takes the fast path"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'below threshold' "the reason names the confidence gap"
pass "low-confidence fast_answer: full_turn, never a fast answer"

# --- an API error falls back to the full turn --------------------------------
reset_log
start_fake --status 400
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "api error"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "an API error routes to the full turn"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'api_error' "the reason names the API failure"
pass "API error: full_turn, exit 0"

# --- a malformed success response falls back to the full turn ----------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "malformed response"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "a malformed success response routes to the full turn"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'core_error' "the reason names the core failure"
pass "malformed success response: full_turn, exit 0"

# --- an unexpected route falls back to the full turn -------------------------
reset_log
start_fake --choice something_else --confidence 0.99
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_typed_output "unexpected route"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "an unexpected route routes to the full turn"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'unexpected route' "the reason names the unexpected route"
pass "unexpected route: full_turn, exit 0"

# --- an invalid confidence is a full-turn fail-safe --------------------------
for bad in nan inf -0.1 1.1; do
  reset_log
  start_fake --choice fast_answer --confidence "$bad"
  run_route '' "$API_KEY" 20 "$PAYLOAD" -
  reap_fake
  assert_typed_output "invalid confidence $bad"
  assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "confidence $bad routes to the full turn"
  assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" flag)" "confidence $bad never takes the fast path"
  assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "confidence $bad is reported as a numeric zero"
  assert_strict_json "$TOOL_OUT" "invalid confidence $bad"
  pass "invalid confidence $bad: full_turn, strict JSON"
done

# --- a stale core cannot push an invalid confidence past the wrapper ---------
reset_log
export FM_JV_STALE_ROUTE=fast_answer
run_route "$STALE_CORE" "$API_KEY" 20 "$PAYLOAD" -
unset FM_JV_STALE_ROUTE
assert_typed_output "stale core"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "a stale core's non-finite confidence routes to the full turn"
assert_equals '0.0' "$(json_get "$TOOL_OUT" confidence)" "a stale core's confidence is reported as numeric zero"
assert_strict_json "$TOOL_OUT" "stale core"
assert_absent "$LOG/requests" "the stale-core case makes no network call"
pass "stale core with a non-finite confidence: wrapper fail-safe, no network"

# --- invalid input JSON falls back without any network call ------------------
reset_log
start_fake --choice fast_answer --confidence 0.99
run_route '' "$API_KEY" 20 '{"message": "x",' -
reap_fake
assert_typed_output "invalid JSON"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "invalid input JSON routes to the full turn"
assert_absent "$LOG/requests" "invalid input JSON never reaches the network"
pass "invalid input JSON: full_turn, exit 0, no network"

# --- the wall-clock bound falls back and fast --------------------------------
reset_log
start_fake --choice fast_answer --confidence 0.97 --delay 30
started=$(date +%s)
run_route '' "$API_KEY" 1 "$PAYLOAD" -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "the wall-clock bound routes to the full turn"
assert_contains "$(json_get "$TOOL_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: fail-safe inside the bound, exit 0"

# --- a non-finite or absurd bound never leaves the call unbounded -------------
for bad_timeout in nan inf 1e30; do
  reset_log
  start_fake --choice fast_answer --confidence 0.97 --delay 30
  started=$(date +%s)
  run_route '' "$API_KEY" "$bad_timeout" "$PAYLOAD" -
  elapsed=$(( $(date +%s) - started ))
  reap_fake
  assert_typed_output "timeout $bad_timeout"
  assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "timeout $bad_timeout routes to the full turn"
  assert_contains "$(json_get "$TOOL_OUT" reason)" 'fail_safe' "the $bad_timeout reason names the fail-safe"
  assert_absent "$LOG/requests" "timeout $bad_timeout never reaches the network"
  [ "$elapsed" -lt 10 ] || fail "timeout $bad_timeout did not return inside a finite bound (elapsed ${elapsed}s)"
  pass "timeout $bad_timeout: fail-safe, finite bound, no request"
done

# --- a missing key falls back without any network call -----------------------
reset_log
start_fake --choice fast_answer --confidence 0.97
run_route '' '' 20 "$PAYLOAD" -
reap_fake
assert_typed_output "absent key"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "a missing key routes to the full turn"
assert_absent "$LOG/requests" "a missing key makes no network call"
pass "absent key: fail-safe, no network call"

# --- the .env key is used, and the environment wins over it ------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --choice fast_answer --confidence 0.97
run_route '' '' 20 "$PAYLOAD" -
reap_fake
assert_equals '"fast_answer"' "$(json_get "$TOOL_OUT" verdict)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --choice fast_answer --confidence 0.97
run_route '' "$API_KEY" 20 "$PAYLOAD" -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- file input behaves exactly like stdin -----------------------------------
printf '%s\n' "$PAYLOAD" >"$TMP_ROOT/message.json"
reset_log
start_fake --choice full_turn --confidence 0.95
run_route '' "$API_KEY" 20 '' "$TMP_ROOT/message.json"
reap_fake
assert_typed_output "file input"
assert_equals '"full_turn"' "$(json_get "$TOOL_OUT" verdict)" "file input classifies like stdin"
assert_present "$LOG/requests" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- usage errors refuse loudly with no network call -------------------------
reset_log
start_fake --choice fast_answer --confidence 0.97
run_route '' "$API_KEY" 20 "$PAYLOAD" --bogus
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

printf '# all fm-jev-console-route tests passed\n'
