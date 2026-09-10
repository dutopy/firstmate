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

- Ready PRs are projected from structured `ready_prs` observations and queued/in-flight backlog rows with a PR URL; client stage gates use structured `client_gates`/`gates` observations.
- Keyed open decisions use task `hints.open_decisions` and secondmate `decisions_open` records. The task and source key remain in evidence.
- Credential evidence and pending service/update decisions are projected when the snapshot provides `credential_evidence`/`credentials` or `pending_services`/`service_updates`/`pending_updates`. Missing source arrays are reported as `unknown` in `inventory` and `unknowns`, never treated as clear.
- Every recommendation contains a stable `key`, action, reason, evidence, unknowns, and optional authoritative age. Stable keys deduplicate the bounded output.

Daily and event semantics:

- Scheduling is outside this command. `--daily` declares a daily view and resurfaces existing recommendations whose authoritative `age_days` is at least `FM_VIGIE_AGE_DAYS`.
- `--event <previous.json>` compares stable recommendation keys with a prior JSON digest. `changes.new` contains additions, `changes.resolved` contains keys no longer observed, and daily `changes.resurfaced` contains aged retained items. These are view deltas, not state transitions.
- Recommendations are sorted by action/key and capped after deduplication. Display never answers a hold, closes a blocker, changes a service, updates credentials, or marks work complete.

Delivery is explicit: the output identifies the approved pilot channel separately from the future desktop surface and reports `scheduled: false`. Notification scheduling or Discord activation requires separate approval.
