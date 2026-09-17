#!/usr/bin/env bash
# fm-jev-finding.sh - advisory, fail-safe severity classifier for one review
# finding, backed by typesafe.ai's System One model (Jev) through the shared
# jev_decide core.
#
# Usage:
#   fm-jev-finding.sh [<finding.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_FINDING_CORE:-$FM_HOME/data/jev_decide.py}, imported by path with
#   importlib, so there is exactly one HTTP client and exactly one confidence
#   gate. This wrapper re-implements neither the client nor TypeSafe's API
#   contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing a single review finding, from a file
#   or from "-" (or no positional argument) for stdin. The whole object is the
#   model's `state`; recommended fields are `title` (the finding's headline),
#   `description` (the finding's body), and `context` (any extra evidence such
#   as the diff, the brief, or the reviewer's note). Never pass a list of
#   findings: this tool answers for exactly one finding per call.
#
# One atomic question: a single forced-choice question asks the model to place
#   the finding in exactly one severity. The tool never sends a state list and
#   never asks the model to rank or order several findings at once.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"severity":"blocking|important|cosmetic","confidence":<0..1>,"reason":"<text>","flag":"<action>"}
#   The `flag` is the advisory action for the severity:
#     fix_now          - blocking; the single correction batch must fix it.
#     fix_in_batch     - important; the same single batch fixes it.
#     optional_polish  - cosmetic; listed in the batch, and may be deferred
#                        without another review round.
#     needs_review     - no usable severity (confidence below the floor, or any
#                        fail-safe path). Severity is the conservative default
#                        `important`; the finding stays in the batch for the
#                        reviewer to judge, and is never dropped.
#
# Fail-safe: every path that produced no usable severity - confidence below 0.9,
#   a confidence the model reports outside the finite 0..1 range (non-finite,
#   negative, or above 1), a missing or rejected API key, any API or network
#   error, a malformed success response, an unreadable shared core, an unusable
#   FM_JV_FINDING_TIMEOUT value (non-finite, negative, or above the ceiling), a
#   host that cannot arm the bound, or the wall-clock bound itself
#   (FM_JV_FINDING_TIMEOUT, default 20s) - resolves to severity important, flag
#   needs_review, exit 0, with the specific cause named in `reason`. There is no
#   silent drop: every finding comes back with a typed severity to batch, and the
#   emitted confidence is always a finite number in [0, 1] in strict JSON, so a
#   NaN or Infinity answer can never slip past the confidence floor and can never
#   reach stdout.
#
# Wall-clock bound: one finite deadline is the only wait this tool allows, and an
#   invalid value can neither disable it nor overflow it. The numeric input is
#   checked before it reaches the timer, and arming the timer is itself inside
#   the fail-safe path, so a NaN or infinite timeout is a bounded fail-safe and
#   never an unbounded call.
#
# Exit: 0 for every classified outcome, including every fail-safe. 2 for a usage
#   error: an unknown flag, a missing flag value, missing python3, an unreadable
#   input file, input that is not valid JSON, input that is not a JSON object,
#   or input that carries no finding text at all. A usage error prints nothing
#   on stdout, makes no network call, and leaves the caller to judge the finding
#   exactly as if this classifier were absent. A usage error is a caller
#   mistake, never a finding's severity, so an empty or malformed finding is
#   reported loudly to the caller instead of being given a default.
#
# Environment:
#   FM_JV_FINDING_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_FINDING_TIMEOUT  wall-clock bound in seconds (default 20; 0 disables);
#                          must be a finite number in [0, 3600], and anything
#                          else is a fail-safe, never an unbounded call
#   TYPESAFE_API_KEY       from this process environment, else a TYPESAFE_API_KEY=
#                          line in $FM_HOME/.env read with fmx_env_get (the
#                          environment wins). The key reaches the one python
#                          child through its environment, because the shared
#                          core reads it there; it never appears on argv and
#                          nothing logs or writes it.
#   TYPESAFE_BASE_URL      passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never decides a finding in place of the
#   reviewer or the captain, never closes or answers a finding, never trims the
#   finding list, and is not run on every tool call. docs/jev-guard.md owns the
#   rubric, the one-batch usage, and the precedence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_FINDING_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_FINDING_TIMEOUT:-20}"

die() { printf 'fm-jev-finding: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

INPUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -) [ -z "$INPUT" ] || die "one input only"; INPUT='-'; shift ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$INPUT" ] || die "one input only"; INPUT=$1; shift ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 required"

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
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-finding.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
python3 - "$CORE" "$INPUT" "$TIMEOUT" <<'PY' || rc=$?
"""Classify one review finding's severity through the shared jev_decide core."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import sys

CONFIDENCE_THRESHOLD = 0.9
DEFAULT_SEVERITY = "important"
DEFAULT_FLAG = "needs_review"
SEVERITY_FLAGS = {
    "blocking": "fix_now",
    "important": "fix_in_batch",
    "cosmetic": "optional_polish",
}
RECOMMENDED_FIELDS = ("title", "description", "context")
INSTRUCTIONS = (
    "Classify the single review finding described by the state into exactly "
    "one severity. Read the finding's title and description, and any context "
    "or diff evidence the state carries, then choose one severity."
)
CRITERIA = {
    "blocking": {
        "what": (
            "A defect that breaks the contract, security, or conformance to "
            "the brief: the change is wrong, unsafe, or does not do what the "
            "brief asked for, so the work cannot be accepted as it stands."
        ),
        "not_for": (
            "A real but non-blocking defect that can be corrected in the same "
            "batch without changing whether the work is acceptable, or a "
            "style preference."
        ),
        "examples": [
            "the requested protection is not implemented",
            "a credential is written into a tracked file",
            "the change contradicts the brief's stated scope",
        ],
    },
    "important": {
        "what": (
            "A real defect that should be corrected but does not by itself "
            "block acceptance: a genuine bug, a missing edge case, a wrong "
            "error path, or a real regression risk."
        ),
        "not_for": (
            "A defect that breaks the contract or security, or a mere style "
            "or naming preference."
        ),
        "examples": [
            "an error path returns the wrong code",
            "a boundary case is untested",
            "a race window is left open",
        ],
    },
    "cosmetic": {
        "what": (
            "A style, naming, formatting, or nit-level observation with no "
            "behavioral or contractual consequence."
        ),
        "not_for": (
            "Any defect with a behavioral or contractual consequence, however "
            "small it looks."
        ),
        "examples": [
            "inconsistent naming",
            "a long line or awkward wording",
            "a redundant comment",
        ],
    },
}


class UsageError(Exception):
    """A caller-side mistake: nothing on stdout, exit 2, no network call."""


def valid_confidence(value):
    """Return the model's confidence as a float in [0, 1], or None when the
    answer cannot be trusted: non-numeric, non-finite, negative, or above 1.

    This wrapper owns its own boundary validation instead of trusting the shared
    core's gate, so a NaN, Infinity, or out-of-range confidence is never compared
    as if it passed the floor (NaN compares false against every bound) and is
    never emitted as a non-JSON literal.
    """
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
        return None
    return confidence


def emit(severity, confidence, flag, reason):
    safe = valid_confidence(confidence)
    payload = {
        "severity": severity,
        "confidence": round(safe if safe is not None else 0.0, 4),
        "reason": reason[:400],
        "flag": flag,
    }
    # allow_nan=False keeps the output strict JSON: no NaN or Infinity literal
    # can ever be written, whatever a future change hands to this function.
    sys.stdout.write(
        json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n"
    )


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


def _on_alarm(unused_signum: int, unused_frame: object) -> None:
    raise _Deadline()


def load_core(path):
    if not path or not os.path.isfile(path):
        raise FileNotFoundError(path)
    spec = importlib.util.spec_from_file_location("fm_jev_decide_core", path)
    if spec is None or spec.loader is None:
        raise ImportError("cannot import shared core: %s" % path)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so the core's dataclasses and Enums resolve their own
    # module through sys.modules; without this, class creation fails.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    if not hasattr(module, "guard") or not hasattr(module, "Verdict"):
        raise ImportError("shared core does not expose guard()/Verdict")
    return module


def carries_finding_text(payload):
    for value in payload.values():
        if isinstance(value, str) and value.strip():
            return True
        if isinstance(value, (list, dict)) and value:
            return True
    return False


def load_finding(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        raise UsageError("cannot read the finding input: %s" % exc) from None
    if not raw.strip():
        raise UsageError("empty input: expected one JSON finding object")
    try:
        payload = json.loads(raw)
    except ValueError as exc:
        raise UsageError("invalid JSON input: %s" % exc) from None
    if not isinstance(payload, dict):
        raise UsageError("input must be a JSON object describing one finding")
    if not carries_finding_text(payload):
        raise UsageError(
            "empty finding: expected at least one of %s"
            % ", ".join(RECOMMENDED_FIELDS)
        )
    return payload


MAX_TIMEOUT_SECONDS = 3600.0


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


def classify(core, payload):
    decision = core.guard(
        payload,
        CRITERIA,
        threshold=CONFIDENCE_THRESHOLD,
        block_options=(),
        instructions=INSTRUCTIONS,
    )
    confidence = valid_confidence(decision.confidence)
    route = decision.route
    if confidence is None:
        return (
            DEFAULT_SEVERITY,
            0.0,
            DEFAULT_FLAG,
            "invalid confidence %r; keeping the default severity"
            % (decision.confidence,),
        )
    if decision.verdict is core.Verdict.PROCEED and route in SEVERITY_FLAGS:
        return route, confidence, SEVERITY_FLAGS[route], "ok"
    if route is not None and route not in SEVERITY_FLAGS:
        reason = "unexpected severity %r; keeping the default severity" % (route,)
    elif route is not None:
        reason = "confidence %s below threshold %s for severity %s" % (
            confidence,
            CONFIDENCE_THRESHOLD,
            route,
        )
    else:
        reason = decision.reason or "no usable severity"
    return DEFAULT_SEVERITY, confidence, DEFAULT_FLAG, reason


def run(core_path, input_path, timeout_raw):
    try:
        payload = load_finding(input_path)
    except UsageError as exc:
        sys.stderr.write("fm-jev-finding: %s\n" % exc)
        return 2
    try:
        core = load_core(core_path)
        timeout = parse_timeout(timeout_raw)
    except Exception as exc:
        emit(
            DEFAULT_SEVERITY,
            0.0,
            DEFAULT_FLAG,
            "fail_safe: %s: %s" % (type(exc).__name__, exc),
        )
        return 0
    if timeout > 0:
        try:
            arm_deadline(timeout)
        except Exception as exc:
            # A bound that cannot be armed must not become an unbounded wait:
            # this fail-safe is decided before the shared core makes any call.
            emit(
                DEFAULT_SEVERITY,
                0.0,
                DEFAULT_FLAG,
                "fail_safe: could not arm the %ss wall-clock bound: %s: %s"
                % (timeout, type(exc).__name__, exc),
            )
            return 0
    try:
        try:
            severity, confidence, flag, reason = classify(core, payload)
        finally:
            if timeout > 0:
                clear_deadline()
        emit(severity, confidence, flag, reason)
        return 0
    except _Deadline:
        emit(
            DEFAULT_SEVERITY,
            0.0,
            DEFAULT_FLAG,
            "timeout: no severity within %ss" % timeout,
        )
        return 0
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        emit(
            DEFAULT_SEVERITY,
            0.0,
            DEFAULT_FLAG,
            "core_error: %s: %s" % (type(exc).__name__, exc),
        )
        return 0


if __name__ == "__main__":
    sys.exit(run(*sys.argv[1:4]))
PY

# Exit 2 is a usage error and owns stderr and the empty stdout above. Any other
# unexpected non-zero exit still owes the caller one typed severity, because a
# finding must never be dropped silently.
if [ "$rc" -eq 2 ]; then
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '{"severity":"important","confidence":0.0,"reason":"classifier did not run; keeping the default severity","flag":"needs_review"}'
fi
exit 0
