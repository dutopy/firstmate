# The Jev advisory classifiers

`bin/fm-jev-guard.sh` is a thin, advisory classifier over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
It gives firstmate one typed second opinion before a consequential action, and it fails safe: every uncertainty resolves to a question for the captain, never to a silent advance.
The script's header owns the exact flags, environment keys, input handling, and output shape; this page owns the contract the guard is held to.

`bin/fm-jev-blocker.sh` and `bin/fm-jev-lane.sh` are two thin, advisory classifiers over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
Each gives firstmate one typed second opinion on one narrow, recurring question, and each fails safe: every uncertainty resolves to the captain or to the conservative default, never to a silent action.
The scripts' headers own their exact flags, environment keys, input handling, and output shape; this page owns the contract they are held to.

The `jev` classifiers are thin, advisory tools over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
Each gives firstmate one typed second opinion on one narrow, recurring question, and each fails safe: every uncertainty resolves to the conservative default, never to a silent action.
The scripts' headers own their exact flags, environment keys, input handling, and output shape; this page owns the contract they are held to.


`bin/fm-jev-fred-preflight.sh` is a thin, advisory classifier over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
It gives Fred's Folium work one typed second opinion before an action is taken, and it fails safe: every uncertainty resolves to the conservative class, never to a silent wave-through.
The script's header owns the exact flags, environment keys, input handling, and output shape; this page owns the contract the pre-flight is held to.

## Advisory only, and below every hard rule

The guard never carries authority.

- It never overrides a hard rule.
  It never merges without the captain, never writes to a project, and never bypasses a guard, a gate, or a refusal.
- `block` and `ask_human` are escalations to the captain, not enforcement actions.
  A `block` says the model read the action as destructive, irreversible, or secret-exposing; the guard itself stops nothing.
  An `ask_human` says the model could not decide, which is the correct outcome for a missing key, an API failure, a timeout, or any answer below the confidence floor.
- `proceed` is a recommendation.
  Firstmate still owns the decision, and every other applicable rule still applies unchanged.
- The guard is not run on every tool call.
  It answers two narrow, consequential questions, and they are the recommended call sites:
  - before a merge, classifying the pending change as documentation-only, behavior-bearing, or unsafe;
  - before dispatching a task, classifying the request as routine, as needing the captain's call, or as unsafe.
- The guard reads the same `TYPESAFE_API_KEY` the typed dispatch resolution uses, from the environment or `$FM_HOME/.env`.
  An absent or rejected key is a fail-safe, not an error: it yields a typed `ask_human` with exit 0 and no network call.
  Only a usage or environment error exits 2, exactly as the fail-safe boundary below lists.

Neither classifier carries authority.

- Neither ever overrides a hard rule.
  Neither merges without the captain, neither writes to a project, neither bypasses a guard, a gate, or a refusal, and neither suppresses a wake or starts work on its own.
- A `suppress_wake` flag never suppresses a wake a hard rule requires.
  It marks the classifier's own high-confidence fixture-noise verdict, and firstmate still decides.
- A lane is a routing recommendation.
  The captain's explicit instruction and the project registry both outrank it.
- An `arfal` result only marks a request dormant.
  It never activates, launches, or funds ARFAL.
- Neither classifier runs on every tool call.
  Each answers one question about exactly one item.

A classifier carries no authority and decides nothing.

- It never decides a finding in place of the reviewer or the captain.
- It never closes, resolves, answers, or posts a finding.
- It never trims the finding list: every finding it sees comes back with a severity, and a flagged or cosmetic one stays listed.
- It never authorizes or blocks a merge, and it never bypasses a guard, a gate, or a refusal.
- It runs one question about one item, never on every tool call and never over a list of items.

The non-convergence detector carries no authority either.

- It never interrupts, relaunches, or otherwise controls a worker.
- It never overrides a hard rule, never bypasses a guard, a gate, or a refusal, and never merges without the captain.
- It never turns an uncertain or failed answer into an action: uncertainty always resolves to "judge it yourself".
- It runs one question about one worker, never on every tool call and never over a list of workers.


The pre-flight carries no authority, and it changes nothing.

- It never takes, authorizes, or blocks an action.
  `proceed` is a recommendation on the standing path, `hold_for_review` is a request to hold the action for the ordinary human review, and `human_portal` is a request to route it to the human portal instead of letting Fred take it alone.
  Firstmate still owns every decision, and every other applicable rule still applies unchanged.
- An `irreversible_or_secret` verdict never becomes permission to act, and a `routine_reversible` verdict never widens what Fred was already allowed to do.
- It never overrides a hard rule, never merges without the captain, never writes to a project, and never bypasses a guard, a gate, or a refusal.
- It classifies exactly one intended action per call and is not run on every tool call.

## Read-only by construction

The pre-flight is an advisory reader, so it performs no live mutation: it opens no Folium gateway, sends no Discord message, changes no service, and reads no Folium credential or secret.
It touches only the input JSON, the shared core, and its own `TYPESAFE_API_KEY`, and the single file it writes of its own is a temporary copy of stdin input that it removes on the way out.
It also disables Python's bytecode cache, so importing the shared core cannot leave a cache beside it in the home that owns it.
`tests/fm-jev-fred-preflight.test.sh` proves both halves in a home the tool has never run in before: the home is exactly as it was after a run, and no temporary artifact is left behind.

## Shared core

The guard imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_GUARD_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the guard adds no second HTTP client and no second copy of the API contract.
The guard makes zero change to the core; improving the client or the gate happens in the core, once, for every caller.

Both classifiers import the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_BLOCKER_CORE` and `FM_JV_LANE_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, which rejects a non-finite or out-of-range confidence as an `ask_human` outcome at the owner, so neither wrapper adds a second HTTP client and neither copies the API contract.
Both read the same `TYPESAFE_API_KEY` the typed dispatch resolution reads, from the environment or a `TYPESAFE_API_KEY=` line in `$FM_HOME/.env`.
Neither ever sends a list of items: each call asks the model one atomic forced-choice question about exactly one block or one request.

Each classifier imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_FINDING_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the wrapper adds no second HTTP client and copies no API contract.
It reads the same `TYPESAFE_API_KEY` the typed dispatch resolution reads, from the environment or a `TYPESAFE_API_KEY=` line in `$FM_HOME/.env`.
It never sends a list: each call asks the model one atomic forced-choice question about exactly one finding.

The detector imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_NONCONVERGENCE_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the wrapper adds no second HTTP client and copies no API contract.
It reads the same `TYPESAFE_API_KEY` the typed dispatch resolution reads, from the environment or a `TYPESAFE_API_KEY=` line in `$FM_HOME/.env`.
It never sends a list of items to classify: each call asks the model one atomic forced-choice question about exactly one worker.

Every numeric input is validated at both ends.
At the single owner, `ask()` coerces a non-finite, zero, negative, or absurd `timeout` and a non-integer or out-of-range `retries` to its safe finite defaults, and `guard()` coerces a non-finite, zero, negative, or above-one `threshold` to its safe default, so a NaN wait bound can never reach the socket and a NaN confidence floor can never turn a weak answer into a `proceed`.
The core is local material outside this repository, so that guard is exercised against `$FM_HOME/data/jev_decide.py` directly rather than committed here; every wrapper also re-validates the numerics it passes at its own boundary, so a stale core cannot reintroduce an unvalidated value.
A wall-clock bound that is non-finite, negative, or above its ceiling, and a host that cannot arm the bound, are fail-safes in every wrapper: the value is checked before it reaches the timer, arming the timer is itself inside the fail-safe path, and a NaN never silently arms nothing.


The pre-flight imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_FRED_PREFLIGHT_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the pre-flight adds no second HTTP client and no second copy of the API contract.
It asks one atomic forced-choice question per call, makes zero change to the core, and improving the client or the gate happens in the core, once, for every caller.
The wrapper validates the confidence it reports itself, so a stale core cannot reintroduce a routine verdict either.

## Fail-safe boundary and exit codes

Confidence below the floor, a missing or rejected API key, any API or network error, a malformed success response, an unusable `FM_JV_GUARD_TIMEOUT` value (non-finite, negative, or above the ceiling), a host that cannot arm the bound, and the wall-clock bound itself all resolve to `ask_human` with exit 0.
There is no silent proceed and no silent block.
Exit 2 is reserved for a usage or environment error - invalid input JSON, an unknown or missing rubric, missing `python3`, or an unreadable shared core - and it prints nothing on stdout and makes no network call.

Every path that produced no usable verdict or route resolves to the conservative default with its flag and exits 0:

- confidence below 0.9;
- a confidence that is not a finite number in [0, 1] (NaN, infinity, negative, or above 1);
- a missing or rejected API key;
- any API or network error;
- a malformed success response;
- invalid or unreadable input JSON;
- an unreadable shared core;
- an unusable `FM_JV_BLOCKER_TIMEOUT` / `FM_JV_LANE_TIMEOUT` value (non-finite, negative, or above the ceiling), a host that cannot arm the bound, or the wall-clock bound itself (default 20s).

There is no silent suppression, no silent retry, and no silent lane assignment.
Each wrapper validates the confidence at its own boundary, so a stale shared core that returned a non-finite or out-of-range confidence cannot reintroduce a suppression or a silent lane: any such value is treated exactly like an absent verdict, and the emitted confidence is always a plain JSON number, never `NaN` or `Infinity`.
Exit 2 is reserved for a usage error - an unknown flag, a missing flag value, or missing `python3` - which prints nothing on stdout and makes no network call.
Invalid input JSON and an unreadable core are fail-safes here rather than usage errors, because either could otherwise suppress a wake or misroute a request, and a safe typed answer is always available.

Every path that produced no usable severity resolves to severity `important`, flag `needs_review`, exit 0, with the cause named in `reason`:

- confidence below 0.9;
- a confidence the model reports outside the finite 0..1 range (non-finite, negative, or above 1);
- a missing or rejected API key;
- any API or network error;
- a malformed success response;
- an unexpected severity the rubric does not define;
- an unreadable shared core;
- an unusable `FM_JV_FINDING_TIMEOUT` value (non-finite, negative, or above the ceiling), a host that cannot arm the bound, or the wall-clock bound itself (default 20s).

Exit 2 is reserved for a usage error: an unknown flag, a missing flag value, missing `python3`, an unreadable input file, input that is not valid JSON, input that is not a JSON object, or a JSON object that carries no finding text at all.
A usage error prints nothing on stdout and makes no network call.
This is the deliberate difference from the wake-side classifiers: a usage error is a caller mistake, never a finding's severity, so an empty or malformed finding is reported loudly to the caller instead of being given a default severity.
There is no silent drop either way: a classified path always exits 0 with a typed severity, and a refused path exits 2 with the caller's mistake named.

The wrapper validates the confidence boundary itself rather than trusting the shared gate, so a non-finite or out-of-range answer can never compare as passing.
The emitted confidence is always a finite number in [0, 1] and the output is always strict JSON, so no `NaN` or `Infinity` literal can reach stdout.

Every path that produced no usable verdict resolves to verdict `progressing`, flag `review_history`, exit 0, with the cause named in `reason`:

- confidence below 0.9;
- a confidence the model reports outside the finite 0..1 range (non-finite, negative, or above 1);
- a missing or rejected API key;
- any API or network error;
- a malformed success response;
- a verdict the rubric does not define;
- an unreadable shared core;
- the wall-clock bound (`FM_JV_NONCONVERGENCE_TIMEOUT`, default 20s).

A timeout that is non-finite or otherwise unrepresentable is a fail-safe too, so an invalid or unusable bound can never leave a call unbounded: the numeric input is checked before it reaches the timer, and arming the timer is itself inside the fail-safe path.
The same rule holds for every classifier above: a `FM_JV_GUARD_TIMEOUT`, `FM_JV_BLOCKER_TIMEOUT`, `FM_JV_LANE_TIMEOUT`, `FM_JV_FINDING_TIMEOUT`, `FM_JV_CLASS_TIMEOUT`, or `FM_JV_NONCONVERGENCE_TIMEOUT` value that is NaN, infinite, negative, or absurd is a bounded fail-safe rather than a silently disabled or overflowing bound.
An error never escalates.
A `stalled_looping` verdict requires a high-confidence answer, never the absence of one, so a broken call, a missing key, or an unusable confidence can only hand the history back to firstmate.

Exit 2 is reserved for a usage error: an unknown flag, a missing flag value, a non-positive or non-integer `--lines`, `--task` together with a history file, missing `python3`, or a named history or task status file that cannot be read.
A usage error prints nothing on stdout and makes no network call.

The wrapper validates the confidence boundary itself rather than trusting the shared gate, so a non-finite or out-of-range answer can never compare as passing and can never become an automatic escalation.
The emitted confidence is always a finite number in [0, 1] and the output is always strict JSON, so no `NaN` or `Infinity` literal can reach stdout.


Confidence below the floor, any non-finite or out-of-range confidence, a missing or rejected API key, any API or network error, a malformed success response, invalid or unreadable input JSON, an unreadable shared core, and an invalid wall-clock bound all resolve to verdict `consequential`, flag `hold_for_review`, and exit 0.
There is no silent proceed: no error, timeout, low-confidence answer, or malformed response is ever reported as `routine_reversible`, and the emitted confidence is always a finite number in `[0, 1]` in strict JSON, so a NaN or Infinity answer can never slip past the floor.
Exit 2 is reserved for a usage error - an unknown flag, a missing flag value, or missing `python3` - and it prints nothing on stdout and makes no network call.

The wall-clock bound is part of that boundary rather than an option beside it.
One finite deadline is armed before the call, so the call and its retries can never outlive it, and `FM_JV_FRED_PREFLIGHT_TIMEOUT` must be a finite number of seconds in `(0, 3600]`.
A missing, non-numeric, zero, negative, non-finite, or above-ceiling value is a fail-safe with no network call, and so is a host that cannot arm the deadline: an invalid value can neither disable the bound nor overflow the timer, and the tool never classifies without one.

## What it classifies

Two rubrics ship with the tool, selected by `--rubric` or the input's `rubric` field.

- `merge` classifies a pending merge as `safe_merge` (documentation or comment-only), `needs_human` (code, tests, configuration, CI, dependencies, or another behavior-bearing artifact), or `unsafe` (destructive, irreversible, or secret-exposing).
- `dispatch` classifies requested work as `routine` (the standing delivery posture already covers it), `needs_human` (ambiguous, expanding, or authority-sensitive), or `unsafe` (destructive, irreversible, or security-sensitive).

The verdict is the guard's own typed answer: `proceed` only for the rubric's safe option above the confidence floor, `ask_human` for `needs_human` and for every fail-safe path, and `block` only for an `unsafe` answer at or above that floor.
The model's `route`, its `confidence`, and a short `reason` are reported beside the verdict so the caller can see the evidence rather than only the conclusion.


## The blocker classifier

`bin/fm-jev-blocker.sh` classifies one worker block into exactly one class and reports it as `verdict`:

```json
{"verdict": "real_business_blocker|needs_captain_decision|transient_retryable|test_fixture_noise", "confidence": 0.0, "reason": "text", "flag": "action"}
```

| verdict                  | flag              | what firstmate does with it                                                       |
| ------------------------ | ----------------- | --------------------------------------------------------------------------------- |
| `real_business_blocker`  | `none`            | Handle it as an ordinary blocker; no suppression and no special card.              |
| `needs_captain_decision` | `captain_card`    | Open a keyed captain decision card for the block.                                  |
| `transient_retryable`    | `bounded_retry`   | Retry the bounded number of times the retry doctrine allows, then surface it.      |
| `test_fixture_noise`     | `suppress_wake`   | At or above the confidence floor only: the wake may be suppressed as fixture noise. |
| low confidence or a fail-safe | `surface_captain` | Verdict is `needs_captain_decision`; surface the block to the captain anyway.  |

The confidence floor is 0.9.
A `test_fixture_noise` answer below the floor never suppresses anything: it comes back as `needs_captain_decision` with `surface_captain`.


## The lane router

`bin/fm-jev-lane.sh` classifies one incoming request into exactly one lane and reports it as `route`:

```json
{"route": "system|proapplis|folium|arfal|null", "confidence": 0.0, "reason": "text", "flag": "action"}
```

| route                     | flag          | what firstmate does with it                                                     |
| ------------------------- | ------------- | ------------------------------------------------------------------------------- |
| `system`                  | `none`        | Route the request to firstmate's own tooling and infrastructure lane as usual.   |
| `proapplis`               | `none`        | Route the request to the ProApplis lane as usual.                                |
| `folium`                  | `none`        | Route the request to the Folium lane as usual.                                   |
| `arfal`                   | `dormant`     | Mark the request dormant only; never activate, launch, or fund ARFAL.            |
| low confidence or a fail-safe | `ask_captain` | Route is `null`; ask the captain which lane the request belongs to.          |

The confidence floor is 0.9.
ARFAL is a deliberately dormant lane: a confident `arfal` result parks the request, and no code path here starts ARFAL work.


## The finding severity classifier

`bin/fm-jev-finding.sh` classifies one review finding into exactly one severity and reports it as `severity`:

```json
{"severity": "blocking|important|cosmetic", "confidence": 0.0, "reason": "text", "flag": "action"}
```

| severity    | flag              | what firstmate does with it                                             |
| ----------- | ----------------- | ----------------------------------------------------------------------- |
| `blocking`  | `fix_now`         | The single correction batch must fix it before acceptance.              |
| `important` | `fix_in_batch`    | The same single batch fixes it; acceptance does not depend on it alone. |
| `cosmetic`  | `optional_polish` | List it; it may be deferred without another review round.               |
| default (no usable severity) | `needs_review` | Severity is `important`; the finding stays in the batch for the reviewer to judge. |

- `blocking` is a defect that breaks the contract, security, or conformance to the brief.
- `important` is a real defect that is not blocking for acceptance.
- `cosmetic` is style or a nit.

The confidence floor is 0.9.
A severity answered below the floor is never promoted or dropped: it comes back as `important` with `needs_review`, and the reviewer still sees the model's answer in `reason`.


## One finding list, one correction batch

The classifier exists to feed one correction batch, not to iterate over a review.
Call it once per finding, collect the typed severities, and put every finding into a single correction round ordered `blocking` first, then `important`, then `cosmetic`.

```bash
for finding in findings/*.json; do
  bin/fm-jev-finding.sh "$finding"
done
```

A `needs_review` finding is batched like any other; the flag asks the reviewer to judge it, and never removes it.
`optional_polish` is the only flag that may be deferred, and deferring it still leaves it in the list.


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


## The Fred pre-flight classifier

`bin/fm-jev-fred-preflight.sh` classifies the action Fred intends to take, described before anything acts on it, into exactly one of three classes.

- `routine_reversible` - an ordinary action Fred already performs unattended, whose effect stays inside Fred's own workspace or mailbox, is visible to nobody new, and can be undone or ignored at will.
- `consequential` - an action with a real, externally visible, or hard-to-undo effect that a human should see before it happens, but that is neither destructive, nor secret-exposing, nor a new commitment.
- `irreversible_or_secret` - an action that cannot be undone once taken, or that exposes, moves, or grants access to secret or private material, including deletion, a message that cannot be recalled, an access or credential change, a payment, or a disclosure outside the intended audience.

The verdict is the class itself, and the `flag` is the advisory action for it: `proceed` for `routine_reversible`, `hold_for_review` for `consequential`, and `human_portal` for `irreversible_or_secret`.
The model's `confidence` and a short `reason` are reported beside the verdict, so the caller sees the evidence rather than only the conclusion.
Input is one small JSON object; `action`, `target`, `context`, and `note` are the recommended fields, and the whole object is the model's `state`.

## The console-route classifier

`bin/fm-jev-console-route.sh` classifies one captured Discord console message into exactly one route and reports it as `verdict`:

```json
{"verdict": "fast_answer|full_turn", "confidence": 0.0, "reason": "text", "flag": "action"}
```

| verdict       | flag                 | what the console does with it                                              |
| ------------- | -------------------- | -------------------------------------------------------------------------- |
| `fast_answer` | `answer_from_records` | Answer the message directly from durable records, with no full turn.        |
| `full_turn`   | `full_turn`          | Route the message to the full firstmate turn exactly as if the tool were absent. |

The confidence floor is 0.9.
Every path that produced no usable verdict - a low-confidence answer, any non-finite or out-of-range confidence, a missing or rejected API key, any API or network error, a malformed success response, an unexpected route, unreadable input, an unreadable shared core, or the wall-clock bound - resolves to `full_turn` and exit 0, so an uncertain console route can never take the fast path.
Input is one small JSON object; `message` (the captain text) and `label` (the channel label) are the recommended fields, and the whole object is the model's `state`.
The console contract is owned by [`discord-conversation-console.md`](discord-conversation-console.md).

## Precedence

The captain's explicit instruction outranks everything here.
The reviewer's judgement outranks the classifier: a reviewer may raise, lower, or dismiss a severity, and the classifier never argues.
The classifier never closes an open finding and never stands in for the captain's merge authority.
A severity is a batching hint for the single correction round, nothing more.
A live worker's own evidence and the current-state read outrank the detector: a `progressing` verdict never green-lights a wedged worker, and a `stalled_looping` verdict never overrides a validation run that is still authoritatively working.
The detector is a recovery hint for a suspicious history, nothing more.


## Verification

`tests/fm-jev-guard.test.sh` drives the public interface against a fake System One server bound to loopback on an ephemeral port, covering the safe, low-confidence, unsafe, `needs_human`, API-error, malformed-response, timeout, non-finite-or-absurd-timeout, missing-key, and usage-error paths.
No case reaches the real network.

`tests/fm-jev-blocker.test.sh` and `tests/fm-jev-lane.test.sh` drive the public interface against `tests/assets/jev-classify-fake-typesafe.py`, a fake System One server bound to loopback on an ephemeral port.
They cover every class and lane, the high-confidence noise suppression, a low-confidence answer that must never suppress, the ARFAL dormant flag, an API error, a malformed response, invalid input JSON, the wall-clock fallback, a non-finite or absurd timeout that must stay a bounded fail-safe with no request, a missing key, the `.env` fallback, an unexpected answer, file input, and the usage errors.
No case reaches the real network, and each classification case asserts exactly one call.
Both suites also cover an invalid confidence (NaN, infinity, negative, and above 1) and a deliberately stale shared core that returns a non-finite confidence, asserting the default verdict, the surface flag, a numeric confidence, strict JSON, exit 0, and no network call.
The shared core is not part of the repository: it lives at `$FM_HOME/data/jev_decide.py`, so its own `invalid_confidence` guard is verified through these wrappers rather than committed here.

`tests/fm-jev-finding.test.sh` drives the public interface against `tests/assets/jev-finding-fake-typesafe.py`, a fake System One server bound to loopback on an ephemeral port.
It covers the three severities, the one-atomic-question request shape, a low-confidence answer that must fall back to `important` plus `needs_review`, a non-finite or out-of-range confidence (`NaN`, `Infinity`, `-0.1`, `1.1`) that must resolve to the same default with an in-range numeric confidence, an API error, a malformed response, an unexpected severity, the wall-clock bound, a non-finite or absurd timeout that must stay a bounded fail-safe with no request, a missing key, the `.env` key fallback, file input, and every usage error (invalid JSON, empty input, an empty finding object, a JSON list, and an unknown flag).
No case reaches the real network, and each classification case asserts exactly one call.

`tests/fm-jev-nonconvergence.test.sh` drives the public interface against `tests/assets/jev-nonconvergence-fake-typesafe.py`, a fake System One server bound to loopback on an ephemeral port.
It covers both verdicts, the deterministic feature extraction (repeated notes, a frozen state window, a state-level and a note-level alternation), the one-atomic-question request shape, a low-confidence answer that must fall back to `progressing` plus `review_history`, a non-finite or out-of-range confidence that must resolve to the same fail-safe verdict without escalating, an API error, a malformed response, an unexpected verdict, the wall-clock bound, a missing key, the `.env` key fallback, `--task` resolution, `--lines` windowing, both no-model-call shortcuts (insufficient history and a terminal declaration), and every usage error.
No case reaches the real network, and each judged case asserts exactly one call.

`tests/fm-jev-fred-preflight.test.sh` drives the public interface against a fake System One server bound to loopback on an ephemeral port, covering all three classes, a low-confidence answer in the safe class that must never stay routine, a low-confidence answer in the unsafe class, an API error, a malformed response, an unexpected class, NaN, Infinity, and out-of-range confidences against both the shared core and a stale-core stand-in, invalid input JSON, the wall-clock bound (armed, and refused for every invalid `FM_JV_FRED_PREFLIGHT_TIMEOUT`), a missing key, the `.env` key with the environment winning, file input, the read-only promise, and the usage errors.
No case reaches the real network, each classification case asserts exactly one call, and the suite skips cleanly when the captain-private shared core is not readable.

`tests/fm-jev-console-route.test.sh` drives the console-route classifier against
`tests/assets/jev-classify-fake-typesafe.py`, a fake System One server bound to
loopback on an ephemeral port.
It covers both routes, a low-confidence `fast_answer` that must fall back to
`full_turn`, an API error, a malformed response, an unexpected route, a
non-finite or out-of-range confidence, a stale core, invalid input JSON, the
wall-clock bound, a non-finite or absurd timeout that must stay a bounded
fail-safe with no request, a missing key, the `.env` key fallback with the
environment winning, file input, and every usage error.
No case reaches the real network, and each classification case asserts exactly
one call.
