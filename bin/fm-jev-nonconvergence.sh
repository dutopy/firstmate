#!/usr/bin/env bash
# fm-jev-nonconvergence.sh - advisory, fail-safe non-convergence detector for
# one worker's recent status history, backed by typesafe.ai's System One model
# (Jev) through the shared jev_decide core.
#
# Usage:
#   fm-jev-nonconvergence.sh [<history-file>|-] [--lines <n>]
#   fm-jev-nonconvergence.sh --task <id> [--lines <n>]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_NONCONVERGENCE_CORE:-$FM_HOME/data/jev_decide.py}, imported by path
#   with importlib, so there is exactly one HTTP client and exactly one
#   confidence gate. This wrapper re-implements neither the client nor
#   TypeSafe's API contract, and it makes no change to the shared core.
#
# Input: one worker's recent status-event history - the same append-only
#   `<state>: <note>` lines a task logs in state/<id>.status. Pass a file, "-"
#   (or nothing) for stdin, or `--task <id>` to read
#   ${FM_STATE_OVERRIDE:-$FM_HOME/state}/<id>.status. --lines <n> (default 12)
#   bounds the window to the last n events; every event is one cycle.
#   Blank lines are ignored, and a line whose leading token is not a state
#   identifier is read as state `unknown` so nothing is silently dropped.
#
# Deterministic features first, in code: the wrapper itself extracts the
#   stall signals - repeated identical normalized notes, no state change across
#   the window, and an oscillating state (or note) pair such as fix then revert
#   or blocked then working. Those features, plus the raw window, are the whole
#   model state. No feature extraction is delegated to the model.
#
# One atomic question: a single forced-choice question asks the model to place
#   this ONE worker in exactly one verdict, progressing or stalled_looping.
#   The wrapper never asks the model to classify several workers or to rank a
#   list; the history is evidence for one judgment.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"verdict":"progressing|stalled_looping","confidence":<0..1>,"flag":"<action>","reason":"<text>","features":{...}}
#   The `flag` is the advisory action firstmate may take for the verdict:
#     continue              - progressing at or above the confidence floor; no
#                             recovery action and no escalation.
#     escalate_recovery     - stalled_looping at or above the confidence floor;
#                             escalate through stuck-crewmate-recovery (peek
#                             the pane and the steering inbox, answer a question
#                             the brief already answers, interrupt and redirect,
#                             then relaunch a genuinely wedged worker). Never
#                             silent.
#     review_history        - no usable verdict (confidence below the floor, or
#                             any fail-safe path); firstmate judges the history
#                             itself. Never an automatic escalation.
#     terminal              - the window ends in a terminal declaration (done,
#                             or a single failed that stopped the worker), so
#                             there is nothing to judge; no model call. A
#                             repeated or oscillating failed tail is a stall
#                             candidate and is judged normally.
#     insufficient_history  - fewer than two events in the window, so there is
#                             nothing to judge; no model call.
#   `features` is the deterministic evidence the verdict was made over, so a
#   caller can inspect it without re-parsing the log.
#
# Fail-safe: every path that produced no usable verdict - confidence below 0.9
#   or any non-finite or out-of-range confidence (NaN, infinity, negative, or
#   above 1), a missing or rejected API key, any API or network error, a
#   malformed success response, a verdict the rubric does not define, an
#   unreadable shared core, or the wall-clock bound
#   (FM_JV_NONCONVERGENCE_TIMEOUT, default 20s) - resolves to verdict
#   progressing, flag review_history, exit 0, with the specific cause named in
#   `reason`. An error NEVER auto-escalates: a stalled_looping verdict requires
#   a high-confidence answer, never an absence of one.
#
# The wrapper validates the confidence itself, so a stale shared core that
#   returned a non-finite confidence cannot reintroduce an escalation: any
#   confidence that is not a finite number in [0, 1] is treated exactly like an
#   absent verdict, and the emitted confidence is always a plain JSON number.
#
# Exit: 0 for every judged outcome, including every fail-safe and both
#   no-model-call shortcuts. 2 for a usage error: an unknown flag, a missing
#   flag value, a --lines outside the supported 1..10000 range, --task together
#   with a history file, missing python3, or a named history or task status file
#   that cannot be read. A usage error prints nothing on stdout and makes no
#   network call.
#
# Environment:
#   FM_JV_NONCONVERGENCE_CORE     shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_NONCONVERGENCE_TIMEOUT  wall-clock bound in seconds (default 20; 0
#                                 disables). The value must be finite and
#                                 non-negative: a non-finite or unrepresentable
#                                 bound is a fail-safe (progressing plus
#                                 review_history), never an unbounded call.
#   FM_STATE_OVERRIDE             state directory that --task resolves against
#                                 (default $FM_HOME/state)
#   TYPESAFE_API_KEY              from this process environment, else a
#                                 TYPESAFE_API_KEY= line in $FM_HOME/.env read
#                                 with fmx_env_get (the environment wins). The
#                                 key reaches the one python child through its
#                                 environment, because the shared core reads it
#                                 there; it never appears on argv and nothing
#                                 logs or writes it.
#   TYPESAFE_BASE_URL             passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never interrupts, relaunches, or otherwise
#   controls a worker, never overrides a hard rule, never merges, and is not run
#   on every tool call. docs/jev-guard.md owns the contract and the escalation
#   mapping.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_NONCONVERGENCE_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_NONCONVERGENCE_TIMEOUT:-20}"
DEFAULT_LINES=12

die() { printf 'fm-jev-nonconvergence: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

INPUT='' TASK='' LINES=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task)
      [ $# -ge 2 ] || die "--task needs a value"
      [ -z "$TASK" ] || die "one --task only"
      TASK=$2; shift 2 ;;
    --lines)
      [ $# -ge 2 ] || die "--lines needs a value"
      [ -z "$LINES" ] || die "one --lines only"
      LINES=$2; shift 2 ;;
    -) [ -z "$INPUT" ] || die "one input only"; INPUT='-'; shift ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$INPUT" ] || die "one input only"; INPUT=$1; shift ;;
  esac
done

[ -z "$TASK" ] || [ -z "$INPUT" ] || die "--task and a history file are mutually exclusive"

if [ -z "$LINES" ]; then
  LINES=$DEFAULT_LINES
else
  case "$LINES" in
    ''|*[!0-9]*) die "--lines must be a positive integer" ;;
  esac
  [ "$LINES" -ge 1 ] || die "--lines must be a positive integer"
fi

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

if [ -n "$TASK" ]; then
  INPUT="$STATE/$TASK.status"
elif [ -z "$INPUT" ] || [ "$INPUT" = '-' ]; then
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-nonconvergence.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read the status history from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
python3 - "$CORE" "$INPUT" "$LINES" "$TIMEOUT" "$TASK" <<'PY' || rc=$?
"""Judge one worker's convergence from its recent status history via Jev."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import re
import signal
import sys
from collections import Counter

CONFIDENCE_THRESHOLD = 0.9
DEFAULT_VERDICT = "progressing"
FALLBACK_FLAG = "review_history"
MAX_LINES = 10000
VERDICT_FLAGS = {
    "progressing": "continue",
    "stalled_looping": "escalate_recovery",
}
STATE_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
INSTRUCTIONS = (
    "Judge whether the ONE worker described by the state is progressing or "
    "stalled in a loop. Read state.features first - the deterministic signals "
    "(repeated identical notes, no state change across the window, and an "
    "oscillating state or note pair) - then state.history, the recent status "
    "events in order. Treat any new state, any new note, a resolved decision, "
    "or an unblocked event as progress. Choose exactly one verdict."
)
CRITERIA = {
    "progressing": {
        "what": (
            "The worker is making forward progress: its recent events show a new "
            "state, a new note, a resolved decision, or an unblocked event, and "
            "no finding repeats across the window."
        ),
        "not_for": (
            "A worker that repeats the same note, never changes state across the "
            "window, or alternates between the same two states without closing "
            "either one."
        ),
        "examples": [
            "a state that differs from the previous event",
            "a blocker or a decision that is resolved",
            "a distinct note naming concrete new work each cycle",
        ],
    },
    "stalled_looping": {
        "what": (
            "The worker is stuck in a loop: the same finding is reported "
            "repeatedly, the state does not change across the window, or it "
            "alternates between the same two states (for example fix then revert, "
            "or blocked then working) without resolving either one."
        ),
        "not_for": (
            "A worker whose events show genuine forward motion, even slow or "
            "noisy, or one that has just declared done or failed."
        ),
        "examples": [
            "the same note repeating across three cycles",
            "no state change across the whole window",
            "a fix/revert or blocked/working alternation",
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
    as if it cleared the floor and can never turn into an automatic escalation.
    """
    try:
        confidence = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
        return None
    return confidence


def emit(verdict, confidence, flag, reason, features):
    safe = valid_confidence(confidence)
    payload = {
        "verdict": verdict,
        "confidence": round(safe if safe is not None else 0.0, 4),
        "flag": flag,
        "reason": reason[:400],
        "features": features,
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


def read_history(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read().splitlines()
    except OSError as exc:
        raise UsageError("cannot read the status history: %s" % exc) from None


def parse_lines(raw):
    """The window size as a positive integer inside a finite range."""
    try:
        count = int(raw)
    except (TypeError, ValueError):
        raise UsageError("--lines must be a positive integer") from None
    if count < 1 or count > MAX_LINES:
        raise UsageError(
            "--lines must be a positive integer no greater than %d" % MAX_LINES
        )
    return count


def parse_timeout(raw):
    """The wall-clock bound as a finite, non-negative number of seconds.

    0 disables the bound by contract. NaN and infinity reach neither the timer
    nor the request: the value is rejected here so the run can fail safe with
    the real history instead of falling through to an unbounded call.
    """
    try:
        timeout = float(raw)
    except (TypeError, ValueError):
        raise ValueError("timeout must be a finite number of seconds") from None
    if not math.isfinite(timeout):
        raise ValueError("timeout must be a finite number of seconds")
    if timeout < 0:
        raise ValueError("timeout must not be negative")
    return timeout


def arm_deadline(timeout):
    """Arm the wall-clock bound; return True when a timer is armed.

    A finite timeout the platform still cannot represent (a very large value,
    for example) raises out of here into the run's fail-safe path, so an
    unusable bound can neither leave the call unbounded nor escape as a raw
    traceback.
    """
    if timeout <= 0 or not hasattr(signal, "SIGALRM") or not hasattr(signal, "setitimer"):
        return False
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)
    return True


def parse_event(line):
    text = line.rstrip("\r\n").strip()
    state_part, sep, note = text.partition(":")
    state = state_part.strip().lower()
    if sep and STATE_RE.match(state):
        return {"state": state, "note": note.strip(), "line": text}
    return {"state": "unknown", "note": text, "line": text}


def select_window(lines, count):
    events = [parse_event(line) for line in lines if line.strip()]
    return events[-count:]


def normalize_note(note):
    return " ".join(note.split()).lower()


def detect_alternation(sequence):
    """True with the alternating pair when the last four entries are A B A B."""
    if len(sequence) < 4:
        return False, None
    tail = sequence[-4:]
    if not tail[0] or tail[0] == tail[1] or tail[0] != tail[2] or tail[1] != tail[3]:
        return False, None
    return True, " <> ".join(sorted((tail[0], tail[1])))


def terminal_state_of(states):
    """The state that ends the window, or None when it still needs judging.

    `done` always ends it. A single `failed` is a worker that stopped on a
    failure and is handled by the ordinary lifecycle, but a failed tail that
    repeats or oscillates is exactly the loop this detector exists to catch, so
    that case stays open for the model.
    """
    if not states:
        return None
    last = states[-1]
    if last == "done":
        return last
    if last == "failed" and states.count("failed") == 1:
        return last
    return None


def extract_features(events):
    """Deterministic stall features, computed here and never by the model."""
    cycles = len(events)
    states = [event["state"] for event in events]
    notes = [normalize_note(event["note"]) for event in events]
    counts = Counter(note for note in notes if note)
    repeated = [
        {"note": note, "count": count}
        for note, count in counts.items()
        if count >= 2
    ]
    repeated.sort(key=lambda item: (-item["count"], item["note"]))
    state_oscillating, state_pair = detect_alternation(states)
    note_oscillating, note_pair = detect_alternation([n for n in notes if n])
    distinct = len(set(states))
    return {
        "cycles": cycles,
        "distinct_states": distinct,
        "state_sequence": ">".join(states),
        "no_state_change": cycles >= 2 and distinct == 1,
        "repeated_notes": repeated,
        "max_note_repeat": repeated[0]["count"] if repeated else 0,
        "oscillating": state_oscillating or note_oscillating,
        "oscillation_pair": state_pair or note_pair,
        "terminal_state": terminal_state_of(states),
    }


def classify(core, task, features, events):
    payload = {
        "task": task or "unknown",
        "features": features,
        "history": [event["line"] for event in events],
    }
    decision = core.guard(
        payload,
        CRITERIA,
        threshold=CONFIDENCE_THRESHOLD,
        block_options=("stalled_looping",),
        instructions=INSTRUCTIONS,
    )
    confidence = valid_confidence(decision.confidence)
    route = decision.route
    if confidence is None:
        return (
            DEFAULT_VERDICT,
            0.0,
            FALLBACK_FLAG,
            "invalid confidence %r; never escalating on an unusable answer"
            % (decision.confidence,),
        )
    if decision.verdict is core.Verdict.BLOCK and route == "stalled_looping":
        return (
            "stalled_looping",
            confidence,
            "escalate_recovery",
            "high-confidence stalled_looping; escalate through stuck-crewmate-recovery",
        )
    if decision.verdict is core.Verdict.PROCEED and route == "progressing":
        return "progressing", confidence, VERDICT_FLAGS["progressing"], "ok"
    if route is not None and route not in CRITERIA:
        reason = "unexpected verdict %r; keeping the fail-safe verdict" % (route,)
    elif route is not None:
        reason = (
            "confidence %s below threshold %s for %s; never escalating on an "
            "uncertain answer" % (confidence, CONFIDENCE_THRESHOLD, route)
        )
    else:
        reason = decision.reason or "no usable verdict"
    return DEFAULT_VERDICT, confidence, FALLBACK_FLAG, reason


def run(core_path, input_path, lines_raw, timeout_raw, task):
    try:
        count = parse_lines(lines_raw)
        lines = read_history(input_path)
    except UsageError as exc:
        sys.stderr.write("fm-jev-nonconvergence: %s\n" % exc)
        return 2
    events = select_window(lines, count)
    features = extract_features(events)
    if features["cycles"] < 2:
        emit(
            DEFAULT_VERDICT,
            0.0,
            "insufficient_history",
            "no model call: %d status event(s) in the window; at least two are "
            "needed to judge convergence" % features["cycles"],
            features,
        )
        return 0
    if features["terminal_state"]:
        emit(
            DEFAULT_VERDICT,
            0.0,
            "terminal",
            "no model call: the window ends in the terminal state %s"
            % features["terminal_state"],
            features,
        )
        return 0
    try:
        core = load_core(core_path)
        timeout = parse_timeout(timeout_raw)
        armed = arm_deadline(timeout)
    except Exception as exc:
        emit(
            DEFAULT_VERDICT,
            0.0,
            FALLBACK_FLAG,
            "fail_safe: %s: %s" % (type(exc).__name__, exc),
            features,
        )
        return 0
    try:
        try:
            verdict, confidence, flag, reason = classify(core, task, features, events)
        finally:
            if armed:
                signal.setitimer(signal.ITIMER_REAL, 0)
        emit(verdict, confidence, flag, reason, features)
        return 0
    except _Deadline:
        emit(
            DEFAULT_VERDICT,
            0.0,
            FALLBACK_FLAG,
            "timeout: no verdict within %ss" % timeout,
            features,
        )
        return 0
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        emit(
            DEFAULT_VERDICT,
            0.0,
            FALLBACK_FLAG,
            "core_error: %s: %s" % (type(exc).__name__, exc),
            features,
        )
        return 0


if __name__ == "__main__":
    sys.exit(run(*sys.argv[1:6]))
PY

# Exit 2 is a usage error and owns stderr and the empty stdout above. Any other
# unexpected non-zero exit still owes the caller one typed verdict on the
# fail-safe side, because a stall must never be inferred from a broken run.
if [ "$rc" -eq 2 ]; then
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  printf '%s\n' '{"verdict":"progressing","confidence":0.0,"flag":"review_history","reason":"detector did not run; keeping the fail-safe verdict","features":{"cycles":0,"distinct_states":0,"state_sequence":"","no_state_change":false,"repeated_notes":[],"max_note_repeat":0,"oscillating":false,"oscillation_pair":null,"terminal_state":null}}'
fi
exit 0
