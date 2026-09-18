#!/usr/bin/env bash
# fm-jev-console-route.sh - advisory, fail-safe classifier for one captured
# Discord console message, backed by typesafe.ai's System One model (Jev)
# through the shared jev_decide core.
#
# Usage:
#   fm-jev-console-route.sh [<message.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_CONSOLE_ROUTE_CORE:-$FM_HOME/data/jev_decide.py}, imported by path
#   with importlib, so there is exactly one HTTP client and exactly one
#   confidence gate. This wrapper re-implements neither the client nor
#   TypeSafe's API contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing a single captured captain message,
#   from a file or from "-" (or no positional argument) for stdin. The whole
#   object is the model's `state`; recommended fields are `message` (the captain
#   text) and `label` (the configured channel label). Never pass a list of
#   messages: this tool answers for exactly one message per call.
#
# One atomic question: a single forced-choice question asks the model whether
#   this message can be answered directly from current durable records, or
#   whether it needs the full firstmate turn.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"verdict":"fast_answer|full_turn","confidence":<0..1>,"reason":"<text>","flag":"<action>"}
#   The `flag` is the advisory action the caller may take for the verdict:
#     answer_from_records - the message is a plain status lookup; answer it
#                           directly from durable records without a full turn.
#     full_turn           - no usable fast-path verdict: route the message to the
#                           full firstmate turn exactly as if this tool were
#                           absent.
#
# Fail-safe: every path that produced no usable verdict - confidence below 0.9
#   or any non-finite or out-of-range confidence (NaN, infinity, negative, or
#   above 1), a missing or rejected API key, any API or network error, a
#   malformed success response, invalid or unreadable input JSON, an unreadable
#   shared core, an unusable FM_JV_CONSOLE_ROUTE_TIMEOUT value (non-finite,
#   negative, or above the ceiling), a host that cannot arm the bound, or the
#   wall-clock bound itself (FM_JV_CONSOLE_ROUTE_TIMEOUT, default 20s) -
#   resolves to verdict full_turn, flag full_turn, exit 0. There is no silent
#   fast answer on uncertain evidence.
#
# Wall-clock bound: one finite deadline is the only wait this tool allows, and an
#   invalid value can neither disable it nor overflow it. The numeric input is
#   checked before it reaches the timer, and arming the timer is itself inside
#   the fail-safe path, so a NaN or infinite timeout is a bounded fail-safe and
#   never an unbounded call.
#
# The wrapper validates the confidence itself, so a stale shared core that
#   returned a non-finite confidence cannot reintroduce a fast answer: any
#   confidence that is not a finite number in [0, 1] is treated exactly like an
#   absent verdict, and the emitted confidence is always a plain JSON number.
#
# Exit: 0 for every classified outcome, including every fail-safe. 2 for a usage
#   error (an unknown flag, a missing flag value, or missing python3), which
#   prints nothing on stdout, makes no network call, and leaves the caller to
#   route the message to the full turn exactly as if the classifier were absent.
#
# Environment:
#   FM_JV_CONSOLE_ROUTE_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_CONSOLE_ROUTE_TIMEOUT  wall-clock bound in seconds (default 20; 0 disables);
#                                must be a finite number in [0, 3600], and anything
#                                else is a fail-safe, never an unbounded call
#   TYPESAFE_API_KEY             from this process environment, else a TYPESAFE_API_KEY=
#                                line in $FM_HOME/.env read with fmx_env_get (the
#                                environment wins). The key reaches the one python
#                                child through its environment, because the shared
#                                core reads it there; it never appears on argv and
#                                nothing logs or writes it.
#   TYPESAFE_BASE_URL            passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never overrides a hard rule and never
#   starts, suppresses, or answers firstmate work on its own; the console
#   routes to the fast path only on a fast_answer verdict and falls back to the
#   full turn everywhere else. docs/jev-guard.md owns the contract, and
#   docs/discord-conversation-console.md owns the console fast path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_CONSOLE_ROUTE_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_CONSOLE_ROUTE_TIMEOUT:-20}"

die() { printf 'fm-jev-console-route: %s\n' "$1" >&2; exit 2; }
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
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-console-route.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
python3 - "$CORE" "$INPUT" "$TIMEOUT" <<'PY' || rc=$?
"""Classify one captured Discord console message through the shared jev_decide core."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import sys

CONFIDENCE_THRESHOLD = 0.9
DEFAULT_VERDICT = "full_turn"
DEFAULT_FLAG = "full_turn"
FLAGS = {
    "fast_answer": "answer_from_records",
    "full_turn": "full_turn",
}
INSTRUCTIONS = (
    "Decide whether the single captured captain message can be answered "
    "directly from current durable records, with no new work and no judgment, "
    "or whether it needs the full firstmate turn. Read the message and the "
    "channel label, then choose exactly one route."
)
CRITERIA = {
    "fast_answer": {
        "what": (
            "A plain status lookup whose answer already exists in the durable "
            "records: where a named task stands, what is running or waiting, "
            "which tasks are blocked, or what the backlog currently holds. The "
            "answer is a read of the current records, not a synthesis."
        ),
        "not_for": (
            "Any request to change, build, investigate, decide, or explain "
            "something new; any ambiguous or multi-part question; any question "
            "whose answer would need reasoning beyond reading one current "
            "record; any greeting, thanks, or open-ended conversation."
        ),
        "examples": [
            "where does the folium email lot stand",
            "what is running right now",
            "which tasks are blocked",
            "status of hermes-role-profile-renames",
        ],
    },
    "full_turn": {
        "what": (
            "Everything else: a request for work, a decision, an explanation, "
            "a follow-up, an ambiguous or multi-part question, or any message "
            "whose answer is not already sitting in the current records."
        ),
        "not_for": (
            "A plain status lookup that one current record already answers."
        ),
        "examples": [
            "please fix the login bug",
            "why did the pipeline fail",
            "should I merge the Folium PR",
            "hello",
        ],
    },
}


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


def usage_error(message):
    sys.stderr.write("fm-jev-console-route: %s\n" % message)
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


def _on_alarm(unused_signum, unused_frame):
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
        raise ValueError("input must be a JSON object describing one message")
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
    """Arm the one wall-clock bound, or raise when this host cannot arm it."""
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)


def clear_deadline():
    """Disarm the wall-clock bound."""
    signal.setitimer(signal.ITIMER_REAL, 0)


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
            "invalid or missing confidence %r; routing to the full turn"
            % (decision.confidence,),
        )
    if decision.verdict is core.Verdict.PROCEED and route == "fast_answer":
        return "fast_answer", confidence, FLAGS["fast_answer"], "ok"
    if route is not None and route not in FLAGS:
        reason = "unexpected route %r; routing to the full turn" % (route,)
    elif route == "fast_answer":
        reason = "confidence %s below threshold %s for route fast_answer" % (
            confidence,
            CONFIDENCE_THRESHOLD,
        )
    elif route == "full_turn":
        reason = decision.reason or "the model chose the full turn"
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
    if timeout > 0:
        try:
            arm_deadline(timeout)
        except Exception as exc:
            # A bound that cannot be armed must not become an unbounded wait:
            # this fail-safe is decided before the shared core makes any call.
            emit(
                DEFAULT_VERDICT,
                0.0,
                DEFAULT_FLAG,
                "fail_safe: could not arm the %ss wall-clock bound: %s: %s"
                % (timeout, type(exc).__name__, exc),
            )
            return 0
    try:
        try:
            verdict, confidence, flag, reason = classify(core, payload)
        finally:
            if timeout > 0:
                clear_deadline()
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
  printf '%s\n' '{"verdict":"full_turn","confidence":0.0,"reason":"classifier did not run; routing to the full turn","flag":"full_turn"}'
fi
exit 0
