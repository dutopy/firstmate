#!/usr/bin/env bash
# fm-jev-blocker.sh - advisory, fail-safe classifier for one worker block,
# backed by typesafe.ai's System One model (Jev) through the shared jev_decide
# core.
#
# Usage:
#   fm-jev-blocker.sh [<block.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_BLOCKER_CORE:-$FM_HOME/data/jev_decide.py}, imported by path with
#   importlib, so there is exactly one HTTP client and exactly one confidence
#   gate. This wrapper re-implements neither the client nor TypeSafe's API
#   contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing a single worker block, from a file or
#   from "-" (or no positional argument) for stdin. The whole object is the
#   model's `state`; recommended fields are `block` (the blocker text), `task`
#   (the task id), and `note` (any extra evidence). Never pass a list of
#   blocks: this tool answers for exactly one block per call.
#
# One atomic question: a single forced-choice question asks the model to place
#   the block in exactly one class.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"verdict":"real_business_blocker|needs_captain_decision|transient_retryable|test_fixture_noise","confidence":<0..1>,"reason":"<text>","flag":"<action>"}
#   The `flag` is the advisory action firstmate may take for the verdict:
#     none              - a real business blocker; handle it as an ordinary
#                         blocker, no suppression and no special card.
#     captain_card      - open a keyed captain decision card for the block.
#     bounded_retry     - retry the bounded number of times the retry doctrine
#                         allows, then surface it.
#     suppress_wake     - the block is test-fixture noise at or above the
#                         confidence floor, so its wake may be suppressed.
#     surface_captain   - no usable verdict (confidence below the floor, or any
#                         fail-safe path); surface the block to the captain
#                         anyway, exactly as if the classifier were absent.
#
# Fail-safe: every path that produced no usable verdict - confidence below 0.9
#   or any non-finite or out-of-range confidence (NaN, infinity, negative, or
#   above 1), a missing or rejected API key, any API or network error, a
#   malformed success response, invalid or unreadable input JSON, an unreadable
#   shared core, or the wall-clock bound (FM_JV_BLOCKER_TIMEOUT, default 20s) -
#   resolves to verdict needs_captain_decision, flag surface_captain, exit 0.
#   There is no silent suppression and no silent retry.
#
# The wrapper validates the confidence itself, so a stale shared core that
#   returned a non-finite confidence cannot reintroduce a suppression: any
#   confidence that is not a finite number in [0, 1] is treated exactly like an
#   absent verdict, and the emitted confidence is always a plain JSON number.
#
# Exit: 0 for every classified outcome, including every fail-safe. 2 for a usage
#   error (an unknown flag, a missing flag value, or missing python3), which
#   prints nothing on stdout, makes no network call, and leaves the caller to
#   judge exactly as if the classifier were absent.
#
# Environment:
#   FM_JV_BLOCKER_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_BLOCKER_TIMEOUT  wall-clock bound in seconds (default 20; 0 disables)
#   TYPESAFE_API_KEY       from this process environment, else a TYPESAFE_API_KEY=
#                          line in $FM_HOME/.env read with fmx_env_get (the
#                          environment wins). The key reaches the one python
#                          child through its environment, because the shared
#                          core reads it there; it never appears on argv and
#                          nothing logs or writes it.
#   TYPESAFE_BASE_URL      passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never overrides a hard rule, never
#   suppresses a wake on its own, never retries on its own, and is not run on
#   every tool call. docs/jev-guard.md owns the contract and the recommended
#   call sites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_BLOCKER_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_BLOCKER_TIMEOUT:-20}"

die() { printf 'fm-jev-blocker: %s\n' "$1" >&2; exit 2; }
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
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-blocker.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
python3 - "$CORE" "$INPUT" "$TIMEOUT" <<'PY' || rc=$?
"""Classify one worker block through the shared jev_decide core."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import sys

CONFIDENCE_THRESHOLD = 0.9
DEFAULT_VERDICT = "needs_captain_decision"
DEFAULT_FLAG = "surface_captain"
FLAGS = {
    "real_business_blocker": "none",
    "needs_captain_decision": "captain_card",
    "transient_retryable": "bounded_retry",
    "test_fixture_noise": "suppress_wake",
}
INSTRUCTIONS = (
    "Classify the single worker block described by the state. Read the block "
    "text, the task, and any notes, then choose exactly one class."
)
CRITERIA = {
    "real_business_blocker": {
        "what": (
            "The worker is blocked by a genuine external condition - a missing "
            "dependency, an unavailable upstream service, a credential or "
            "access the worker lacks, or a human process - that is not "
            "transient and is not test noise."
        ),
        "not_for": (
            "A failure a bounded retry can clear, a question only the captain "
            "can answer, or an artifact of the test fixtures."
        ),
        "examples": [
            "the package registry is down",
            "an API token is missing",
            "an upstream migration has not run yet",
        ],
    },
    "needs_captain_decision": {
        "what": (
            "The block is really a choice that belongs to the captain - a "
            "product, scope, or authority decision the worker cannot make on "
            "its own."
        ),
        "not_for": (
            "A genuine external condition the worker can report, a transient "
            "failure, or test noise."
        ),
        "examples": [
            "which of two designs to ship",
            "whether to widen the stated scope",
            "whether to discard unlanded work",
        ],
    },
    "transient_retryable": {
        "what": (
            "The failure is transient and a bounded retry is expected to clear "
            "it - a rate limit, a flaky network call, momentary lock "
            "contention, or a timeout."
        ),
        "not_for": (
            "A durable external condition, a question for the captain, or "
            "test-fixture noise."
        ),
        "examples": [
            "HTTP 429 from a provider",
            "a connection reset",
            "a lock held by another process",
        ],
    },
    "test_fixture_noise": {
        "what": (
            "The report is an artifact of the test fixtures or a known "
            "expected test failure, not a real block, so waking anyone about "
            "it is noise."
        ),
        "not_for": (
            "A failure in production code, a genuine dependency problem, or "
            "any uncertainty about whether the failure is fixture-only."
        ),
        "examples": [
            "an intentionally failing fixture",
            "a test that asserts the error path",
            "snapshot churn in a scratch tree",
        ],
    },
}


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


def usage_error(message):
    sys.stderr.write("fm-jev-blocker: %s\n" % message)
    raise SystemExit(2)


def emit(verdict, confidence, flag, reason):
    # allow_nan=False keeps the output strict JSON: a non-finite confidence can
    # never reach stdout even if a caller passes one by mistake.
    conf = valid_confidence(confidence)
    payload = {
        "verdict": verdict,
        "confidence": round(conf, 4) if conf is not None else 0.0,
        "reason": str(reason)[:400],
        "flag": flag,
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n")


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


def read_payload(path):
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("input must be a JSON object describing one block")
    return payload


def parse_timeout(raw):
    timeout = float(raw)
    if timeout < 0:
        raise ValueError("timeout must not be negative")
    return timeout


def valid_confidence(value):
    """A finite confidence in [0, 1], or None for anything unusable."""
    if isinstance(value, bool):
        return None
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
        return None
    return confidence


def classify(core, payload):
    decision = core.guard(
        payload,
        CRITERIA,
        threshold=CONFIDENCE_THRESHOLD,
        block_options=(),
        instructions=INSTRUCTIONS,
    )
    route = decision.route if isinstance(decision.route, str) else None
    confidence = valid_confidence(decision.confidence)
    if confidence is None:
        return (
            DEFAULT_VERDICT,
            0.0,
            DEFAULT_FLAG,
            "invalid or missing confidence %r; surfacing to the captain"
            % (decision.confidence,),
        )
    if decision.verdict is core.Verdict.PROCEED and route in FLAGS:
        return route, confidence, FLAGS[route], "ok"
    if route is not None and route not in FLAGS:
        reason = "unexpected class %r; surfacing to the captain" % (route,)
    elif route is not None:
        reason = "confidence %s below threshold %s for class %s" % (
            confidence,
            CONFIDENCE_THRESHOLD,
            route,
        )
    else:
        reason = decision.reason or "no usable verdict"
    return DEFAULT_VERDICT, confidence, DEFAULT_FLAG, reason


def run(core_path, input_path, timeout_raw):
    try:
        core = load_core(core_path)
        payload = read_payload(input_path)
        timeout = parse_timeout(timeout_raw)
    except Exception as exc:
        emit(
            DEFAULT_VERDICT,
            0.0,
            DEFAULT_FLAG,
            "fail_safe: %s: %s" % (type(exc).__name__, exc),
        )
        return 0
    armed = timeout > 0 and hasattr(signal, "SIGALRM") and hasattr(signal, "setitimer")
    if armed:
        signal.signal(signal.SIGALRM, _on_alarm)
        signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        try:
            verdict, confidence, flag, reason = classify(core, payload)
        finally:
            if armed:
                signal.setitimer(signal.ITIMER_REAL, 0)
        emit(verdict, confidence, flag, reason)
        return 0
    except _Deadline:
        emit(
            DEFAULT_VERDICT,
            0.0,
            DEFAULT_FLAG,
            "timeout: no verdict within %ss" % timeout,
        )
        return 0
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        emit(
            DEFAULT_VERDICT,
            0.0,
            DEFAULT_FLAG,
            "core_error: %s: %s" % (type(exc).__name__, exc),
        )
        return 0


if __name__ == "__main__":
    sys.exit(run(*sys.argv[1:4]))
PY
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '{"verdict":"needs_captain_decision","confidence":0.0,"reason":"classifier did not run; surfacing to the captain","flag":"surface_captain"}'
fi
exit 0
