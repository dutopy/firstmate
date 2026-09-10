# Vigie recommendation digest

`bin/fm-vigie.sh` is a bounded, read-only projection over `bin/fm-fleet-snapshot.sh`. The snapshot is authoritative; Vigie does not parse prose, create a ledger, or execute merge, authentication, service, update, or notification actions.

Usage:

    bin/fm-vigie.sh
    bin/fm-vigie.sh --json
    bin/fm-vigie.sh --fr
    bin/fm-vigie.sh --json --event previous.json
    bin/fm-vigie.sh --json --daily --event previous.json

The default is compact AXI/TOON output. `--json` emits `fm-vigie.v1`; `--fr` renders the same bounded recommendations as concise French notification text. `FM_VIGIE_MAX` defaults to 10. `FM_VIGIE_AGE_DAYS` defaults to 14.

Recommendation inventory:

- Ready PRs are projected from the native snapshot backlog rows (queued/in-flight records with a PR URL), with the recorded URL, title, state, and gate retained as evidence. A snapshot producer may also provide structured `ready_prs`; Vigie does not invent that field or query a forge itself.
- Client stage gates, credential evidence, and pending service/update decisions are read only from their explicitly named native snapshot fields. If the producer does not expose one of those fields, its inventory status is `unknown` rather than an inferred empty/clear result.
- Keyed open decisions use task `hints.open_decisions` and secondmate `decisions_open` records. The task and source key remain in evidence.
- Every recommendation contains a stable `key`, action, reason, concrete observed evidence, unknowns, and optional authoritative age. Stable keys deduplicate the bounded output.

Daily and event semantics:

- Scheduling is outside this command. `--daily` declares a daily view and resurfaces existing recommendations whose authoritative `age_days` is at least `FM_VIGIE_AGE_DAYS`.
- `--event <previous.json>` compares stable recommendation keys with a prior JSON digest. `changes.new` contains additions, `changes.resolved` contains keys no longer observed, and daily `changes.resurfaced` contains aged retained items. These are view deltas, not state transitions.
- Recommendations are sorted by action/key and capped after deduplication. Display never answers a hold, closes a blocker, changes a service, updates credentials, or marks work complete.

Delivery is explicit: the output identifies the approved pilot channel separately from the future desktop surface and reports `scheduled: false`. Notification scheduling or Discord activation requires separate approval.
