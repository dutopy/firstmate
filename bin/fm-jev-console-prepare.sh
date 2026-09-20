#!/usr/bin/env bash
# fm-jev-console-prepare.sh - advisory, fail-safe request preparation for one
# captured Discord console message, backed by typesafe.ai's System One model
# (Jev) through the shared jev_decide core.
#
# Usage:
#   fm-jev-console-prepare.sh [<request.json>|-]
#
# What it is: one thin CLI over the shared core at
#   ${FM_JV_PREPARE_CORE:-$FM_HOME/data/jev_decide.py}, imported by path with
#   importlib, so there is exactly one HTTP client and exactly one confidence
#   gate. This wrapper re-implements neither the client nor TypeSafe's API
#   contract, and it makes no change to the shared core.
#
# Input: one small JSON object describing a single captured captain message,
#   from a file or from "-" (or no positional argument) for stdin:
#     {
#       "message": "<the captain's own words>",
#       "label":   "<configured channel label>",
#       "projects": [{"id": "<registry id>", "summary": "<one line>"}],
#       "tasks":    [{"id": "<task id>", "title": "<backlog title>"}]
#     }
#   `projects` and `tasks` are CODE-BUILT CANDIDATE LISTS from the durable
#   records, and they exist for the select-instead-of-generate rule: the model
#   may only pick one of the values it is shown, so it can never invent a
#   project id or a task id that does not exist. Both may be absent or empty,
#   and then that axis is answered `null` without a question. Never pass a list
#   of messages: this tool answers for exactly one message per call.
#
# One atomic call, up to three narrow questions:
#   - intent: which of state_question, new_work, decision_answer, or chat the
#     message is. This is the name firstmate would otherwise have to derive
#     before it can start.
#   - project: which of the candidate project ids the message is about, or
#     `none`.
#   - entity: which of the candidate task ids the message is about, or `none`.
#   Answering them together costs one request, and no axis can see another's
#   answer.
#
# Output (stdout, exactly one JSON object, keys in this order):
#   {"intent":"<class>","intent_confidence":<0..1>,"project":<id|null>,
#    "entity":<id|null>,"flag":<null|"low_confidence"|"api_error">,
#    "reason":"<text>"}
#   `flag` is null only when every asked axis cleared the confidence floor.
#   `reason` names every axis that was replaced.
#
# Fail-safe: a missing or rejected API key, any API or network error, a
#   malformed or out-of-vocabulary response, a confidence that is not a finite
#   number inside 0..1, an unusable FM_JV_PREPARE_TIMEOUT value (non-finite,
#   negative, or above the ceiling), a host that cannot arm the bound, the
#   wall-clock bound itself, and any answer below the confidence floor all
#   resolve to `intent` unclear with `flag` set and exit 0. The caller then
#   falls back to the captain's raw message, so preparation can never block,
#   delay past its bound, replace, or contradict the message itself.
#
# Wall-clock bound: one finite deadline is the only wait this tool allows, and
#   an invalid value can neither disable it nor overflow it. The numeric input
#   is checked before it reaches the timer, and arming the timer is itself
#   inside the fail-safe path, so a NaN or infinite timeout is a bounded
#   fail-safe and never an unbounded call.
#
# Exit: 0 for every classified outcome, including every fail-safe. 2 for a
#   usage error (an unknown flag, a missing flag value, missing python3, an
#   unreadable shared core, or a threshold outside (0, 1]), which prints
#   nothing on stdout and leaves the caller to fall back to the raw message
#   exactly as if this tool were absent.
#
# Environment:
#   FM_JV_PREPARE_CORE       shared core module path (default $FM_HOME/data/jev_decide.py)
#   FM_JV_PREPARE_TIMEOUT    wall-clock bound in seconds (default 20; 0 disables);
#                            must be a finite number in [0, 3600], and anything
#                            else is a fail-safe, never an unbounded call
#   FM_JV_PREPARE_THRESHOLD  confidence floor as a finite number in (0, 1]
#                            (default 0.9); anything else is a usage error
#   TYPESAFE_API_KEY         from this process environment, else a TYPESAFE_API_KEY=
#                            line in $FM_HOME/.env read with fmx_env_get (the
#                            environment wins). The key reaches the one python
#                            child through its environment, because the shared
#                            core reads it there; it never appears on argv and
#                            nothing logs or writes it.
#   TYPESAFE_BASE_URL        passed through to the core (tests point it at loopback)
#
# Authority: advisory only. This tool never answers a message, never starts,
#   suppresses, or mutates firstmate work, and never changes a task record. It
#   returns a derived reading of one message; the raw message stays the
#   authority and is always kept beside it. docs/discord-conversation-console.md
#   ("Prepared request") owns the packet contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

CORE="${FM_JV_PREPARE_CORE:-$FM_HOME/data/jev_decide.py}"
TIMEOUT="${FM_JV_PREPARE_TIMEOUT:-20}"
THRESHOLD="${FM_JV_PREPARE_THRESHOLD:-0.9}"

die() { printf 'fm-jev-console-prepare: %s\n' "$1" >&2; exit 2; }
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
  INPUT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-jev-console-prepare.XXXXXX") || die "mktemp failed"
  cat > "$INPUT_TMP" || die "could not read JSON from stdin"
  INPUT="$INPUT_TMP"
fi

rc=0
OUT=$(
python3 - "$CORE" "$INPUT" "$TIMEOUT" "$THRESHOLD" <<'PY'

"""Prepare one captured Discord console message through the shared jev_decide core."""
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import sys

DEFAULT_INTENT = "unclear"
INTENTS = {
    "state_question": {
        "what": (
            "Asks where something stands, what is running, what is blocked, "
            "what changed, or what a record currently says. The answer is a "
            "read of current durable records, not new work and not a decision."
        ),
        "examples": [
            "where does the folium email lot stand",
            "what is in flight right now",
            "did the quota fix land",
        ],
    },
    "new_work": {
        "what": (
            "Asks for something to be started, built, changed, fixed, "
            "investigated, reviewed, or delivered, or restates a previously "
            "requested piece of work with a correction or an added condition."
        ),
        "examples": [
            "please make the console answer faster",
            "the third point in my last message is wrong, redo it",
            "audit the discord surfaces",
        ],
    },
    "decision_answer": {
        "what": (
            "Answers or settles a question that was put to the captain: an "
            "approval, a refusal, a choice between offered options, a "
            "postponement, or an instruction that resolves a pending call."
        ),
        "examples": [
            "yes, merge it",
            "no, keep it local",
            "option 2, and do it tomorrow",
        ],
    },
    "chat": {
        "what": (
            "Conversation that carries no request and needs no record lookup "
            "and no work: a greeting, thanks, an acknowledgement, an aside, or "
            "a remark about the situation."
        ),
        "examples": [
            "hello",
            "thanks, good job",
            "ok",
            "I am travelling today",
        ],
    },
}
INTENT_INSTRUCTIONS = (
    "Read the single captain message in `message`, which arrived on the "
    "Discord channel labelled in `label`. Decide what kind of message it is "
    "for firstmate. Choose exactly one intent."
)
PROJECT_INSTRUCTIONS = (
    "Read the single captain message in `message`. If it is about one of the "
    "projects listed below, choose that project; otherwise choose none. Choose "
    "none whenever the message names no project or names something that is not "
    "in the list, and never stretch a project to fit."
)
ENTITY_INSTRUCTIONS = (
    "Read the single captain message in `message`. If it is about one of the "
    "tasks listed below, choose that task; otherwise choose none. Only the "
    "task the message is actually about counts; a task merely mentioned in "
    "passing is not the subject."
)
NONE_OPTION = "none"
NONE_PROJECT = (
    "The message names no project, or its subject is not one of the projects "
    "listed above."
)
NONE_ENTITY = (
    "The message names no task from the list, or its subject is not one of the "
    "tasks listed above."
)
MAX_TIMEOUT_SECONDS = 3600.0
MAX_REASON_CHARS = 400
MAX_CANDIDATES = 200


class _Deadline(BaseException):
    """Raised from the alarm handler; BaseException so the core's own
    `except Exception` retry loop cannot swallow it as a network error."""


class Malformed(Exception):
    """The response is not the typed answer this tool asked for."""


def usage_error(message):
    sys.stderr.write("fm-jev-console-prepare: %s\n" % message)
    raise SystemExit(2)


def emit(intent, confidence, project, entity, flag, reason):
    # allow_nan=False keeps the output strict JSON: a non-finite confidence can
    # never reach stdout even if a caller passes one by mistake.
    value = float(confidence)
    if not math.isfinite(value) or not 0.0 <= value <= 1.0:
        value = 0.0
    payload = {
        "intent": intent,
        "intent_confidence": round(value, 4),
        "project": project,
        "entity": entity,
        "flag": flag,
        "reason": str(reason)[:MAX_REASON_CHARS],
    }
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, allow_nan=False) + "\n")


def fallback(flag, reason):
    emit(DEFAULT_INTENT, 0.0, None, None, flag, reason)
    return 0


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
    if not hasattr(module, "ask") or not hasattr(module, "TypeSafeError"):
        raise ImportError("shared core does not expose ask()/TypeSafeError")
    return module


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


def parse_threshold(raw):
    """The confidence floor as a finite number in (0, 1], or a usage error.

    A floor that is not a finite number inside (0, 1] is refused here rather
    than silently changing the rubric, because a NaN floor would make every
    comparison false and a zero floor would accept any answer.
    """
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ValueError("FM_JV_PREPARE_THRESHOLD must be a finite number in (0, 1]: %s" % raw)
    if not math.isfinite(value) or not 0.0 < value <= 1.0:
        raise ValueError("FM_JV_PREPARE_THRESHOLD must be a finite number in (0, 1]: %s" % raw)
    return value


def arm_deadline(timeout):
    """Arm the one wall-clock bound, or raise when this host cannot arm it."""
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)


def clear_deadline():
    """Disarm the wall-clock bound."""
    signal.setitimer(signal.ITIMER_REAL, 0)


def read_payload(path):
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.loads(handle.read())
    if not isinstance(payload, dict):
        raise ValueError("input must be a JSON object describing one message")
    message = payload.get("message")
    if not isinstance(message, str) or not message.strip():
        raise ValueError("input must carry the captain's non-empty `message` text")
    label = payload.get("label")
    if label is not None and not isinstance(label, str):
        raise ValueError("input `label` must be a string when present")
    return payload


def candidate_list(payload, key):
    """The code-built candidate list for one axis, in the order it was given.

    A malformed candidate entry is dropped rather than guessed at, because a
    candidate the model can select must be a value code already accepts.
    """
    raw = payload.get(key)
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ValueError("input `%s` must be a list when present" % key)
    seen = []
    for index, item in enumerate(raw[:MAX_CANDIDATES]):
        if not isinstance(item, dict):
            continue
        value = item.get("id")
        if not isinstance(value, str) or not value.strip():
            continue
        if value == NONE_OPTION or value in seen:
            continue
        seen.append(value)
    return seen


def option_text(payload, key, text_key, value):
    for item in payload.get(key) or []:
        if isinstance(item, dict) and item.get("id") == value:
            text = item.get(text_key)
            if isinstance(text, str) and text.strip():
                return text.strip()
    return ""


def build_questions(payload):
    """The one request: the intent question, then whichever axis has candidates."""
    questions = {
        "intent": {
            "type": "choice",
            "instructions": INTENT_INSTRUCTIONS,
            "criteria": INTENTS,
        }
    }
    projects = candidate_list(payload, "projects")
    if projects:
        criteria = {}
        for value in projects:
            summary = option_text(payload, "projects", "summary", value)
            criteria[value] = (
                "The message is about the project %s%s."
                % (value, (": " + summary) if summary else "")
            )
        criteria[NONE_OPTION] = NONE_PROJECT
        questions["project"] = {
            "type": "choice",
            "instructions": PROJECT_INSTRUCTIONS,
            "criteria": criteria,
        }
    tasks = candidate_list(payload, "tasks")
    if tasks:
        criteria = {}
        for value in tasks:
            title = option_text(payload, "tasks", "title", value)
            criteria[value] = (
                "The message is about the task %s%s."
                % (value, (": " + title) if title else "")
            )
        criteria[NONE_OPTION] = NONE_ENTITY
        questions["entity"] = {
            "type": "choice",
            "instructions": ENTITY_INSTRUCTIONS,
            "criteria": criteria,
        }
    return questions, projects, tasks


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


def answer_of(response, key):
    """One typed choice answer, or Malformed when the response is not usable."""
    answers = response.get("answers") if isinstance(response, dict) else None
    if not isinstance(answers, dict):
        raise Malformed("no answers object")
    entry = answers.get(key)
    if not isinstance(entry, dict):
        raise Malformed("no %s answer" % key)
    choice = entry.get("choice")
    if not isinstance(choice, str):
        raise Malformed("%s answer has no choice" % key)
    confidence = valid_confidence(entry.get("confidence"))
    if confidence is None:
        raise Malformed(
            "%s confidence %r is not a finite number inside 0..1"
            % (key, entry.get("confidence"))
        )
    return choice, confidence


def show(value):
    return ("%g" % value) if isinstance(value, float) else str(value)


def prepare(core, payload, threshold):
    questions, projects, tasks = build_questions(payload)
    state = {"message": str(payload.get("message") or ""), "label": str(payload.get("label") or "")}
    response = core.ask(state, questions)

    intent_choice, intent_confidence = answer_of(response, "intent")
    notes = []
    degraded = False
    if intent_choice not in INTENTS:
        return DEFAULT_INTENT, 0.0, None, None, "api_error", (
            "malformed response: unknown intent %r" % (intent_choice,)
        )
    if intent_confidence >= threshold:
        intent = intent_choice
    else:
        intent = DEFAULT_INTENT
        degraded = True
        notes.append(
            "intent %s at confidence %s is below the %s floor"
            % (intent_choice, show(intent_confidence), show(threshold))
        )

    project = None
    if projects:
        choice, confidence = answer_of(response, "project")
        if choice not in projects and choice != NONE_OPTION:
            return DEFAULT_INTENT, 0.0, None, None, "api_error", (
                "malformed response: unknown project %r" % (choice,)
            )
        if choice != NONE_OPTION and confidence >= threshold:
            project = choice
        elif choice != NONE_OPTION:
            degraded = True
            notes.append(
                "project %s at confidence %s is below the %s floor"
                % (choice, show(confidence), show(threshold))
            )

    entity = None
    if tasks:
        choice, confidence = answer_of(response, "entity")
        if choice not in tasks and choice != NONE_OPTION:
            return DEFAULT_INTENT, 0.0, None, None, "api_error", (
                "malformed response: unknown task %r" % (choice,)
            )
        if choice != NONE_OPTION and confidence >= threshold:
            entity = choice
        elif choice != NONE_OPTION:
            degraded = True
            notes.append(
                "task %s at confidence %s is below the %s floor"
                % (choice, show(confidence), show(threshold))
            )

    flag = "low_confidence" if degraded else None
    reason = "; ".join(notes) if notes else "ok"
    return intent, intent_confidence, project, entity, flag, reason


def run(core_path, input_path, timeout_raw, threshold_raw):
    try:
        threshold = parse_threshold(threshold_raw)
    except ValueError as exc:
        usage_error(str(exc))
    try:
        core = load_core(core_path)
        payload = read_payload(input_path)
        timeout = parse_timeout(timeout_raw)
    except Exception as exc:
        return fallback("api_error", "fail_safe: %s: %s" % (type(exc).__name__, exc))
    if timeout > 0:
        try:
            arm_deadline(timeout)
        except Exception as exc:
            # A bound that cannot be armed must not become an unbounded wait:
            # this fail-safe is decided before the shared core makes any call.
            return fallback(
                "api_error",
                "fail_safe: could not arm the %ss wall-clock bound: %s: %s"
                % (timeout, type(exc).__name__, exc),
            )
    try:
        try:
            result = prepare(core, payload, threshold)
        finally:
            if timeout > 0:
                clear_deadline()
        emit(*result)
        return 0
    except _Deadline:
        return fallback("api_error", "timeout: no answer within %ss" % show(timeout))
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:
        detail = str(exc) if isinstance(exc, getattr(core, "TypeSafeError", ())) else "%s: %s" % (type(exc).__name__, exc)
        return fallback("api_error", "api_error: %s" % detail)


if __name__ == "__main__":
    sys.exit(run(*sys.argv[1:5]))
PY
) || rc=$?
# A classified outcome, including every fail-safe, already printed its one JSON
# object and exited 0. Exit 2 is a usage or environment error, which prints
# nothing on stdout: the caller then falls back to the raw message exactly as if
# this tool were absent.
[ "$rc" -eq 0 ] || exit "$rc"
printf '%s\n' "$OUT"
