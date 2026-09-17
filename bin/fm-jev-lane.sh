#!/usr/bin/env bash
# fm-jev-lane.sh - advisory, fail-safe lane classifier for one incoming
# request, backed by typesafe.ai's System One model (Jev) through the shared
# jev_decide core.
#
# Usage:
#   fm-jev-lane.sh [<request.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_LANE_CORE:-$FM_HOME/data/jev_decide.py}, imported by path with
#   importlib, so there is exactly one HTTP client and exactly one confidence
#   gate. This wrapper re-implements neither the client nor TypeSafe's API
#   contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing a single incoming request, from a
#   file or from "-" (or no positional argument) for stdin. The whole object is
#   the model's `state`; recommended fields are `request` (the request text),
#   `source` (where it came from), and `note` (any extra evidence). Never pass a
#   list of requests: this tool answers for exactly one request per call.
#
# One atomic question: a single forced-choice question asks the model to place
#   the request in exactly one lane.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"route":"system|proapplis|folium|arfal|null","confidence":<0..1>,"reason":"<text>","flag":"<action>"}
#   The `flag` is the advisory action firstmate may take for the route:
#     none         - route the request to that lane as usual.
#     dormant      - the request belongs to ARFAL; mark it dormant only and
#                    never activate ARFAL or start ARFAL work.
#     ask_captain  - no usable route (confidence below the floor, or any
#                    fail-safe path); ask the captain which lane it belongs to.
#
# ARFAL is never activated: a confident ARFAL result only sets flag `dormant`,
#   which marks the request dormant so firstmate can park it. This tool carries
#   no authority to wake, launch, or fund an ARFAL lane.
#
# Fail-safe: every path that produced no usable route - confidence below 0.9, a
#   missing or rejected API key, any API or network error, a malformed success
#   response, invalid or unreadable input JSON, an unreadable shared core, or
#   the wall-clock bound (FM_JV_LANE_TIMEOUT, default 20s) - resolves to route
#   null, flag ask_captain, exit 0. There is no silent lane assignment.
#
# Exit: 0 for every classified outcome, including every fail-safe. 2 for a usage
#   error (an unknown flag, a missing flag value, or missing python3), which
#   prints nothing on stdout, makes no network call, and leaves the caller to
#   judge exactly as if the classifier were absent.
#
# Environment:
#   FM_JV_LANE_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_LANE_TIMEOUT  wall-clock bound in seconds (default 20; 0 disables)
#   TYPESAFE_API_KEY    from this process environment, else a TYPESAFE_API_KEY=
#                       line in $FM_HOME/.env read with fmx_env_get (the
#                       environment wins). The key reaches the one python child
#                       through its environment, because the shared core reads
#                       it there; it never appears on argv and nothing logs or
#                       writes it.
#   TYPESAFE_BASE_URL   passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never overrides a hard rule, never starts
#   work, never activates the ARFAL lane, and is not run on every tool call.
#   docs/jev-guard.md owns the contract and the recommended call sites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_LANE_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_LANE_TIMEOUT:-20}"

die() { printf 'fm-jev-lane: %s\n' "$1" >&2; exit 2; }
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
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-lane.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
python3 - "$CORE" "$INPUT" "$TIMEOUT" <<'PY' || rc=$?
"""Classify one incoming request into a lane through the shared jev_decide core."""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import sys

CONFIDENCE_THRESHOLD = 0.9
DEFAULT_FLAG = "ask_captain"
FLAGS = {
    "system": "none",
    "proapplis": "none",
    "folium": "none",
    "arfal": "dormant",
}
INSTRUCTIONS = (
    "Classify the single incoming request described by the state into exactly "
    "one lane. Read the request text, its source, and any notes. Choose the "
    "lane the request belongs to; if no lane clearly fits, answer with low "
    "confidence so the caller asks the captain."
)
CRITERIA = {
    "system": {
        "what": (
            "The request concerns firstmate's own runtime, fleet plumbing, "
            "supervision, contracts, or cross-cutting infrastructure rather "
            "than one product line."
        ),
        "not_for": (
            "Work on one product line, and any request whose product owner is "
            "one of the other lanes."
        ),
        "examples": [
            "fix the wake watcher",
            "add a backend adapter",
            "update the supervisor contract",
        ],
    },
    "proapplis": {
        "what": (
            "The request concerns ProApplis, its application, its data, or its "
            "delivery."
        ),
        "not_for": (
            "Firstmate's own tooling or another product line."
        ),
        "examples": [
            "fix a ProApplis screen",
            "ship a ProApplis migration",
        ],
    },
    "folium": {
        "what": (
            "The request concerns Folium, its product, or its email bridge."
        ),
        "not_for": (
            "Firstmate's own tooling or another product line."
        ),
        "examples": [
            "change the Folium email triage",
            "ship a Folium client fix",
        ],
    },
    "arfal": {
        "what": (
            "The request concerns ARFAL, a deliberately dormant product line. "
            "Matching it means the request should be marked dormant, not "
            "started."
        ),
        "not_for": (
            "Active product lines, whose work should proceed normally."
        ),
        "examples": [
            "prepare an ARFAL note for later",
            "record an ARFAL idea without starting it",
        ],
    },
}


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


def emit(route, confidence, flag, reason):
    payload = {
        "route": route,
        "confidence": round(float(confidence), 4),
        "reason": reason[:400],
        "flag": flag,
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


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
        raise ValueError("input must be a JSON object describing one request")
    return payload


def parse_timeout(raw):
    timeout = float(raw)
    if timeout < 0:
        raise ValueError("timeout must not be negative")
    return timeout


def classify(core, payload):
    decision = core.guard(
        payload,
        CRITERIA,
        threshold=CONFIDENCE_THRESHOLD,
        block_options=(),
        instructions=INSTRUCTIONS,
    )
    confidence = float(decision.confidence)
    route = decision.route
    if decision.verdict is core.Verdict.PROCEED and route in FLAGS:
        return route, confidence, FLAGS[route], "ok"
    if route is not None and route not in FLAGS:
        reason = "unexpected lane %r; asking the captain" % (route,)
    elif route is not None:
        reason = "confidence %s below threshold %s for lane %s" % (
            confidence,
            CONFIDENCE_THRESHOLD,
            route,
        )
    else:
        reason = decision.reason or "no usable route"
    return None, confidence, DEFAULT_FLAG, reason


def run(core_path, input_path, timeout_raw):
    try:
        core = load_core(core_path)
        payload = read_payload(input_path)
        timeout = parse_timeout(timeout_raw)
    except Exception as exc:
        emit(
            None,
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
            route, confidence, flag, reason = classify(core, payload)
        finally:
            if armed:
                signal.setitimer(signal.ITIMER_REAL, 0)
        emit(route, confidence, flag, reason)
        return 0
    except _Deadline:
        emit(None, 0.0, DEFAULT_FLAG, "timeout: no route within %ss" % timeout)
        return 0
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        emit(
            None,
            0.0,
            DEFAULT_FLAG,
            "core_error: %s: %s" % (type(exc).__name__, exc),
        )
        return 0


if __name__ == "__main__":
    sys.exit(run(*sys.argv[1:4]))
PY
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '{"route":null,"confidence":0.0,"reason":"classifier did not run; asking the captain","flag":"ask_captain"}'
fi
exit 0
