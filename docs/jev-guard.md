# The Jev advisory classifiers

`bin/fm-jev-blocker.sh` and `bin/fm-jev-lane.sh` are two thin, advisory classifiers over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
Each gives firstmate one typed second opinion on one narrow, recurring question, and each fails safe: every uncertainty resolves to the captain or to the conservative default, never to a silent action.
The scripts' headers own their exact flags, environment keys, input handling, and output shape; this page owns the contract they are held to.

## Advisory only, and below every hard rule

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

## Shared core

Both classifiers import the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_BLOCKER_CORE` and `FM_JV_LANE_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, which rejects a non-finite or out-of-range confidence as an `ask_human` outcome at the owner, so neither wrapper adds a second HTTP client and neither copies the API contract.
Both read the same `TYPESAFE_API_KEY` the typed dispatch resolution reads, from the environment or a `TYPESAFE_API_KEY=` line in `$FM_HOME/.env`.
Neither ever sends a list of items: each call asks the model one atomic forced-choice question about exactly one block or one request.

## Fail-safe boundary and exit codes

Every path that produced no usable verdict or route resolves to the conservative default with its flag and exits 0:

- confidence below 0.9;
- a confidence that is not a finite number in [0, 1] (NaN, infinity, negative, or above 1);
- a missing or rejected API key;
- any API or network error;
- a malformed success response;
- invalid or unreadable input JSON;
- an unreadable shared core;
- the wall-clock bound (`FM_JV_BLOCKER_TIMEOUT` / `FM_JV_LANE_TIMEOUT`, default 20s).

There is no silent suppression, no silent retry, and no silent lane assignment.
Each wrapper validates the confidence at its own boundary, so a stale shared core that returned a non-finite or out-of-range confidence cannot reintroduce a suppression or a silent lane: any such value is treated exactly like an absent verdict, and the emitted confidence is always a plain JSON number, never `NaN` or `Infinity`.
Exit 2 is reserved for a usage error - an unknown flag, a missing flag value, or missing `python3` - which prints nothing on stdout and makes no network call.
Invalid input JSON and an unreadable core are fail-safes here rather than usage errors, because either could otherwise suppress a wake or misroute a request, and a safe typed answer is always available.

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

## Verification

`tests/fm-jev-blocker.test.sh` and `tests/fm-jev-lane.test.sh` drive the public interface against `tests/assets/jev-classify-fake-typesafe.py`, a fake System One server bound to loopback on an ephemeral port.
They cover every class and lane, the high-confidence noise suppression, a low-confidence answer that must never suppress, the ARFAL dormant flag, an API error, a malformed response, invalid input JSON, the wall-clock fallback, a missing key, the `.env` fallback, an unexpected answer, file input, and the usage errors.
No case reaches the real network, and each classification case asserts exactly one call.
Both suites also cover an invalid confidence (NaN, infinity, negative, and above 1) and a deliberately stale shared core that returns a non-finite confidence, asserting the default verdict, the surface flag, a numeric confidence, strict JSON, exit 0, and no network call.
The shared core is not part of the repository: it lives at `$FM_HOME/data/jev_decide.py`, so its own `invalid_confidence` guard is verified through these wrappers rather than committed here.
