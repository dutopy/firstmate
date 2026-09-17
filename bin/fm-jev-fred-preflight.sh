#!/usr/bin/env bash
# fm-jev-fred-preflight.sh - advisory, fail-safe pre-flight classifier for one
# action Fred intends to take on Folium, backed by typesafe.ai's System One
# model (Jev) through the shared jev_decide core.
#
# Usage:
#   fm-jev-fred-preflight.sh [<action.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_FRED_PREFLIGHT_CORE:-$FM_HOME/data/jev_decide.py}, imported by path
#   with importlib, so there is exactly one HTTP client and exactly one
#   confidence gate. This wrapper re-implements neither the client nor
#   TypeSafe's API contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing exactly one action Fred is about to
#   take, from a file or from "-" (or no positional argument) for stdin. The
#   whole object is the model's `state`; recommended fields are `action` (what
#   Fred intends to do, in plain words), `target` (the channel, recipient,
#   system, or record it touches), `context` (any extra evidence such as the
#   conversation or the standing rule behind it), and `note`. Never pass a list
#   of actions: this tool answers for exactly one action per call.
#
# One atomic question: a single forced-choice question asks the model to place
#   the intended action in exactly one class, before anything acts on it.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"verdict":"routine_reversible|consequential|irreversible_or_secret","confidence":<0..1>,"reason":"<text>","flag":"<action>"}
#   The `flag` is the advisory action firstmate may take for the verdict:
#     proceed          - the action is routine and reversible at or above the
#                        confidence floor; Fred may take it on the standing
#                        path. It is a recommendation, not a permission.
#     hold_for_review  - the action is consequential: hold it for the ordinary
#                        human review before it happens.
#     human_portal     - the action is irreversible or secret-exposing: route it
#                        to the human portal and never let Fred take it alone.
#
# Fail-safe: every path that produced no usable classification - confidence
#   below 0.9 or any non-finite or out-of-range confidence (NaN, infinity,
#   negative, or above 1), a missing or rejected API key, any API or network
#   error, a malformed success response, invalid or unreadable input JSON, an
#   unreadable shared core, or the wall-clock bound
#   (FM_JV_FRED_PREFLIGHT_TIMEOUT, default 20s) - resolves to verdict
#   consequential, flag hold_for_review, exit 0. No error, no timeout, no
#   low-confidence answer, and no malformed response is ever reported as
#   routine_reversible, and nothing is silently waved through.
#
# Wall-clock bound: one finite deadline is armed before the call, so the call
#   and its retries can never outlive the bound. The bound is the only reason
#   the request may wait: a missing, non-numeric, zero, negative, non-finite, or
#   above-ceiling FM_JV_FRED_PREFLIGHT_TIMEOUT, and a host that cannot arm the
#   deadline at all, are each a fail-safe that emits the default verdict with no
#   network call, because a bound that cannot be armed must not become an
#   unbounded wait. An invalid value can therefore neither disable the bound nor
#   overflow the timer, and the tool never runs a classification without one.
#
# The wrapper validates the confidence itself, so a stale shared core that
#   returned a non-finite confidence cannot reintroduce a routine verdict: any
#   confidence that is not a finite number in [0, 1] is treated exactly like an
#   absent class, and the emitted confidence is always a plain JSON number.
#
# Exit: 0 for every classified outcome, including every fail-safe. 2 for a usage
#   error (an unknown flag, a missing flag value, or missing python3), which
#   prints nothing on stdout, makes no network call, and leaves the caller to
#   judge exactly as if the classifier were absent.
#
# Environment:
#   FM_JV_FRED_PREFLIGHT_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_FRED_PREFLIGHT_TIMEOUT  wall-clock bound in seconds (default 20); must
#                                 be a finite number of seconds in (0, 3600],
#                                 and anything else is a fail-safe
#   TYPESAFE_API_KEY              from this process environment, else a
#                                 TYPESAFE_API_KEY= line in $FM_HOME/.env read
#                                 with fmx_env_get (the environment wins). The
#                                 key reaches the one python child through its
#                                 environment, because the shared core reads it
#                                 there; it never appears on argv and nothing
#                                 logs or writes it.
#   TYPESAFE_BASE_URL             passed through to the core (tests point it at loopback)
#
# Authority: advisory only, and read-only. This tool never overrides a hard
#   rule and never carries authority to act: it makes no change to any live
#   system, opens no gateway or Discord connection, changes no service, and
#   reads no Folium credential or secret - the only secret it touches is its own
#   TYPESAFE_API_KEY. It writes nothing of its own either: the single file it
#   creates is its temporary copy of stdin input, which it removes on the way
#   out, and it disables Python's bytecode cache so importing the shared core
#   cannot leave one beside it. It is not run on every tool call.
#   docs/jev-guard.md owns the contract and the recommended call sites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_FRED_PREFLIGHT_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_FRED_PREFLIGHT_TIMEOUT:-20}"

die() { printf 'fm-jev-fred-preflight: %s\n' "$1" >&2; exit 2; }
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
# The shared core sits beside the home's private data, so importing it must not
# leave a bytecode cache there: this tool stays a read-only advisory reader.
export PYTHONDONTWRITEBYTECODE=1
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT/INT/TERM/HUP traps below.
cleanup() { [ -n "$INPUT_TMP" ] && rm -f "$INPUT_TMP"; return 0; }
trap cleanup EXIT INT TERM HUP

if [ -z "$INPUT" ] || [ "$INPUT" = '-' ]; then
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-fred-preflight.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
python3 - "$CORE" "$INPUT" "$TIMEOUT" <<'PY' || rc=$?
"""Classify one intended Fred action through the shared jev_decide core."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import sys

CONFIDENCE_THRESHOLD = 0.9
MAX_TIMEOUT_SECONDS = 3600.0
_TIMEOUT_RULE = "timeout must be a finite number of seconds in (0, %g]" % MAX_TIMEOUT_SECONDS
DEFAULT_VERDICT = "consequential"
DEFAULT_FLAG = "hold_for_review"
FLAGS = {
    "routine_reversible": "proceed",
    "consequential": "hold_for_review",
    "irreversible_or_secret": "human_portal",
}
INSTRUCTIONS = (
    "Classify the single action that Fred intends to take, as described by the "
    "state. Read what Fred intends to do, what it touches, and any context or "
    "notes, then choose exactly one class. Classify the action Fred describes, "
    "not the one that would be reasonable to take instead. Answer with low "
    "confidence rather than guessing."
)
CRITERIA = {
    "routine_reversible": {
        "what": (
            "An ordinary Folium action Fred already performs unattended, whose "
            "effect stays inside Fred's own workspace or mailbox, is visible to "
            "nobody new, and can be undone or ignored at will - no secret, no "
            "new authority, no money, no new outside contact, and no "
            "irreversible effect."
        ),
        "not_for": (
            "Anything destructive or hard to take back, anything that exposes "
            "or moves secret or private material, anything that changes access, "
            "configuration, or a standing rule, anything that newly contacts an "
            "outside party, and anything that commits money, contract, or legal "
            "position."
        ),
        "examples": [
            "reading or labelling an incoming message",
            "drafting a reply that a human will review and send",
            "moving a message inside Fred's own folders",
            "summarising a thread Fred already has",
        ],
    },
    "consequential": {
        "what": (
            "An action with a real, externally visible, or hard-to-undo "
            "effect that a human should see before it happens, but that is "
            "neither destructive, nor secret-exposing, nor a new commitment: it "
            "changes shared state, Fred's own behaviour, or contact with a "
            "party already known."
        ),
        "not_for": (
            "An action Fred already performs unattended with a trivially "
            "reversible effect, and anything destructive, irreversible, "
            "access-changing, secret-exposing, or newly committing."
        ),
        "examples": [
            "changing a filter, a rule, or Fred's own configuration",
            "editing a shared document, calendar, or record",
            "posting into a shared channel",
            "messaging a known correspondent on Fred's own behalf",
            "bulk-editing many messages in one pass",
        ],
    },
    "irreversible_or_secret": {
        "what": (
            "An action that cannot be undone once taken, or that exposes, "
            "moves, or grants access to secret or private material: deletion or "
            "overwriting, a message that cannot be recalled, an access or "
            "credential change, the sharing of a code or key, a payment or "
            "commitment, or the disclosure of private material outside its "
            "intended audience."
        ),
        "not_for": (
            "An action a human review can still recall and repair, and anything "
            "Fred already performs unattended."
        ),
        "examples": [
            "deleting a message, a record, or an account",
            "sending a message that cannot be recalled to an outside party",
            "granting or revoking access",
            "sharing a credential, a key, or an authentication code",
            "paying or authorising a payment",
            "disclosing private material to a new recipient",
        ],
    },
}


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


def usage_error(message):
    sys.stderr.write("fm-jev-fred-preflight: %s\n" % message)
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
        raise ValueError("input must be a JSON object describing one action")
    return payload


def parse_timeout(raw):
    """A finite timeout in (0, MAX_TIMEOUT_SECONDS], or an error.

    This is the only value that may ever reach the timer, so a value that
    cannot be represented there - a missing, non-numeric, zero, negative,
    non-finite, or above-ceiling one - is rejected here instead of silently
    disabling or overflowing the bound. There is no caller-supplied way to run
    this classifier without a wall-clock bound.
    """
    try:
        timeout = float(raw)
    except (TypeError, ValueError):
        raise ValueError("%s; got %r" % (_TIMEOUT_RULE, raw)) from None
    if not math.isfinite(timeout) or not 0.0 < timeout <= MAX_TIMEOUT_SECONDS:
        raise ValueError("%s; got %r" % (_TIMEOUT_RULE, raw))
    return timeout


def arm_deadline(timeout):
    """Arm the one wall-clock bound, or raise when this host cannot arm it.

    parse_timeout has already guaranteed a finite positive value, so the timer
    cannot overflow; a host without SIGALRM raises here and the caller turns
    that into a fail-safe rather than a classification without a bound.
    """
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
            "invalid or missing confidence %r; failing safe to consequential"
            % (decision.confidence,),
        )
    if decision.verdict is core.Verdict.PROCEED and route in FLAGS:
        return route, confidence, FLAGS[route], "ok"
    if route is not None and route not in FLAGS:
        reason = "unexpected class %r; failing safe to consequential" % (route,)
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
    try:
        arm_deadline(timeout)
    except Exception as exc:
        # A bound that cannot be armed must not become an unbounded wait: this is
        # a fail-safe, decided before the shared core makes any call.
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
  printf '%s\n' '{"verdict":"consequential","confidence":0.0,"reason":"classifier did not run; failing safe to consequential","flag":"hold_for_review"}'
fi
exit 0
