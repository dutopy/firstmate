#!/usr/bin/env bash
# fm-jev-class.sh - typed intelligence-class and effort classifier for the
# dispatch intake, backed by typesafe.ai's System One model (Jev) through the
# shared jev_decide core.
#
# Usage:
#   fm-jev-class.sh [--profiles] [--class <name>] [--effort <name>] [<task-description-file>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_CLASS_CORE:-$FM_HOME/data/jev_decide.py}, imported by path with
#   importlib, so there is exactly one HTTP client and exactly one retry and
#   timeout implementation. This wrapper re-implements neither the client nor
#   TypeSafe's API contract, and it makes no change to the shared core.
#
# Input: the task description as plain text, from a file or from "-" (or no
#   positional argument) for stdin. The whole description is the model's `task`
#   state, and one request asks both questions below at once.
#
# What it decides: the two axes of the captain-approved two-stage router, and
#   nothing else. Stage one only names the intelligence a task needs; live quota
#   and availability stay with quota-axi and quota-array-dispatch, and this tool
#   never sees them. docs/jev-class-router.md owns the two-stage contract, and
#   docs/configuration.md ("Crew dispatch profiles") owns the class-keyed
#   `classes` block that consumes the class.
#   - class:  volume_cheap | standard_impl | hard_reasoning. The rubric is the
#             live-validated one, reused verbatim.
#   - effort: low | medium | high. The lowest effort that is adequate for the
#             task; the deterministic fallback mapping is
#             volume_cheap->low, standard_impl->medium, hard_reasoning->high.
#
# Explicit override: --class and --effort state the value directly, which is how
#   an explicit captain instruction outranks the model's answer. Either one
#   replaces that axis, reports confidence 1.0 because the caller stated it, and
#   is named in `reason`; --class alone answers without any network call.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"class":"<class>","effort":"<low|medium|high>","confidence":<0..1>,"reason":"<text>","flag":<null|"low_confidence"|"api_error">}
#   With --profiles, one additional key follows:
#   "profiles": <declared profile array for that class, or null>
#   `confidence` is the class answer's own confidence. `flag` names the weakest
#   evidence in the pair: null when both answers cleared the floor, or
#   "low_confidence" or "api_error" when either answer was replaced by the
#   fallback. `reason` names every replaced answer.
#
# Fail-safe: a missing or rejected API key, any API or network error, a
#   malformed or out-of-vocabulary response, a confidence that is not a finite
#   number inside 0..1, an unusable FM_JV_CLASS_TIMEOUT value (non-finite,
#   negative, or above the ceiling), a host that cannot arm the bound, the
#   wall-clock bound itself (FM_JV_CLASS_TIMEOUT, default 20s, 0 disables), and
#   any answer below the confidence floor all resolve to the default class plus
#   its mapped effort with exit 0. Dispatch is never blocked by this tool, and
#   stdout is always strict JSON: a non-finite or out-of-range confidence can
#   never reach the output as NaN or Infinity.
#
# Wall-clock bound: one finite deadline is the only wait this tool allows, and an
#   invalid value can neither disable it nor overflow it. The numeric input is
#   checked before it reaches the timer, and arming the timer is itself inside
#   the fail-safe path, so a NaN or infinite timeout is a bounded fail-safe and
#   never an unbounded call.
#
# Exit: 0 for every classified outcome, including both fallbacks. 2 for a usage
#   or environment error (unreadable or empty input, a bad threshold or default
#   class, missing python3, an unreadable shared core, missing jq, or an
#   unreadable or malformed canonical dispatch config on the --profiles path,
#   whose whole `classes` block is validated with the canonical clauses
#   bin/fm-bootstrap.sh applies to it), which prints nothing on stdout and
#   leaves the caller to judge exactly as if this tool were absent.
#
# Environment:
#   FM_JV_CLASS_CORE       shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_CLASS_TIMEOUT    wall-clock bound in seconds (default 20; 0 disables);
#                          must be a finite number in [0, 3600], and anything
#                          else is a fail-safe, never an unbounded call
#   FM_JV_CLASS_THRESHOLD  confidence floor for both answers (default 0.75, the
#                          floor the live router was validated at); must be a
#                          finite number in (0, 1], and anything else is a usage
#                          error
#   FM_JV_CLASS_DEFAULT    class used whenever an answer falls back (default
#                          volume_cheap, the class this home's current default
#                          dispatch belongs to)
#   FM_CONFIG_OVERRIDE     config directory for --profiles (default $FM_HOME/config)
#   TYPESAFE_API_KEY       from this process environment, else a TYPESAFE_API_KEY=
#                          line in $FM_HOME/.env read with fmx_env_get (the
#                          environment wins). The key reaches the one python
#                          child through its environment, because the shared core
#                          reads it there; it never appears on argv and nothing
#                          logs or writes it.
#   TYPESAFE_BASE_URL      passed through to the core (tests point it at loopback)
#
# Authority: advisory. The class feeds the matched profile array; it never
#   overrides an explicit captain instruction, an explicit effort declared in a
#   chosen profile, or quota-array-dispatch's availability and economics gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

CORE="${FM_JV_CLASS_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_CLASS_TIMEOUT:-20}"
THRESHOLD="${FM_JV_CLASS_THRESHOLD:-0.75}"
DEFAULT_CLASS="${FM_JV_CLASS_DEFAULT:-volume_cheap}"

die() { printf 'fm-jev-class: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

WANT_PROFILES=0
FORCED_CLASS=''
FORCED_EFFORT=''
INPUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --profiles) WANT_PROFILES=1; shift ;;
    --class) [ $# -ge 2 ] || die "--class needs a value"; FORCED_CLASS=$2; shift 2 ;;
    --effort) [ $# -ge 2 ] || die "--effort needs a value"; FORCED_EFFORT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -) [ -z "$INPUT" ] || die "one input only"; INPUT='-'; shift ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$INPUT" ] || die "one input only"; INPUT=$1; shift ;;
  esac
done

case "$FORCED_CLASS" in
  ''|volume_cheap|standard_impl|hard_reasoning) ;;
  *) die "--class must be one of volume_cheap, standard_impl, hard_reasoning" ;;
esac
case "$FORCED_EFFORT" in
  ''|low|medium|high) ;;
  *) die "--effort must be one of low, medium, high" ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 required"
if [ "$WANT_PROFILES" = 1 ] && ! command -v jq >/dev/null 2>&1; then
  die "jq required for --profiles"
fi

# The key is resolved once here so the environment layer and the .env layer
# follow the same env-wins rule the rest of the toolbelt uses.
if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  TYPESAFE_API_KEY=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
export TYPESAFE_API_KEY

INPUT_TMP=''
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT/INT/TERM/HUP traps below.
cleanup() { [ -n "$INPUT_TMP" ] && rm -f "$INPUT_TMP"; return 0; }
trap cleanup EXIT INT TERM HUP

if [ -z "$INPUT" ] || [ "$INPUT" = '-' ]; then
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-class.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read the task description from stdin"
  INPUT="$INPUT_TMP"
fi
[ -r "$INPUT" ] || die "task description not readable: $INPUT"

# One JSON array of profiles declared for one class under the canonical
# dispatch config's `classes` block, or null when the file or the class is
# absent. Before anything is looked up the whole `classes` block is validated
# with the canonical clauses, so a malformed canonical object is never selected
# around: the field clauses bin/fm-bootstrap.sh applies (object, known class
# keys, profile object or non-empty array, harness, model, effort, provider,
# floor), the verified-harness vocabulary and effort support from the same
# single owners bin/fm-bootstrap.sh and bin/fm-dispatch-resolve.sh use
# (fm_control_harnesses and the shared effort map), the duplicate-profile check,
# and the provider requirement for a harness with no authoritative single
# provider family.
declared_profiles() {
  local class=$1 file="$CONFIG/crew-dispatch.json" out verified provider harness
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'null'
    return 0
  fi
  [ -r "$file" ] || die "dispatch config not readable: $file"
  command -v jq >/dev/null 2>&1 || die "jq required for --profiles"
  verified=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')
  out=$(jq -c --arg c "$class" --argjson verified_harnesses "$verified" '
    def profiles($v):
      if ($v | type) == "array" then $v
      elif ($v | type) == "object" then [$v]
      else [] end;
    def optional_bad($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)))
      or ($items | any(has("provider") and ((.provider | type) != "string" or ((.provider | test("^[a-z0-9]+(-[a-z0-9]+)*$")) | not))));
    def floor_bad($f):
      ($f | type) != "object"
      or (($f.scope | type) != "string") or (($f.scope | length) == 0)
      or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
      or ($f | has("provider"));
    def floors_bad($items): ($items | any(has("floor") and floor_bad(.floor)));
    def effort_ok($h; $m; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
      elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
      elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
      elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
      elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true end;
    def duplicate_profiles($items):
      ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
      | ($keys | length) != ($keys | unique | length);
    [(.classes // {})[]? | profiles(.)[]?] as $all |
    if (.classes // null) == null then null
    elif (.classes | type) != "object" then error("classes must be an object")
    elif [(.classes // {}) | keys[]? | select(. != "volume_cheap" and . != "standard_impl" and . != "hard_reasoning")] | length > 0 then
      error("unknown class: " + ([(.classes // {}) | keys[]? | select(. != "volume_cheap" and . != "standard_impl" and . != "hard_reasoning")] | unique | join(", ")))
    elif [(.classes // {})[]? | profiles(.) | length] | any(. == 0) then error("each class needs a profile object or non-empty profile array")
    elif [($all[] | select(type != "object"))] | length > 0 then error("each class profile must be an object")
    elif [($all[] | select((.harness? | type) != "string" or (.harness | length) == 0))] | length > 0 then error("each class profile needs harness")
    elif optional_bad($all) then error("class profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present")
    elif floors_bad($all) then error("class profile floor needs scope and min_percent 0..100")
    elif [($all[] | . as $p | select(($verified_harnesses | index($p.harness)) == null))] | length > 0 then
      error("unverified harness: " + ([$all[] | . as $p | select(($verified_harnesses | index($p.harness)) == null) | $p.harness] | unique | join(", ")))
    elif [($all[] | . as $p | select((effort_ok($p.harness; $p.model; $p.effort)) | not))] | length > 0 then
      error("invalid effort: " + ([$all[] | . as $p | select((effort_ok($p.harness; $p.model; $p.effort)) | not) | "\($p.harness):\($p.effort)"] | unique | join(", ")))
    elif any((.classes // {})[]; duplicate_profiles(profiles(.))) then error("each class must not contain duplicate harness, model, and effort profiles")
    elif (.classes[$c] // null) == null then null
    else profiles(.classes[$c])
    end
  ' "$file" 2>&1) || {
    out=$(printf '%s' "$out" | sed -E 's/^jq: error \(at [^)]*\): //')
    die "malformed dispatch config $file - $out"
  }
  # A class profile whose harness has no authoritative single provider family
  # must declare one, exactly as bin/fm-dispatch-resolve.sh requires of every
  # profile it may rank.
  while IFS= read -r harness; do
    [ -n "$harness" ] || continue
    if ! provider=$(fm_quota_single_provider_for_harness "$harness" 2>/dev/null); then
      die "malformed dispatch config $file - class profiles whose harness lacks one authoritative provider family require provider: $harness"
    fi
  done < <(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    (.classes // {})[]? | profiles(.)[]? | select(has("provider") | not) | .harness' "$file" 2>/dev/null)
  printf '%s' "$out"
}

OUT=''
rc=0
OUT=$(python3 - "$CORE" "$THRESHOLD" "$DEFAULT_CLASS" "$TIMEOUT" "$INPUT" "$FORCED_CLASS" "$FORCED_EFFORT" <<'PY'
"""Classify one task through the shared jev_decide core (imported by path)."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import sys

# The class rubric is the live-validated one from the router experiment, reused
# verbatim; the effort rubric is the same doctrine applied to one axis, and the
# deterministic map is the documented fallback for either axis.
CLASSES = {
    "volume_cheap": {
        "what": (
            "High-volume, straightforward, low-risk execution: collection, "
            "structuring, routine edits, simple tests"
        ),
        "not_for": "Hard reasoning, security-sensitive, or architecture decisions",
        "examples": [
            "Extract fields from 200 pages",
            "Rename a variable across files",
            "Run a lint pass",
        ],
    },
    "standard_impl": {
        "what": (
            "Ordinary coding/implementation needing some judgment but not deep "
            "reasoning"
        ),
        "not_for": "Trivial volume work OR difficult multi-factor reasoning",
        "examples": [
            "Implement a REST endpoint with tests",
            "Fix a well-scoped bug",
        ],
    },
    "hard_reasoning": {
        "what": (
            "Genuinely difficult reasoning, architecture, tricky debugging, "
            "security-sensitive design"
        ),
        "not_for": "Routine or volume work",
        "examples": [
            "Design a crash-safe distributed protocol",
            "Diagnose a heisenbug across subsystems",
            "Security review of auth flow",
        ],
    },
}
EFFORTS = {
    "low": {
        "what": (
            "Adequate when the work is well specified and the pattern is "
            "already established: the task can be finished by following it "
            "without weighing alternatives."
        ),
        "not_for": (
            "Work that needs judgment about design, trade-offs, unfamiliar "
            "code, or more than one moving part."
        ),
        "examples": [
            "apply a rote rename across files",
            "run a formatter or lint pass",
            "collect and structure fields from a known source",
        ],
    },
    "medium": {
        "what": (
            "Adequate for ordinary implementation, debugging, or review that "
            "needs real judgment but no deep or multi-factor reasoning."
        ),
        "not_for": (
            "Mechanical repetition, or genuinely hard reasoning where being "
            "wrong is expensive."
        ),
        "examples": [
            "implement a scoped endpoint with tests",
            "fix a reported bug in one subsystem",
            "review a bounded change against its stated intent",
        ],
    },
    "high": {
        "what": (
            "Adequate only when the task needs sustained, multi-factor "
            "reasoning: architecture, subtle cross-subsystem debugging, "
            "security-sensitive design, or work where being wrong is expensive."
        ),
        "not_for": (
            "Routine, volume, or well-scoped work that a lower effort already "
            "covers."
        ),
        "examples": [
            "design a crash-safe distributed protocol",
            "diagnose a heisenbug across subsystems",
            "security review of an authentication flow",
        ],
    },
}
DEFAULT_EFFORT_BY_CLASS = {
    "volume_cheap": "low",
    "standard_impl": "medium",
    "hard_reasoning": "high",
}
QUESTIONS = {
    "class": {
        "type": "choice",
        "instructions": (
            "Read the task description in `task`. Classify this task by the "
            "model class it truly needs (cheapest that meets the bar)."
        ),
        "criteria": CLASSES,
    },
    "effort": {
        "type": "choice",
        "instructions": (
            "Read the task description in `task`. Choose the lowest reasoning "
            "effort that is adequate for it; do not inflate it."
        ),
        "criteria": EFFORTS,
    },
}


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


class Malformed(Exception):
    """The response is not the typed answer this tool asked for."""


def usage_error(message):
    sys.stderr.write("fm-jev-class: %s\n" % message)
    raise SystemExit(2)


def emit(chosen_class, effort, confidence, reason, flag):
    # The boundary already rejects a non-finite or out-of-range confidence, so
    # this is the last-resort guarantee that stdout stays strict JSON and the
    # reported confidence stays a number inside 0..1 on every path.
    value = float(confidence)
    if not math.isfinite(value) or not 0.0 <= value <= 1.0:
        value = 0.0
    payload = {
        "class": chosen_class,
        "effort": effort,
        "confidence": round(value, 4),
        "reason": reason[:400],
        "flag": flag,
    }
    sys.stdout.write(
        json.dumps(payload, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        + "\n"
    )


def _on_alarm(unused_signum, unused_frame):
    raise _Deadline()


def load_core(path):
    if not os.path.isfile(path):
        usage_error("shared core not found: %s" % path)
    spec = importlib.util.spec_from_file_location("fm_jev_decide_core", path)
    if spec is None or spec.loader is None:
        usage_error("cannot import shared core: %s" % path)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so the core's dataclasses and Enums resolve their own
    # module through sys.modules; without this, class creation fails.
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except SystemExit:
        raise
    except BaseException as exc:
        usage_error("cannot load shared core %s: %s" % (path, exc))
    if not hasattr(module, "ask") or not hasattr(module, "TypeSafeError"):
        usage_error("shared core %s does not expose ask()/TypeSafeError" % path)
    return module


def read_task(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        usage_error("task description not readable: %s" % exc)
    except ValueError as exc:
        usage_error("task description is not valid UTF-8 text: %s" % exc)
    if not text.strip():
        usage_error("the task description is empty")
    return text


MAX_TIMEOUT_SECONDS = 3600.0


def parse_threshold(raw):
    """The confidence floor as a finite number in (0, 1], or a usage error.

    A zero, negative, non-finite, or above-one floor is a misconfiguration, and
    a NaN floor in particular would make every `confidence >= threshold` test
    false; each is refused here rather than silently changing the rubric.
    """
    try:
        value = float(raw)
    except (TypeError, ValueError):
        usage_error("FM_JV_CLASS_THRESHOLD is not a number: %s" % raw)
    if not math.isfinite(value) or not 0.0 < value <= 1.0:
        usage_error(
            "FM_JV_CLASS_THRESHOLD must be a finite number in (0, 1]: %s" % raw
        )
    return value


def parse_timeout(raw):
    """The wall-clock bound as a finite number of seconds in [0, MAX].

    0 keeps its documented meaning of "no bound". NaN, the infinities, a
    negative value, and an absurd value are rejected here, before they can
    reach the timer, so an unusable bound can neither silently disable the
    timer nor overflow it; the caller turns this error into the fail-safe
    outcome without making any request.
    """
    try:
        timeout = float(raw)
    except (TypeError, ValueError):
        raise ValueError("timeout must be a finite number of seconds") from None
    if not math.isfinite(timeout) or timeout < 0 or timeout > MAX_TIMEOUT_SECONDS:
        raise ValueError(
            "timeout must be a finite number of seconds no greater than %g"
            % MAX_TIMEOUT_SECONDS
        )
    return timeout


def arm_deadline(timeout):
    """Arm the one wall-clock bound, or raise when this host cannot arm it.

    parse_timeout has already guaranteed a finite, non-negative value, so the
    timer can neither be disabled by NaN nor overflowed by infinity; a platform
    that still cannot represent the bound raises here, and the caller turns that
    into the fail-safe outcome instead of an unbounded or crashed run.
    """
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)


def clear_deadline():
    """Disarm the wall-clock bound."""
    signal.setitimer(signal.ITIMER_REAL, 0)


def answer_of(response, key):
    answers = response.get("answers") if isinstance(response, dict) else None
    if not isinstance(answers, dict):
        raise Malformed("no answers object")
    entry = answers.get(key)
    if not isinstance(entry, dict):
        raise Malformed("no %s answer" % key)
    choice = entry.get("choice")
    confidence = entry.get("confidence")
    if not isinstance(choice, str):
        raise Malformed("%s answer has no choice" % key)
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        raise Malformed("%s answer has no numeric confidence" % key)
    confidence = float(confidence)
    if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
        raise Malformed("%s confidence %r is not a finite number inside 0..1" % (key, confidence))
    return choice, confidence


def show(value):
    return ("%g" % value) if isinstance(value, float) else str(value)


def main(argv):
    (
        core_path,
        threshold_raw,
        default_class,
        timeout_raw,
        input_path,
        forced_class,
        forced_effort,
    ) = argv[1:8]
    if default_class not in DEFAULT_EFFORT_BY_CLASS:
        usage_error(
            "FM_JV_CLASS_DEFAULT must be one of %s"
            % ", ".join(sorted(DEFAULT_EFFORT_BY_CLASS))
        )
    if forced_class and forced_class not in CLASSES:
        usage_error("--class must be one of %s" % ", ".join(sorted(CLASSES)))
    if forced_effort and forced_effort not in EFFORTS:
        usage_error("--effort must be one of %s" % ", ".join(sorted(EFFORTS)))
    threshold = parse_threshold(threshold_raw)
    core = load_core(core_path)
    text = read_task(input_path)

    def fallback(flag, reason):
        emit(default_class, DEFAULT_EFFORT_BY_CLASS[default_class], 0.0, reason, flag)
        return 0

    if forced_class:
        effort = forced_effort or DEFAULT_EFFORT_BY_CLASS[forced_class]
        emit(
            forced_class,
            effort,
            1.0,
            "explicit override: class %s, effort %s" % (forced_class, effort),
            None,
        )
        return 0

    try:
        timeout = parse_timeout(timeout_raw)
    except ValueError as exc:
        return fallback("api_error", "fail_safe: %s" % exc)

    if timeout > 0:
        try:
            arm_deadline(timeout)
        except Exception as exc:
            return fallback(
                "api_error",
                "fail_safe: could not arm the %ss wall-clock bound: %s: %s"
                % (timeout, type(exc).__name__, exc),
            )
    try:
        try:
            response = core.ask({"task": text}, QUESTIONS)
        finally:
            if timeout > 0:
                clear_deadline()
    except _Deadline:
        return fallback("api_error", "timeout: no answer within %ss" % show(timeout))
    except Exception as exc:
        detail = str(exc) if isinstance(exc, core.TypeSafeError) else "%s: %s" % (type(exc).__name__, exc)
        return fallback("api_error", "api_error: %s" % detail)

    try:
        class_choice, class_confidence = answer_of(response, "class")
        effort_choice, effort_confidence = answer_of(response, "effort")
    except Malformed as exc:
        return fallback("api_error", "malformed response: %s" % exc)
    if class_choice not in CLASSES:
        return fallback("api_error", "malformed response: unknown class %r" % (class_choice,))
    if effort_choice not in EFFORTS:
        return fallback("api_error", "malformed response: unknown effort %r" % (effort_choice,))

    notes = []
    degraded = False
    if class_confidence >= threshold:
        chosen_class = class_choice
    else:
        chosen_class = default_class
        degraded = True
        notes.append(
            "class %s at confidence %s is below the %s floor; using the default class %s"
            % (class_choice, show(class_confidence), show(threshold), default_class)
        )
    mapped_effort = DEFAULT_EFFORT_BY_CLASS[chosen_class]
    if forced_effort:
        chosen_effort = forced_effort
        notes.append("explicit override: effort %s" % forced_effort)
    elif not degraded and effort_confidence >= threshold:
        chosen_effort = effort_choice
    else:
        chosen_effort = mapped_effort
        if effort_confidence >= threshold:
            notes.append(
                "the class fallback selects the %s effort for class %s"
                % (chosen_effort, chosen_class)
            )
        else:
            degraded = True
            notes.append(
                "effort %s at confidence %s is below the %s floor; using %s for class %s"
                % (
                    effort_choice,
                    show(effort_confidence),
                    show(threshold),
                    chosen_effort,
                    chosen_class,
                )
            )
    emit(
        chosen_class,
        chosen_effort,
        class_confidence,
        "ok" if not notes else "; ".join(notes),
        "low_confidence" if degraded else None,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
) || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

if [ "$WANT_PROFILES" = 1 ]; then
  CLASS=$(printf '%s' "$OUT" | jq -r '.class') || die "could not read the resolved class"
  PROFILES=$(declared_profiles "$CLASS") || exit "$?"
  OUT=$(printf '%s' "$OUT" | jq -c --argjson p "$PROFILES" '. + {profiles: $p}') \
    || die "could not attach the declared class profiles"
fi

printf '%s\n' "$OUT"
