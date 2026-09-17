# The Jev class router

`bin/fm-jev-class.sh` is the first stage of the captain-approved two-stage dispatch router.
It asks typesafe.ai's System One model (Jev), through the shared `jev_decide` core, two questions about one task description, and returns typed answers.
The second stage stays where it already is: `quota-axi` supplies availability evidence and `quota-array-dispatch` selects the concrete route.
The script's header owns the exact flags, environment keys, input handling, and output shape.
This page owns the contract the two stages are held to, and [configuration.md](configuration.md) ("Crew dispatch profiles") owns the `classes` schema the class selects.

## The two stages, never collapsed

The stages answer different questions and neither may absorb the other.

1. Jev decides the intelligence the task needs: the class `volume_cheap`, `standard_impl`, or `hard_reasoning`, and the lowest adequate effort `low`, `medium`, or `high`.
   The class rubric is the live-validated one reused verbatim, and the effort rubric applies the same "cheapest class that meets the bar, lowest adequate effort" doctrine to one axis.
2. Quota decides what is actually available: `quota-array-dispatch` resolves the profile set the class declares against one `quota-axi` snapshot and its `spendPriority`.

Jev never sees quota, catalogs, provider authentication, prices, or remaining headroom, and it never overrides economics.
When the class's preferred route is exhausted or unmeasurable, the route is chosen from that class's declared alternatives by the availability gate.
The doctrine applies there: reduce effort or scope rather than raise cost, prefer the low-cost subscription route while it is up, and escalate to the strongest reasoning route only for genuinely hard work.
A class answer that would require an unavailable route never becomes a reason to spend more.

## The class key

A class answer is a key, never prose.
`config/crew-dispatch.json` may declare a top-level `classes` object whose keys are exactly `volume_cheap`, `standard_impl`, and `hard_reasoning`.
Each value is the profile object or non-empty profile array that class dispatches through, in the same shape as `default`.
`bin/fm-jev-class.sh --profiles` performs the whole lookup in code, so no script parses natural-language rules to reach a profile set.
[configuration.md](configuration.md) owns the declared fields, their validation, and the profile forms.
The intake consumes the class the same way, and it now does so automatically: when the home has the typed key and the config declares classes, `fm-spawn.sh` runs this stage itself on the task's own brief for a crewmate or scout spawn that carries no explicit harness, hands the class and effort to `bin/fm-dispatch-resolve.sh --class`, and launches the profile that comes back.
That path asks the model nothing beyond the one classification request.
An explicit harness, model, or effort still wins outright, and a classifier fallback (low confidence, API error, timeout, or a malformed answer) returns to the resolver's rule and `default` path with its flag reported, so the classifier can never block a dispatch by itself.
`quota-array-dispatch` remains the single availability and economics gate for whichever profile set the class selects; this stage never ranks, filters, or vetoes a candidate.
A home that declares no class profiles keeps the existing intake unchanged: the class is still reported, the resolver falls through to the best-fit rule, then `default`, then `config/crew-harness`.

## Model doctrine the declarations encode

The router names no model; the class profile sets do.
The doctrine those declarations follow is the captain's: the low-cost subscription route (ZAI GLM Flash) is the default whenever it is available, the strongest authenticated reasoning route (Claude over the OAuth session) is the escalation for `hard_reasoning`, Sonnet is not that escalation, and a DeepSeek route is used only when it is genuinely available.
Declaring the routes is a configuration choice and applying the doctrine is the availability stage's work.
The router contributes the class and the effort, and adds no model-specific policy of its own.

## Precedence

From strongest to weakest, the intake resolves a dispatch route in this order:

1. An explicit per-task captain instruction, including the tool's own `--class` and `--effort` overrides and any explicit harness, model, or effort passed to `fm-spawn.sh`.
2. A confident Jev class, resolved through its declared `classes` profile set by the intake path above.
3. The best-fit configured rule, exactly as the dispatch intake matches rules today.
4. The configured `default`.
5. The static `config/crew-harness` fallback.

A declared `effort` on a chosen profile, and every floor, approval gate, and eligibility rule the availability stage applies, still win over the classifier's effort for that route.
The effort answer is the default for the class when the chosen profile does not state one, which the intake path applies in code when the class stage supplies `--effort`.
An effort the chosen harness does not accept is dropped from the launch flags by `fm-spawn.sh` rather than launched.

## Fail-safe boundary

The router never blocks a dispatch.

- Any API or network error, a malformed or out-of-vocabulary response, the wall-clock bound, and a missing or rejected API key resolve to the default class and its mapped effort, with `flag` set to `api_error` and exit 0.
- A confidence that is not a finite number inside `0..1` - NaN, an infinity, a negative value, or a value above 1 - is a malformed response and takes that same fallback.
  The wrapper enforces that boundary itself rather than trusting the shared core, so a non-finite confidence can never reach stdout as `NaN` or `Infinity`.
- Stdout is always strict JSON, and `confidence` is always a number inside `0..1`.
- A class or effort answer below the confidence floor falls back to the default class and the deterministic mapping (`volume_cheap` to `low`, `standard_impl` to `medium`, `hard_reasoning` to `high`), with `flag` set to `low_confidence` and exit 0.
- The effort moved to the deterministic mapping whenever the class itself fell back, so the reported pair is always coherent.
- `flag` is `null` only when both answers cleared the floor, and `confidence` is always the class answer's own confidence, so a caller sees the weakest evidence rather than only the conclusion.
- The default class is the class the home's current default dispatch belongs to, configurable with `FM_JV_CLASS_DEFAULT`.

Exit 2 is reserved for a usage or environment error: an unreadable or empty task description, an unknown class or effort value, a bad threshold or default class, missing `python3`, an unreadable shared core, or an unreadable or malformed canonical dispatch config on the profile-lookup path.
It prints nothing on stdout and makes no network call.

## Shared core

The classifier imports the shared `jev_decide` core by path at `$FM_HOME/data/jev_decide.py`, overridable with `FM_JV_CLASS_CORE`.
That core remains the single owner of the TypeSafe request shape, the retry and timeout behavior, and the API error types, so the classifier adds no second HTTP client and no second copy of the API contract.
It asks both questions in one request and applies the published confidence floor in code, because the core's own `guard()` gates a single question.
The classifier makes zero change to the core.

## Verification

`tests/fm-jev-class.test.sh` drives the public interface against a fake System One server bound to loopback on an ephemeral port.
It covers the three classes with their efforts, the single atomic request, both fallback axes and their combination, an API error, a malformed success response, a non-finite or out-of-range confidence on either axis, an out-of-vocabulary answer, the wall-clock bound, a missing key, the explicit overrides, the canonical `classes` validation with its configuration errors, and the usage errors.
`tests/fm-dispatch-resolve.test.sh` drives the intake path with a fake `curl` and a fake `quota-axi`, proving that a declared class reaches the emitted `profile:` line, that the class path makes no model request, that the class's declared effort and a supplied `--effort` each land correctly, and that an undeclared class falls through to the rule match.
`tests/fm-spawn-dispatch-profile.test.sh` drives the whole intake end to end through the real `fm-spawn.sh` with a fake System One server, a fake `curl`, and a fake `quota-axi`, proving that the class stage's answer changes the launched harness, model, and effort with exactly one classifier request and no resolver model request, and that a classifier API error or a low-confidence class falls back to the configured rule profile with its flag and still spawns.
No case reaches the real network.
The class rubric is the one the live router experiment validated on 2026-09-17, which classified its five labeled tasks at full confidence; that experiment is captain-side evidence in the private task records, not a reproducible claim of this repository.
