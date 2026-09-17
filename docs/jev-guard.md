# The Jev action guard

`bin/fm-jev-guard.sh` is a thin, advisory classifier over the shared `jev_decide` core, backed by typesafe.ai's System One model (Jev).
It gives firstmate one typed second opinion before a consequential action, and it fails safe: every uncertainty resolves to a question for the captain, never to a silent advance.
The script's header owns the exact flags, environment keys, input handling, and output shape; this page owns the contract the guard is held to.

## Advisory only

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

## What it classifies

Two rubrics ship with the tool, selected by `--rubric` or the input's `rubric` field.

- `merge` classifies a pending merge as `safe_merge` (documentation or comment-only), `needs_human` (code, tests, configuration, CI, dependencies, or another behavior-bearing artifact), or `unsafe` (destructive, irreversible, or secret-exposing).
- `dispatch` classifies requested work as `routine` (the standing delivery posture already covers it), `needs_human` (ambiguous, expanding, or authority-sensitive), or `unsafe` (destructive, irreversible, or security-sensitive).

The verdict is the guard's own typed answer: `proceed` only for the rubric's safe option above the confidence floor, `ask_human` for `needs_human` and for every fail-safe path, and `block` only for an `unsafe` answer at or above that floor.
The model's `route`, its `confidence`, and a short `reason` are reported beside the verdict so the caller can see the evidence rather than only the conclusion.

## Fail-safe boundary

Confidence below the floor, a missing or rejected API key, any API or network error, a malformed success response, and the wall-clock bound all resolve to `ask_human` with exit 0.
There is no silent proceed and no silent block.
Exit 2 is reserved for a usage or environment error - invalid input JSON, an unknown or missing rubric, missing `python3`, or an unreadable shared core - and it prints nothing on stdout and makes no network call.

## Shared core

The guard imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_GUARD_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the confidence gate, so the guard adds no second HTTP client and no second copy of the API contract.
The guard makes zero change to the core; improving the client or the gate happens in the core, once, for every caller.

## Verification

`tests/fm-jev-guard.test.sh` drives the public interface against a fake System One server bound to loopback on an ephemeral port, covering the safe, low-confidence, unsafe, `needs_human`, API-error, malformed-response, timeout, missing-key, and usage-error paths.
No case reaches the real network.
