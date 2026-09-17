#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-class.sh.
#
# Drives the public argv/stdin/environment interface against
# tests/assets/jev-class-fake-typesafe.py, a fake typesafe.ai System One server
# bound to 127.0.0.1 on an ephemeral port. Cases cover the three intelligence
# classes with their efforts, an atomic single request for both questions, the
# low-confidence fallback on either axis and on both, an API error, a malformed
# success response, an out-of-vocabulary answer, the wall-clock fallback, a
# missing key, the .env key fallback (and the environment winning over it), the
# explicit class and effort overrides, the class-keyed dispatch config lookup,
# and the usage errors. Every request goes to that loopback server, so no case
# reaches the real network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-class.sh"
FAKE_SERVER="$ROOT/tests/assets/jev-class-fake-typesafe.py"
SHARED_CORE=${FM_JV_CLASS_CORE:-/home/dutopy/atelier/data/jev_decide.py}

command -v python3 >/dev/null 2>&1 || {
  echo "skip: python3 is not installed, and bin/fm-jev-class.sh requires it"
  exit 0
}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_CLASS_CORE to run this suite)"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-jev-class)
HOME_DIR="$TMP_ROOT/home"
CONFIG_DIR="$TMP_ROOT/config"
LOG="$TMP_ROOT/log"
STDERR_FILE="$TMP_ROOT/stderr"
mkdir -p "$HOME_DIR/data" "$CONFIG_DIR" "$LOG"
# The tool's documented default core path is $FM_HOME/data/jev_decide.py, so the
# fixture home carries the real shared core by that name and every case
# exercises the default resolution.
ln -s "$SHARED_CORE" "$HOME_DIR/data/jev_decide.py"

API_KEY='test-key-7b2c-never-on-argv'
TASK='Implement a REST endpoint with tests'

BASE=''
FAKE_PID=''
CLASS_OUT=''
CLASS_RC=''
CLASS_ERR=''

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

# run_class <key> <home> <timeout> <task> [tool args...]: <task> is piped to the
# tool, and stays unused by the cases that read an input file instead.
run_class() {
  local key=$1 home=$2 timeout=$3 task=$4 _out _rc
  shift 4
  _out=$(printf '%s' "$task" | TYPESAFE_API_KEY="$key" FM_HOME="$home" \
    FM_JV_CLASS_TIMEOUT="$timeout" FM_CONFIG_OVERRIDE="$CONFIG_DIR" \
    TYPESAFE_BASE_URL="$BASE" "$TOOL" "$@" 2>"$STDERR_FILE")
  _rc=$?
  CLASS_OUT=$_out
  CLASS_RC=$_rc
  CLASS_ERR=$(cat "$STDERR_FILE")
}

json_get() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.loads(sys.argv[1]).get(sys.argv[2])))' "$1" "$2"
}

json_keys() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sorted(json.loads(sys.argv[1]).keys())))' "$1"
}

# Prove stdout is strict JSON: a non-finite JSON constant (NaN, Infinity) is a
# parse error rather than a silently accepted value, and the reported confidence
# is a number inside 0..1.
assert_strict_json() {
  python3 -c '
import json, sys

def reject(value):
    raise SystemExit("non-finite JSON constant in output: %s" % value)

payload = json.loads(sys.argv[1], parse_constant=reject)
confidence = payload.get("confidence")
if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
    raise SystemExit("confidence is not a number: %r" % (confidence,))
if not 0.0 <= confidence <= 1.0:
    raise SystemExit("confidence is outside 0..1: %r" % (confidence,))
' "$1"
}

body_json() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(json.load(open(sys.argv[1], encoding="utf-8"))))' "$1"
}

assert_typed_output() {
  assert_equals '["class", "confidence", "effort", "flag", "reason"]' "$(json_keys "$CLASS_OUT")" "$1: typed output keys"
  assert_equals 0 "$CLASS_RC" "$1: a classified outcome exits 0"
}

assert_atomic_request() {
  assert_equals 1 "$(wc -l <"$LOG/count" | tr -d ' ')" "$1: exactly one request"
  assert_equals '"object"' "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); s=d.get("state"); sys.stdout.write(json.dumps("object" if isinstance(s, dict) else type(s).__name__))' "$LOG/body")" "$1: the state is an object, never a list"
  assert_contains "$(body_json "$LOG/body")" '"questions"' "$1: the request carries the questions"
  assert_contains "$(body_json "$LOG/body")" '"class"' "$1: the class question is asked"
  assert_contains "$(body_json "$LOG/body")" '"effort"' "$1: the effort question is asked"
  assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "$1: the key travels as a bearer header"
  assert_equals '/v1/systemone' "$(cat "$LOG/path")" "$1: the tool posts to the System One endpoint"
}

# --- the three classes, each with its own effort, one atomic request each ----
for row in 'volume_cheap:low' 'standard_impl:medium' 'hard_reasoning:high'; do
  want_class=${row%%:*}
  want_effort=${row##*:}
  reset_log
  start_fake --class-choice "$want_class" --class-confidence 0.97 \
    --effort-choice "$want_effort" --effort-confidence 0.95
  run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
  reap_fake
  assert_typed_output "$want_class"
  assert_equals "\"$want_class\"" "$(json_get "$CLASS_OUT" class)" "$want_class is classified"
  assert_equals "\"$want_effort\"" "$(json_get "$CLASS_OUT" effort)" "$want_class carries the $want_effort effort"
  assert_equals 'null' "$(json_get "$CLASS_OUT" flag)" "a confident pair carries no flag"
  assert_equals '"ok"' "$(json_get "$CLASS_OUT" reason)" "a confident pair carries a plain reason"
  assert_atomic_request "$want_class"
done
assert_contains "$(cat "$LOG/body")" '"volume_cheap"' "the class rubric option reaches the model"
assert_contains "$(cat "$LOG/body")" '"hard_reasoning"' "the hard-reasoning rubric option reaches the model"
assert_contains "$(cat "$LOG/body")" 'not_for' "the rubric keeps its not_for contrast"
pass "three classes: typed class and effort from one atomic request"

# --- the task description reaches the model as text ---------------------------
reset_log
start_fake --class-choice volume_cheap --class-confidence 0.97
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_contains "$(body_json "$LOG/body")" "$TASK" "the task description is the model state"
pass "the task description is sent as the model state"

# --- the same description from a file behaves identically --------------------
printf '%s\n' "$TASK" >"$TMP_ROOT/task.txt"
reset_log
start_fake --class-choice standard_impl --class-confidence 0.9 --effort-choice medium --effort-confidence 0.9
run_class "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/task.txt"
reap_fake
assert_typed_output "file input"
assert_equals '"standard_impl"' "$(json_get "$CLASS_OUT" class)" "file input classifies like stdin"
assert_present "$LOG/body" "file input reaches the API"
pass "file input behaves exactly like stdin"

# --- low confidence on both axes falls back to the default class --------------
reset_log
start_fake --class-choice hard_reasoning --class-confidence 0.4 --effort-choice high --effort-confidence 0.4
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_typed_output "low confidence"
assert_equals '"volume_cheap"' "$(json_get "$CLASS_OUT" class)" "a low-confidence class falls back to the default class"
assert_equals '"low"' "$(json_get "$CLASS_OUT" effort)" "the mapped effort follows the default class"
assert_equals '"low_confidence"' "$(json_get "$CLASS_OUT" flag)" "the fallback is flagged"
assert_contains "$(json_get "$CLASS_OUT" reason)" 'below the 0.75 floor' "the reason names the confidence floor"
assert_contains "$(json_get "$CLASS_OUT" reason)" 'hard_reasoning' "the reason names the answer it replaced"
pass "low confidence on both axes: default class, mapped effort, low_confidence flag"

# --- low confidence on the class alone maps the effort too -------------------
reset_log
start_fake --class-choice hard_reasoning --class-confidence 0.4 --effort-choice low --effort-confidence 0.99
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_equals '"volume_cheap"' "$(json_get "$CLASS_OUT" class)" "the class fallback wins"
assert_equals '"low"' "$(json_get "$CLASS_OUT" effort)" "the class fallback selects its mapped effort"
assert_equals '"low_confidence"' "$(json_get "$CLASS_OUT" flag)" "the class fallback is flagged"
pass "class fallback: mapped effort, flagged"

# --- low confidence on the effort alone keeps the class ----------------------
reset_log
start_fake --class-choice hard_reasoning --class-confidence 0.97 --effort-choice low --effort-confidence 0.4
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_equals '"hard_reasoning"' "$(json_get "$CLASS_OUT" class)" "a confident class is kept"
assert_equals '"high"' "$(json_get "$CLASS_OUT" effort)" "the low-confidence effort falls back to the class mapping"
assert_equals '"low_confidence"' "$(json_get "$CLASS_OUT" flag)" "the effort fallback is flagged"
assert_contains "$(json_get "$CLASS_OUT" reason)" 'effort low' "the reason names the effort it replaced"
pass "effort fallback: class kept, mapped effort, flagged"

# --- an API error falls back on both axes ------------------------------------
reset_log
start_fake --status 500
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_typed_output "api error"
assert_equals '"volume_cheap"' "$(json_get "$CLASS_OUT" class)" "an API error falls back to the default class"
assert_equals '"low"' "$(json_get "$CLASS_OUT" effort)" "an API error falls back to the mapped effort"
assert_equals '"api_error"' "$(json_get "$CLASS_OUT" flag)" "the API error is flagged"
assert_equals '0.0' "$(json_get "$CLASS_OUT" confidence)" "a failed call reports zero confidence"
assert_contains "$(json_get "$CLASS_OUT" reason)" 'api_error: HTTP 500' "the reason names the API failure"
pass "API error: default class and effort, api_error flag, exit 0"

# --- a malformed success response falls back ----------------------------------
printf '{}' >"$TMP_ROOT/malformed.json"

check_malformed() {
  local label=$1
  shift
  reset_log
  start_fake "$@"
  run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
  reap_fake
  assert_typed_output "$label"
  assert_equals '"volume_cheap"' "$(json_get "$CLASS_OUT" class)" "$label falls back to the default class"
  assert_equals '"api_error"' "$(json_get "$CLASS_OUT" flag)" "$label is flagged as an API-level failure"
  pass "$label: default class and effort, api_error flag"
}

check_malformed "a dropped answer" --drop effort
check_malformed "an unknown class option" --class-choice bogus_class
check_malformed "an unknown effort option" --effort-choice bogus_effort
reset_log
start_fake --body-file "$TMP_ROOT/malformed.json"
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_typed_output "no answers object"
assert_equals '"api_error"' "$(json_get "$CLASS_OUT" flag)" "an answerless response is flagged"
pass "answerless success response: default class and effort, api_error flag"

# --- a confidence that is not a finite number inside 0..1 falls back ---------
check_invalid_confidence() {
  local label=$1
  shift
  reset_log
  start_fake "$@"
  run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
  reap_fake
  assert_typed_output "$label"
  assert_strict_json "$CLASS_OUT" || fail "$label: stdout is not strict JSON with a confidence inside 0..1"
  assert_equals '"volume_cheap"' "$(json_get "$CLASS_OUT" class)" "$label falls back to the default class"
  assert_equals '"low"' "$(json_get "$CLASS_OUT" effort)" "$label falls back to the mapped effort"
  assert_equals '"api_error"' "$(json_get "$CLASS_OUT" flag)" "$label is flagged"
  assert_equals '0.0' "$(json_get "$CLASS_OUT" confidence)" "$label reports zero confidence"
  assert_contains "$(json_get "$CLASS_OUT" reason)" 'malformed response' "$label names the malformed answer"
  pass "$label: default class and effort, api_error flag, strict JSON"
}

check_invalid_confidence "NaN class confidence" --class-choice hard_reasoning --class-confidence-raw NaN
check_invalid_confidence "Infinity class confidence" --class-choice hard_reasoning --class-confidence-raw Infinity
check_invalid_confidence "negative class confidence" --class-choice hard_reasoning --class-confidence -0.1
check_invalid_confidence "class confidence above one" --class-choice hard_reasoning --class-confidence 1.1
check_invalid_confidence "NaN effort confidence" --effort-confidence-raw NaN
check_invalid_confidence "Infinity effort confidence" --effort-choice high --effort-confidence-raw=-Infinity
check_invalid_confidence "negative effort confidence" --effort-choice high --effort-confidence -0.1
check_invalid_confidence "effort confidence above one" --effort-choice high --effort-confidence 1.1

# --- the wall-clock bound fails safe and fast --------------------------------
reset_log
start_fake --class-choice volume_cheap --class-confidence 0.97 --delay 30
started=$(date +%s)
run_class "$API_KEY" "$HOME_DIR" 1 "$TASK" -
elapsed=$(( $(date +%s) - started ))
reap_fake
assert_typed_output "timeout"
assert_equals '"api_error"' "$(json_get "$CLASS_OUT" flag)" "the wall-clock bound is flagged"
assert_contains "$(json_get "$CLASS_OUT" reason)" 'timeout' "the reason names the timeout"
[ "$elapsed" -lt 20 ] || fail "the wall-clock bound did not fire (elapsed ${elapsed}s)"
pass "timeout: default class and effort, api_error flag, inside the bound"

# --- a missing key fails safe without any network call -----------------------
reset_log
start_fake --class-choice volume_cheap --class-confidence 0.97
run_class '' "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_typed_output "absent key"
assert_equals '"api_error"' "$(json_get "$CLASS_OUT" flag)" "a missing key is flagged"
assert_absent "$LOG/body" "a missing key makes no network call"
pass "absent key: default class and effort, no network call"

# --- the .env key is used, and the environment wins over it ------------------
printf 'TYPESAFE_API_KEY=from-dotenv\n' >"$HOME_DIR/.env"
reset_log
start_fake --class-choice standard_impl --class-confidence 0.95 --effort-choice medium --effort-confidence 0.95
run_class '' "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_equals '"standard_impl"' "$(json_get "$CLASS_OUT" class)" "the .env key classifies normally"
assert_equals 'Bearer from-dotenv' "$(cat "$LOG/auth")" "the .env key reaches the API"
reset_log
start_fake --class-choice standard_impl --class-confidence 0.95 --effort-choice medium --effort-confidence 0.95
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" -
reap_fake
assert_equals "Bearer $API_KEY" "$(cat "$LOG/auth")" "the environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass ".env key fallback with the environment winning"

# --- an explicit captain override outranks the model -------------------------
reset_log
start_fake --class-choice volume_cheap --class-confidence 0.97 --effort-choice low --effort-confidence 0.97
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --class hard_reasoning -
reap_fake
assert_typed_output "explicit class"
assert_equals '"hard_reasoning"' "$(json_get "$CLASS_OUT" class)" "--class outranks the model's class"
assert_equals '"high"' "$(json_get "$CLASS_OUT" effort)" "--class alone carries its mapped effort"
assert_equals '"explicit override: class hard_reasoning, effort high"' "$(json_get "$CLASS_OUT" reason)" "the override is named in the reason"
assert_absent "$LOG/body" "--class alone answers without any network call"

reset_log
start_fake --class-choice volume_cheap --class-confidence 0.97 --effort-choice low --effort-confidence 0.97
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --effort high -
reap_fake
assert_equals '"volume_cheap"' "$(json_get "$CLASS_OUT" class)" "--effort keeps the model's class"
assert_equals '"high"' "$(json_get "$CLASS_OUT" effort)" "--effort outranks the model's effort"
assert_equals 'null' "$(json_get "$CLASS_OUT" flag)" "an explicit override is not degraded evidence"
assert_contains "$(json_get "$CLASS_OUT" reason)" 'explicit override: effort high' "the effort override is named"
pass "explicit --class and --effort outrank the model"

# --- the class-keyed dispatch config lookup ----------------------------------
printf '%s\n' '{"classes":{"standard_impl":[{"harness":"pi","model":"openai-codex/gpt-5.6-luna","effort":"medium","provider":"codex"},{"harness":"claude","model":"claude-sonnet-5","effort":"medium"}],"hard_reasoning":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"high","provider":"codex"}},"default":{"harness":"pi","effort":"medium"}}' >"$CONFIG_DIR/crew-dispatch.json"
reset_log
start_fake --class-choice standard_impl --class-confidence 0.95 --effort-choice medium --effort-confidence 0.95
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --profiles -
reap_fake
assert_equals '[{"harness": "pi", "model": "openai-codex/gpt-5.6-luna", "effort": "medium", "provider": "codex"}, {"harness": "claude", "model": "claude-sonnet-5", "effort": "medium"}]' \
  "$(json_get "$CLASS_OUT" profiles)" "--profiles attaches the declared class array"
assert_equals '["class", "confidence", "effort", "flag", "profiles", "reason"]' "$(json_keys "$CLASS_OUT")" "--profiles adds exactly one key"
assert_equals 1 "$(wc -l <"$LOG/count" | tr -d ' ')" "the config lookup adds no model request"

reset_log
start_fake --class-choice volume_cheap --class-confidence 0.95 --effort-choice low --effort-confidence 0.95
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --profiles -
reap_fake
assert_equals 'null' "$(json_get "$CLASS_OUT" profiles)" "a class with no declared profiles yields null"
assert_equals 0 "$CLASS_RC" "an undeclared class is not an error"

printf '%s\n' '{"default":{"harness":"pi"}}' >"$CONFIG_DIR/crew-dispatch.json"
reset_log
start_fake --class-choice standard_impl --class-confidence 0.95 --effort-choice medium --effort-confidence 0.95
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --profiles -
reap_fake
assert_equals 'null' "$(json_get "$CLASS_OUT" profiles)" "a default-only config yields null class profiles"

printf '%s\n' '{"classes":{"standard_impl":{"model":"gpt-5.6-luna"}}}' >"$CONFIG_DIR/crew-dispatch.json"
reset_log
start_fake --class-choice standard_impl --class-confidence 0.95 --effort-choice medium --effort-confidence 0.95
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --profiles -
reap_fake
expect_code 2 "$CLASS_RC" "a class profile without harness is a configuration error"
assert_equals '' "$CLASS_OUT" "the configuration error prints nothing on stdout"
assert_contains "$CLASS_ERR" 'each class profile needs harness' "the configuration error names the defect"

# The whole `classes` block is validated canonically before any lookup, so a
# defect anywhere in it is refused rather than selected around.
check_bad_config() {
  local label=$1 body=$2 want=$3
  reset_log
  printf '%s\n' "$body" >"$CONFIG_DIR/crew-dispatch.json"
  start_fake --class-choice volume_cheap --class-confidence 0.95 --effort-choice low --effort-confidence 0.95
  run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --profiles -
  reap_fake
  expect_code 2 "$CLASS_RC" "$label is refused"
  assert_equals '' "$CLASS_OUT" "$label prints nothing on stdout"
  assert_contains "$CLASS_ERR" "$want" "$label names the defect"
}

check_bad_config "an unknown class key" '{"classes":{"typo":{"harness":"pi"}}}' 'unknown class: typo'
check_bad_config "a malformed model in another class" '{"classes":{"volume_cheap":{"harness":"pi","model":"zai/glm-5.3-flash"},"hard_reasoning":{"harness":"claude","model":5}}}' 'class profile model and effort must be non-empty strings'
check_bad_config "a malformed provider" '{"classes":{"volume_cheap":{"harness":"pi","provider":"ZAI"}}}' 'class profile model and effort must be non-empty strings'
check_bad_config "a malformed profile floor" '{"classes":{"volume_cheap":{"harness":"pi","floor":{"scope":"all_models"}}}}' 'class profile floor needs scope and min_percent 0..100'
check_bad_config "classes that are not an object" '{"classes":[]}' 'classes must be an object'
check_bad_config "an empty class profile array" '{"classes":{"volume_cheap":[]}}' 'each class needs a profile object or non-empty profile array'
check_bad_config "a profile floor naming its own provider" '{"classes":{"volume_cheap":{"harness":"pi","floor":{"scope":"all_models","min_percent":50,"provider":"zai"}}}}' 'class profile floor needs scope and min_percent 0..100'
check_bad_config "an unverified harness" '{"classes":{"volume_cheap":{"harness":"spaceship"}}}' 'unverified harness: spaceship'
check_bad_config "an effort the harness does not support" '{"classes":{"volume_cheap":{"harness":"grok","effort":"max"}}}' 'invalid effort: grok:max'
check_bad_config "duplicate class profiles" '{"classes":{"volume_cheap":[{"harness":"cursor","model":"cursor-grok-4.6-medium"},{"harness":"cursor","model":"cursor-grok-4.6-medium"}]}}' 'each class must not contain duplicate harness, model, and effort profiles'
check_bad_config "a harness with no authoritative provider family" '{"classes":{"volume_cheap":{"harness":"pi"}}}' 'class profiles whose harness lacks one authoritative provider family require provider: pi'

printf '%s\n' '{"classes":{"standard_impl":[{"harness":"pi"}]' >"$CONFIG_DIR/crew-dispatch.json"
run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --profiles -
expect_code 2 "$CLASS_RC" "an invalid JSON config is a configuration error"
assert_contains "$CLASS_ERR" 'malformed dispatch config' "the invalid JSON is named"
rm -f "$CONFIG_DIR/crew-dispatch.json"
pass "class-keyed config lookup, plus its configuration errors"

# --- usage errors: empty input, unreadable file, bad flags and settings ------
reset_log
start_fake --class-choice volume_cheap --class-confidence 0.97
run_class "$API_KEY" "$HOME_DIR" 20 '' -
reap_fake
expect_code 2 "$CLASS_RC" "an empty task description is a usage error"
assert_equals '' "$CLASS_OUT" "a usage error prints nothing on stdout"
assert_contains "$CLASS_ERR" 'empty' "the usage error names the empty input"
assert_absent "$LOG/body" "an empty description never reaches the network"

run_class "$API_KEY" "$HOME_DIR" 20 '' "$TMP_ROOT/absent.txt"
expect_code 2 "$CLASS_RC" "an unreadable task file is a usage error"
assert_contains "$CLASS_ERR" 'not readable' "the usage error names the input problem"

run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --class spaceship -
expect_code 2 "$CLASS_RC" "an unknown --class value is a usage error"
assert_contains "$CLASS_ERR" '--class must be one of' "the usage error lists the classes"

run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --effort ultra -
expect_code 2 "$CLASS_RC" "an unknown --effort value is a usage error"
assert_contains "$CLASS_ERR" '--effort must be one of' "the usage error lists the efforts"

run_class "$API_KEY" "$HOME_DIR" 20 "$TASK" --bogus
expect_code 2 "$CLASS_RC" "an unknown flag is a usage error"
assert_contains "$CLASS_ERR" 'unknown flag --bogus' "the usage error names the flag"

CLASS_OUT=$(printf '%s' "$TASK" | TYPESAFE_API_KEY="$API_KEY" FM_HOME="$HOME_DIR" \
  FM_JV_CLASS_THRESHOLD=high bash "$TOOL" - 2>"$STDERR_FILE")
CLASS_RC=$?
CLASS_ERR=$(cat "$STDERR_FILE")
expect_code 2 "$CLASS_RC" "a non-numeric threshold is a usage error"
assert_contains "$CLASS_ERR" 'FM_JV_CLASS_THRESHOLD' "the usage error names the threshold"

CLASS_OUT=$(printf '%s' "$TASK" | TYPESAFE_API_KEY="$API_KEY" FM_HOME="$HOME_DIR" \
  FM_JV_CLASS_DEFAULT=spaceship bash "$TOOL" - 2>"$STDERR_FILE")
CLASS_RC=$?
CLASS_ERR=$(cat "$STDERR_FILE")
expect_code 2 "$CLASS_RC" "an unknown default class is a usage error"
assert_contains "$CLASS_ERR" 'FM_JV_CLASS_DEFAULT must be one of' "the usage error lists the default classes"
pass "usage errors exit 2 with a named diagnostic and no network call"

CLASS_OUT=$("$TOOL" --help)
CLASS_RC=$?
expect_code 0 "$CLASS_RC" "--help exits 0"
assert_contains "$CLASS_OUT" 'Usage:' "--help prints the usage"
pass "--help exits 0"

printf '# all fm-jev-class tests passed\n'
