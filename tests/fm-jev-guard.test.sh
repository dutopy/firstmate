#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-guard.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-guard-fake-typesafe.py, a fake typesafe.ai System One server
# bound to 127.0.0.1 on an ephemeral port. Cases cover a high-confidence safe
# merge, a low-confidence answer, a high-confidence unsafe answer, a
# needs_human route, an unsafe answer below the threshold, an API error, a
# malformed success response, the wall-clock fallback, a missing key, the .env
# key fallback (and the environment winning over it), the dispatch rubric, file
# input, and the usage errors. Every request goes to that loopback server, so no
# case reaches the real network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-guard.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-guard-fake-typesafe.py"
SHARED_CORE=${FM_JV_GUARD_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-guard.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_GUARD_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-guard)
HOME_DIR="$TMP_ROOT/home"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$HOME_DIR/data" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-3d9a-never-on-argv'
MERGE_PAYLOAD='{"rubric":"merge","action":"merge the docs-only PR","files":["README.md"],"url":"https://example.invalid/pull/1"}'
DISPATCH_PAYLOAD='{"rubric":"dispatch","action":"fix the off-by-one in bin/pager.sh","project":"pager"}'

BASE=''
FAKE_PID=''
GUARD_OUT=''
GUARD_RC=''
GUARD_ERR=''

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

# run_guard <key> <home> <timeout> <payload> [tool args...]: <payload> is piped
# to the tool, and stays unused by the cases that read an input file instead.
run_guard() {
  local key=$1 home=$2 timeout=$3 payload=$4 _out _rc
  shift 4
  _out=$(printf '%s' "$payload" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_GUARD_TIMEOUT="$timeout" TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  _rc=$?
  GUARD_OUT=$_out
  GUARD_RC=$_rc
  GUARD_ERR=$(cat "$STDERR_FILE")
}

json_get() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.argv[1]).get(sys.argv[2])))' "$1" "$2"
}

json_keys() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sorted(json.loads(sys.argv[1]).keys())))' "$1"
}

assert_typed_output() {
  assert_equals '["confidence", "reason", "route", "verdict"]' "$(json_keys "$GUARD_OUT")" "$1: typed output keys"
  assert_equals 0 "$GUARD_RC" "$1: a classified outcome exits 0"
}

# --- a high-confidence safe merge proceeds, over one loopback request --------
reset_log
start_fake --choice safe_merge --confidence 0.97
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "safe merge"
assert_equals '"proceed"' "$(json_get "$GUARD_OUT" verdict)" "a documentation-only merge proceeds"
assert_equals '"safe_merge"' "$(json_get "$GUARD_OUT" route)" "the model route is reported"
assert_equals '"ok"' "$(json_get "$GUARD_OUT" reason)" "a proceed carries a plain reason"
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the key travels as a bearer header"
assert_equals '/v1/systemone' "$(cat "$LOG/path")" "the tool posts to the System One endpoint"
assert_contains "$(cat "$LOG/body")" '"safe_merge"' "the merge rubric options reach the model"
assert_contains "$(cat "$LOG/body")" '"unsafe"' "the unsafe option reaches the model"
assert_not_contains "$(cat "$LOG/body")" 'routine' "the merge rubric does not send dispatch options"
pass "safe merge: proceed, typed JSON, one loopback request"

# --- the same payload from a file behaves identically ------------------------
printf '%s\n' "$MERGE_PAYLOAD" >"$TMP_ROOT/merge.json"
reset_log
start_fake --choice safe_merge --confidence 0.97
run_guard "$API_KEY" "$HOME_DIR" 20 '' --rubric merge "$TMP_ROOT/merge.json"
reap_fake
assert_typed_output "file input"
assert_equals '"proceed"' "$(json_get "$GUARD_OUT" verdict)" "file input proceeds like stdin"
assert_present "$LOG/body" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- low confidence asks the human -------------------------------------------
reset_log
start_fake --choice safe_merge --confidence 0.4
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "low confidence"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "low confidence asks the human"
assert_equals '"safe_merge"' "$(json_get "$GUARD_OUT" route)" "the low-confidence route is still reported"
assert_contains "$(json_get "$GUARD_OUT" reason)" 'below threshold' "the reason names the confidence gap"
pass "low confidence: ask_human"

# --- a high-confidence unsafe answer blocks -----------------------------------
reset_log
start_fake --choice unsafe --confidence 0.95
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "unsafe"
assert_equals '"block"' "$(json_get "$GUARD_OUT" verdict)" "a high-confidence unsafe answer blocks"
assert_equals '"unsafe"' "$(json_get "$GUARD_OUT" route)" "the unsafe route is reported"
pass "high-confidence unsafe: block"

# --- an unsafe answer below the threshold asks instead of blocking ------------
reset_log
start_fake --choice unsafe --confidence 0.4
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "unsafe low confidence"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "an uncertain unsafe answer never blocks"
pass "low-confidence unsafe: ask_human, never block"

# --- a needs_human route asks the human even at high confidence ---------------
reset_log
start_fake --choice needs_human --confidence 0.96
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "needs_human"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "a code change asks the human"
assert_equals '"needs_human"' "$(json_get "$GUARD_OUT" route)" "the needs_human route is reported"
pass "needs_human: ask_human"

# --- an API error asks the human ---------------------------------------------
reset_log
start_fake --status 400
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "api error"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "an API error asks the human"
assert_equals '0.0' "$(json_get "$GUARD_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$GUARD_OUT" reason)" 'api_error' "the reason names the API failure"
pass "API error: ask_human, exit 0"

# --- a malformed success response asks the human ------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "malformed response"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "a malformed success response asks the human"
assert_contains_any "$(json_get "$GUARD_OUT" reason)" "the reason names the core failure" 'core_error' 'defect'
pass "malformed success response: ask_human, exit 0"

# --- the wall-clock bound fails safe and fast ---------------------------------
reset_log
start_fake --choice safe_merge --confidence 0.97 --delay 30
started=$(date +%s)
run_guard "$API_KEY" "$HOME_DIR" 1 "$MERGE_PAYLOAD" --rubric merge -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "the wall-clock bound asks the human"
assert_contains "$(json_get "$GUARD_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: ask_human inside the bound, exit 0"

# --- a non-finite or absurd bound never leaves the call unbounded -------------
# NaN would make `timeout > 0` false and so silently arm nothing, and Infinity
# or a huge finite value overflows the platform timer; each must resolve to the
# fail-safe ask_human inside a finite bound, with no request reaching the
# delayed server.
for bad_timeout in nan inf 1e30; do
  reset_log
  start_fake --choice safe_merge --confidence 0.97 --delay 30
  started=$(date +%s)
  run_guard "$API_KEY" "$HOME_DIR" "$bad_timeout" "$MERGE_PAYLOAD" --rubric merge -
  elapsed=$(( $(date +%s) - started ))
  reap_fake
  assert_typed_output "timeout $bad_timeout"
  assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "timeout $bad_timeout asks the human"
  assert_contains "$(json_get "$GUARD_OUT" reason)" 'fail_safe' "the $bad_timeout reason names the fail-safe"
  assert_absent "$LOG/body" "timeout $bad_timeout never reaches the network"
  [ "$elapsed" -lt 10 ] || fail "timeout $bad_timeout did not return inside a finite bound (elapsed ${elapsed}s)"
  pass "timeout $bad_timeout: fail-safe, finite bound, no request"
done

# --- a missing key fails safe without any network call ------------------------
reset_log
start_fake --choice safe_merge --confidence 0.97
run_guard '' "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "absent key"
assert_equals '"ask_human"' "$(json_get "$GUARD_OUT" verdict)" "a missing key asks the human"
assert_absent "$LOG/body" "a missing key makes no network call"
pass "absent key: ask_human, no network call"

# --- the .env key is used, and the environment wins over it -------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --choice safe_merge --confidence 0.97
run_guard '' "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_typed_output "dotenv key"
assert_equals '"proceed"' "$(json_get "$GUARD_OUT" verdict)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --choice safe_merge --confidence 0.97
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric merge -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- the dispatch rubric, the payload field, and flag precedence --------------
reset_log
start_fake --choice routine --confidence 0.99
run_guard "$API_KEY" "$HOME_DIR" 20 "$DISPATCH_PAYLOAD" -
reap_fake
assert_typed_output "dispatch rubric from the payload"
assert_equals '"proceed"' "$(json_get "$GUARD_OUT" verdict)" "routine work proceeds"
assert_equals '"routine"' "$(json_get "$GUARD_OUT" route)" "the routine route is reported"
assert_contains "$(cat "$LOG/body")" '"routine"' "the dispatch rubric options reach the model"
assert_not_contains "$(cat "$LOG/body")" '"safe_merge"' "the dispatch rubric does not send merge options"
reset_log
start_fake --choice routine --confidence 0.99
run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric dispatch -
reap_fake
assert_equals '"routine"' "$(json_get "$GUARD_OUT" route)" "--rubric overrides the payload rubric field"
assert_not_contains "$(cat "$LOG/body")" '"safe_merge"' "the overriding rubric's options are the ones sent"
pass "dispatch rubric, payload fallback, and --rubric precedence"

# --- usage errors: invalid JSON, unknown or missing rubric, bad input, flags --
reset_log
start_fake --choice safe_merge --confidence 0.97
run_guard "$API_KEY" "$HOME_DIR" 20 '{"rubric": "merge",' --rubric merge -
reap_fake
expect_code 2 "$GUARD_RC" "invalid JSON is a usage error"
assert_equals '' "$GUARD_OUT" "a usage error prints nothing on stdout"
assert_contains "$GUARD_ERR" 'not valid JSON' "the usage error names the invalid JSON"
assert_absent "$LOG/body" "invalid JSON never reaches the network"

run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --rubric bogus -
expect_code 2 "$GUARD_RC" "an unknown rubric is a usage error"
assert_contains "$GUARD_ERR" 'rubric must be one of' "the usage error lists the rubrics"

run_guard "$API_KEY" "$HOME_DIR" 20 '{"action":"do something"}' -
expect_code 2 "$GUARD_RC" "a missing rubric is a usage error"
assert_contains "$GUARD_ERR" 'rubric must be one of' "a missing rubric names the requirement"

run_guard "$API_KEY" "$HOME_DIR" 20 '{"rubric":[]}' -
expect_code 2 "$GUARD_RC" "a non-string rubric is a usage error"
assert_contains "$GUARD_ERR" 'rubric must be one of' "a non-string rubric names the requirement"

run_guard "$API_KEY" "$HOME_DIR" 20 '' --rubric merge "$TMP_ROOT/absent.json"
expect_code 2 "$GUARD_RC" "an unreadable input file is a usage error"
assert_contains "$GUARD_ERR" 'input not readable' "the usage error names the input problem"

run_guard "$API_KEY" "$HOME_DIR" 20 "$MERGE_PAYLOAD" --bogus
expect_code 2 "$GUARD_RC" "an unknown flag is a usage error"
assert_contains "$GUARD_ERR" 'unknown flag --bogus' "the usage error names the flag"
pass "usage errors exit 2 with a named diagnostic and no network call"

GUARD_OUT=$("$TOOL" --help)
GUARD_RC=$?
expect_code 0 "$GUARD_RC" "--help exits 0"
assert_contains "$GUARD_OUT" 'Usage:' "--help prints the usage"
pass "--help exits 0"

printf '# all fm-jev-guard tests passed\n'
