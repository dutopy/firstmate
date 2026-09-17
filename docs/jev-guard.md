# The Jev advisory classifiers

`bin/fm-jev-guard.sh` is a thin, advisory classifier over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
It gives firstmate one typed second opinion before a consequential action, and it fails safe: every uncertainty resolves to a question for the captain, never to a silent advance.
The script's header owns the exact flags, environment keys, input handling, and output shape; this page owns the contract the guard is held to.

The `jev` classifiers are thin, advisory tools over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
Each gives firstmate one typed second opinion on one narrow, recurring question, and each fails safe: every uncertainty resolves to the conservative default, never to a silent action.
The scripts' headers own their exact flags, environment keys, input handling, and output shape; this page owns the contract they are held to.


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

A classifier carries no authority and decides nothing.

- It never decides a finding in place of the reviewer or the captain.
- It never closes, resolves, answers, or posts a finding.
- It never trims the finding list: every finding it sees comes back with a severity, and a flagged or cosmetic one stays listed.
- It never authorizes or blocks a merge, and it never bypasses a guard, a gate, or a refusal.
- It runs one question about one item, never on every tool call and never over a list of items.


## Shared core

The guard imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_GUARD_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the guard adds no second HTTP client and no second copy of the API contract.
The guard makes zero change to the core; improving the client or the gate happens in the core, once, for every caller.

Each classifier imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_FINDING_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the wrapper adds no second HTTP client and copies no API contract.
It reads the same `TYPESAFE_API_KEY` the typed dispatch resolution reads, from the environment or a `TYPESAFE_API_KEY=` line in `$FM_HOME/.env`.
It never sends a list: each call asks the model one atomic forced-choice question about exactly one finding.


## Fail-safe boundary and exit codes

Confidence below the floor, a missing or rejected API key, any API or network error, a malformed success response, and the wall-clock bound all resolve to `ask_human` with exit 0.
There is no silent proceed and no silent block.
Exit 2 is reserved for a usage or environment error - invalid input JSON, an unknown or missing rubric, missing `python3`, or an unreadable shared core - and it prints nothing on stdout and makes no network call.

Every path that produced no usable severity resolves to severity `important`, flag `needs_review`, exit 0, with the cause named in `reason`:

- confidence below 0.9;
- a confidence the model reports outside the finite 0..1 range (non-finite, negative, or above 1);
- a missing or rejected API key;
- any API or network error;
- a malformed success response;
- an unexpected severity the rubric does not define;
- an unreadable shared core;
- the wall-clock bound (`FM_JV_FINDING_TIMEOUT`, default 20s).

Exit 2 is reserved for a usage error: an unknown flag, a missing flag value, missing `python3`, an unreadable input file, input that is not valid JSON, input that is not a JSON object, or a JSON object that carries no finding text at all.
A usage error prints nothing on stdout and makes no network call.
This is the deliberate difference from the wake-side classifiers: a usage error is a caller mistake, never a finding's severity, so an empty or malformed finding is reported loudly to the caller instead of being given a default severity.
There is no silent drop either way: a classified path always exits 0 with a typed severity, and a refused path exits 2 with the caller's mistake named.

The wrapper validates the confidence boundary itself rather than trusting the shared gate, so a non-finite or out-of-range answer can never compare as passing.
The emitted confidence is always a finite number in [0, 1] and the output is always strict JSON, so no `NaN` or `Infinity` literal can reach stdout.


## What it classifies

Two rubrics ship with the tool, selected by `--rubric` or the input's `rubric` field.

- `merge` classifies a pending merge as `safe_merge` (documentation or comment-only), `needs_human` (code, tests, configuration, CI, dependencies, or another behavior-bearing artifact), or `unsafe` (destructive, irreversible, or secret-exposing).
- `dispatch` classifies requested work as `routine` (the standing delivery posture already covers it), `needs_human` (ambiguous, expanding, or authority-sensitive), or `unsafe` (destructive, irreversible, or security-sensitive).

The verdict is the guard's own typed answer: `proceed` only for the rubric's safe option above the confidence floor, `ask_human` for `needs_human` and for every fail-safe path, and `block` only for an `unsafe` answer at or above that floor.
The model's `route`, its `confidence`, and a short `reason` are reported beside the verdict so the caller can see the evidence rather than only the conclusion.


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


## Precedence

The captain's explicit instruction outranks everything here.
The reviewer's judgement outranks the classifier: a reviewer may raise, lower, or dismiss a severity, and the classifier never argues.
The classifier never closes an open finding and never stands in for the captain's merge authority.
A severity is a batching hint for the single correction round, nothing more.


## Verification

`tests/fm-jev-guard.test.sh` drives the public interface against a fake System One server bound to loopback on an ephemeral port, covering the safe, low-confidence, unsafe, `needs_human`, API-error, malformed-response, timeout, missing-key, and usage-error paths.
No case reaches the real network.

`tests/fm-jev-finding.test.sh` drives the public interface against `tests/assets/jev-finding-fake-typesafe.py`, a fake System One server bound to loopback on an ephemeral port.
It covers the three severities, the one-atomic-question request shape, a low-confidence answer that must fall back to `important` plus `needs_review`, a non-finite or out-of-range confidence (`NaN`, `Infinity`, `-0.1`, `1.1`) that must resolve to the same default with an in-range numeric confidence, an API error, a malformed response, an unexpected severity, the wall-clock bound, a missing key, the `.env` key fallback, file input, and every usage error (invalid JSON, empty input, an empty finding object, a JSON list, and an unknown flag).
No case reaches the real network, and each classification case asserts exactly one call.
