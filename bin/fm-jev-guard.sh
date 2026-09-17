#!/usr/bin/env bash
# fm-jev-guard.sh - advisory, fail-safe action classifier backed by typesafe.ai's
# System One model (Jev) through the shared jev_decide core.
#
# Usage:
#   fm-jev-guard.sh [--rubric merge|dispatch] [<action.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_GUARD_CORE:-$FM_HOME/data/jev_decide.py}, imported by path with
#   importlib, so there is exactly one HTTP client and exactly one confidence
#   gate. This wrapper re-implements neither the client nor TypeSafe's API
#   contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing the action, from a file or from "-"
#   (or no positional argument) for stdin. The whole object is the model's
#   `state`; the one reserved key is `rubric` ("merge" or "dispatch"), which
#   --rubric overrides.
#
# Rubrics:
#   merge    - safe_merge (documentation/comment-only change), needs_human
#              (code, tests, configuration, CI, dependencies, generated
#              artifacts), unsafe (destructive, irreversible, secret-exposing).
#   dispatch - routine (the standing delivery posture already covers it),
#              needs_human (ambiguous, expanding, or authority-sensitive),
#              unsafe (destructive, irreversible, security-sensitive).
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"verdict":"proceed|ask_human|block","confidence":<0..1>,"route":"<option>|null","reason":"<text>"}
#   proceed   -> a recommendation; the caller still owns the decision.
#   ask_human -> escalate to the captain, including every fail-safe path.
#   block     -> the answer matched an unsafe option at or above the confidence
#                threshold; still an escalation to the captain, never an
#                enforcement action by this tool.
#
# Fail-safe: confidence below 0.9, a missing or rejected API key, any API or
#   network error, a malformed success response, or the wall-clock bound
#   (FM_JV_GUARD_TIMEOUT, default 20s, 0 disables) all resolve to ask_human with
#   exit 0. There is no silent proceed and no silent block.
#
# Exit: 0 for every classified outcome, including ask_human and block. 2 for a
#   usage or environment error (invalid or unreadable input JSON, an unknown or
#   missing rubric, missing python3, or an unreadable shared core), which prints
#   nothing on stdout, makes no network call, and leaves the caller to judge
#   exactly as if the guard were absent.
#
# Environment:
#   FM_JV_GUARD_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_GUARD_TIMEOUT  wall-clock bound in seconds (default 20; 0 disables)
#   TYPESAFE_API_KEY     from this process environment, else a TYPESAFE_API_KEY=
#                        line in $FM_HOME/.env read with fmx_env_get (the
#                        environment wins). The key reaches the one python child
#                        through its environment, because the shared core reads
#                        it there; it never appears on argv and nothing logs or
#                        writes it.
#   TYPESAFE_BASE_URL    passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never overrides a hard rule, never merges
#   without the captain, never writes to a project, and is not run on every tool
#   call. docs/jev-guard.md owns the contract and the recommended call sites.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_GUARD_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_GUARD_TIMEOUT:-20}"

die() { printf 'fm-jev-guard: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

RUBRIC=''
INPUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --rubric) [ $# -ge 2 ] || die "--rubric needs a value"; RUBRIC=$2; shift 2 ;;
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
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-guard.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi
[ -r "$INPUT" ] || die "input not readable: $INPUT"

rc=0
python3 - "$CORE" "$RUBRIC" "$INPUT" "$TIMEOUT" <<'PY' || rc=$?
"""Classify one action through the shared jev_decide core (imported by path)."""
from __future__ import annotations

import importlib.util
import json
import os
import signal
import sys

CONFIDENCE_THRESHOLD = 0.9
PROCEED_ROUTE = {"merge": "safe_merge", "dispatch": "routine"}
INSTRUCTIONS = {
    "merge": (
        "Classify the pending merge or the action being considered for merge "
        "safety. Read the action description, the changed files, and any notes."
    ),
    "dispatch": (
        "Classify the requested work for dispatch routing. Read the action "
        "description, the project, and any notes."
    ),
}
RUBRICS = {
    "merge": {
        "safe_merge": {
            "what": (
                "The change modifies only documentation, comments, or other "
                "non-executable prose, so merging it cannot change runtime "
                "behavior."
            ),
            "not_for": (
                "Any change that touches executable code, tests, configuration, "
                "workflows, dependencies, or another artifact a program reads "
                "or runs."
            ),
            "examples": [
                "a README typo fix",
                "a new docs/ guide",
                "a comment-only edit in a shell script",
            ],
        },
        "needs_human": {
            "what": (
                "The change touches code, tests, configuration, CI, "
                "dependencies, or another behavior-bearing artifact, so a person "
                "must approve it before it merges."
            ),
            "not_for": (
                "Documentation-only or comment-only changes; destructive or "
                "irreversible actions, which are unsafe instead."
            ),
            "examples": [
                "a bug fix in bin/",
                "a workflow edit",
                "a dependency bump",
            ],
        },
        "unsafe": {
            "what": (
                "The action would destroy or discard data or history, force an "
                "operation past a guard, disable a safety check, or expose a "
                "secret or credential."
            ),
            "not_for": (
                "Ordinary code or documentation changes that are merely "
                "unreviewed."
            ),
            "examples": [
                "force-push over unlanded work",
                "delete a branch with uncommitted changes",
                "commit an API key",
                "rewrite published history",
            ],
        },
    },
    "dispatch": {
        "routine": {
            "what": (
                "The requested work is ordinary, concrete, and reversible, and "
                "the standing delivery posture already covers it, so it can be "
                "dispatched without a new decision."
            ),
            "not_for": (
                "Ambiguous, expanding, or authority-sensitive requests, and "
                "destructive or irreversible actions."
            ),
            "examples": [
                "fix a stated bug in one file",
                "add a test for existing behavior",
                "update a document",
            ],
        },
        "needs_human": {
            "what": (
                "The request is ambiguous, expanding, or product-facing in a way "
                "that needs the captain to choose, or the routing cannot be "
                "resolved from the standing rules."
            ),
            "not_for": (
                "Ordinary in-scope work that the standing posture already "
                "covers."
            ),
            "examples": [
                "which of two designs to build",
                "widen scope beyond the stated ask",
                "a request that matches no registered project",
            ],
        },
        "unsafe": {
            "what": (
                "The request would be destructive, irreversible, or "
                "security-sensitive, or would bypass a hard safety rule."
            ),
            "not_for": (
                "Ordinary work that is merely unfamiliar or unreviewed."
            ),
            "examples": [
                "delete a project directory",
                "merge without approval",
                "expose credentials",
            ],
        },
    },
}


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


def usage_error(message):
    sys.stderr.write("fm-jev-guard: %s\n" % message)
    raise SystemExit(2)


def emit(verdict, confidence, route, reason):
    payload = {
        "verdict": verdict,
        "confidence": round(float(confidence), 4),
        "route": route,
        "reason": reason[:400],
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


def _on_alarm(unused_signum: int, unused_frame: object) -> None:
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
    if not hasattr(module, "guard") or not hasattr(module, "Verdict"):
        usage_error("shared core %s does not expose guard()/Verdict" % path)
    return module


def read_payload(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        usage_error("input not readable: %s" % exc)
    except ValueError as exc:
        usage_error("input is not valid UTF-8 text: %s" % exc)
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        usage_error("input is not valid JSON: %s" % exc)
    if not isinstance(payload, dict):
        usage_error("input must be a JSON object describing the action")
    return payload


def parse_timeout(raw):
    try:
        timeout = float(raw)
    except ValueError:
        usage_error("FM_JV_GUARD_TIMEOUT is not a number of seconds: %s" % raw)
    if timeout < 0:
        usage_error("FM_JV_GUARD_TIMEOUT must not be negative: %s" % raw)
    return timeout


def map_decision(core, decision, rubric):
    verdict = decision.verdict
    route = decision.route
    confidence = float(decision.confidence)
    if verdict is core.Verdict.BLOCK:
        return "block", "route %s is destructive or irreversible" % route
    if verdict is core.Verdict.ASK_HUMAN:
        if route is None:
            return "ask_human", decision.reason or "the model returned no answer"
        if confidence < CONFIDENCE_THRESHOLD:
            return "ask_human", "confidence %s below threshold %s" % (
                confidence,
                CONFIDENCE_THRESHOLD,
            )
        return "ask_human", "route %s requires a human decision" % route
    if route == PROCEED_ROUTE[rubric]:
        return "proceed", "ok"
    if route == "needs_human":
        return "ask_human", "route needs_human requires a human decision"
    return "ask_human", "unexpected route %r" % (route,)


def main(argv):
    core_path, rubric_flag, input_path, timeout_raw = argv[1:5]
    core = load_core(core_path)
    payload = read_payload(input_path)
    rubric = rubric_flag
    if not rubric:
        candidate = payload.get("rubric")
        rubric = candidate if isinstance(candidate, str) else ""
    if rubric not in RUBRICS:
        usage_error(
            "rubric must be one of %s (pass --rubric or set the rubric field)"
            % ", ".join(sorted(RUBRICS))
        )
    timeout = parse_timeout(timeout_raw)

    armed = timeout > 0 and hasattr(signal, "SIGALRM") and hasattr(signal, "setitimer")
    if armed:
        signal.signal(signal.SIGALRM, _on_alarm)
        signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        try:
            decision = core.guard(
                payload,
                RUBRICS[rubric],
                threshold=CONFIDENCE_THRESHOLD,
                block_options=("unsafe",),
                instructions=INSTRUCTIONS[rubric],
            )
        finally:
            if armed:
                signal.setitimer(signal.ITIMER_REAL, 0)
        verdict, reason = map_decision(core, decision, rubric)
        emit(verdict, decision.confidence, decision.route, reason)
        return 0
    except _Deadline:
        emit("ask_human", 0.0, None, "timeout: no verdict within %ss" % timeout)
        return 0
    except Exception as exc:
        emit("ask_human", 0.0, None, "core_error: %s: %s" % (type(exc).__name__, exc))
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
exit "$rc"
