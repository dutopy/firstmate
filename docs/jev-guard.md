# The Jev advisory classifiers

The `jev` classifiers are thin, advisory tools over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
Each gives firstmate one typed second opinion on one narrow, recurring question, and each fails safe: every uncertainty resolves to the conservative default, never to a silent action.
The scripts' headers own their exact flags, environment keys, input handling, and output shape; this page owns the contract they are held to.

## Advisory only, and below every hard rule

A classifier carries no authority and decides nothing.

- It never interrupts, relaunches, or otherwise controls a worker.
- It never overrides a hard rule, never bypasses a guard, a gate, or a refusal, and never merges without the captain.
- It never turns an uncertain or failed answer into an action: uncertainty always resolves to "judge it yourself".
- It runs one question about one item, never on every tool call and never over a list of items.

## Shared core

Each classifier imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_NONCONVERGENCE_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the wrapper adds no second HTTP client and copies no API contract.
It reads the same `TYPESAFE_API_KEY` the typed dispatch resolution reads, from the environment or a `TYPESAFE_API_KEY=` line in `$FM_HOME/.env`.
It never sends a list of items to classify: each call asks the model one atomic forced-choice question about exactly one worker.

## Fail-safe boundary and exit codes

Every path that produced no usable verdict resolves to verdict `progressing`, flag `review_history`, exit 0, with the cause named in `reason`:

- confidence below 0.9;
- a confidence the model reports outside the finite 0..1 range (non-finite, negative, or above 1);
- a missing or rejected API key;
- any API or network error;
- a malformed success response;
- a verdict the rubric does not define;
- an unreadable shared core;
- the wall-clock bound (`FM_JV_NONCONVERGENCE_TIMEOUT`, default 20s).

An error never escalates.
A `stalled_looping` verdict requires a high-confidence answer, never the absence of one, so a broken call, a missing key, or an unusable confidence can only hand the history back to firstmate.

Exit 2 is reserved for a usage error: an unknown flag, a missing flag value, a non-positive or non-integer `--lines`, `--task` together with a history file, missing `python3`, or a named history or task status file that cannot be read.
A usage error prints nothing on stdout and makes no network call.

The wrapper validates the confidence boundary itself rather than trusting the shared gate, so a non-finite or out-of-range answer can never compare as passing and can never become an automatic escalation.
The emitted confidence is always a finite number in [0, 1] and the output is always strict JSON, so no `NaN` or `Infinity` literal can reach stdout.

## The non-convergence detector

`bin/fm-jev-nonconvergence.sh` reads one worker's recent status history and judges whether it is converging:

```json
{"verdict": "progressing|stalled_looping", "confidence": 0.0, "flag": "action", "reason": "text", "features": {}}
```

| verdict           | flag                 | what firstmate does with it                                                       |
| ----------------- | -------------------- | --------------------------------------------------------------------------------- |
| `progressing`     | `continue`           | No recovery action; keep supervising normally.                                    |
| `stalled_looping` | `escalate_recovery`  | Escalate through `stuck-crewmate-recovery`, never silently.                       |
| default (no usable verdict) | `review_history` | Judge the history yourself; never an automatic escalation.                 |
| (no model call)   | `terminal`           | The window ends in a terminal declaration; there is nothing to judge.             |
| (no model call)   | `insufficient_history` | Fewer than two events in the window; there is nothing to judge.                |

The input is the append-only `<state>: <note>` event log a task writes to `state/<id>.status`, supplied as a file, on stdin, or by task id with `--task <id>`.
`--lines <n>` (default 12) bounds the window to the last n events, each event being one cycle.

### Deterministic features, extracted in code

The wrapper itself extracts the stall signals; no feature extraction is delegated to the model, and the model sees the features alongside the raw window:

- `repeated_notes` and `max_note_repeat`: the same normalized note repeated across the window ("the same finding, again").
- `no_state_change`: one distinct state across the whole window.
- `oscillating` and `oscillation_pair`: the last four entries alternate between the same two states or the same two notes, the fix/revert and blocked/working loop.
- `state_sequence`, `cycles`, and `distinct_states`: the raw shape the verdict was made over.

`terminal_state` is reported when the window ends in a `done` declaration, or in a single `failed` declaration that stopped the worker.
A failed tail that repeats or oscillates is not terminal: it is exactly the loop this detector exists to catch, so it is judged normally.
A window with fewer than two events is never judged at all.

### One question, then the escalation doctrine

Each judged window sends exactly one forced-choice question with the two verdicts as its only options.
The confidence floor is 0.9.
A `stalled_looping` answer at or above the floor comes back with `escalate_recovery`; the caller then follows the `stuck-crewmate-recovery` order: peek the pane and the steering inbox, answer a question the brief already answers, interrupt and redirect, and relaunch only a genuinely wedged worker.
A `stalled_looping` answer below the floor comes back as `progressing` with `review_history`, and the model's answer stays visible in `reason`; the detector never escalates on an uncertain answer.

## Precedence

The captain's explicit instruction outranks everything here.
A live worker's own evidence and the current-state read outrank the detector: a `progressing` verdict never green-lights a wedged worker, and a `stalled_looping` verdict never overrides a validation run that is still authoritatively working.
The detector is a recovery hint for a suspicious history, nothing more.

## Verification

`tests/fm-jev-nonconvergence.test.sh` drives the public interface against `tests/assets/jev-nonconvergence-fake-typesafe.py`, a fake System One server bound to loopback on an ephemeral port.
It covers both verdicts, the deterministic feature extraction (repeated notes, a frozen state window, a state-level and a note-level alternation), the one-atomic-question request shape, a low-confidence answer that must fall back to `progressing` plus `review_history`, a non-finite or out-of-range confidence that must resolve to the same fail-safe verdict without escalating, an API error, a malformed response, an unexpected verdict, the wall-clock bound, a missing key, the `.env` key fallback, `--task` resolution, `--lines` windowing, both no-model-call shortcuts (insufficient history and a terminal declaration), and every usage error.
No case reaches the real network, and each judged case asserts exactly one call.
