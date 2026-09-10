# Vigie recommendation digest

`bin/fm-vigie.sh` is a read-only projection over `bin/fm-fleet-snapshot.sh`. The snapshot is authoritative for backlog, captain holds, blockers, task endpoints, reports, and secondmate summaries; Vigie does not parse prose or maintain a second ledger.

Usage:

    bin/fm-vigie.sh
    bin/fm-vigie.sh --json
    bin/fm-vigie.sh --fr
    bin/fm-vigie.sh --json --event previous.json

The default is a compact AXI/TOON projection. `--json` emits `fm-vigie.v1`, including `action`, `reason`, `evidence`, and `unknowns` for each recommendation. `--fr` renders the same bounded recommendations as concise French notification text.

Daily and event semantics:

- The projection is daily by contract (`cadence: daily`); scheduling is deliberately outside this command.
- `FM_VIGIE_MAX` bounds recommendations (default 10). Recommendations are sorted by stable action key and deduplicated by that key.
- A captain-actionable hold produces an `answer:<task-id>` recommendation. A held item aged at least 14 days says so using the authoritative `hold_age_days` field.
- An unresolved structured blocker produces `unblock:<task-id>`.
- A task with an explicitly dead recorded endpoint produces `inspect:<task-id>`; unknown liveness is not treated as dead.
- `--event <previous.json>` compares recommendation keys with a prior `fm-vigie.v1` JSON result. Keys appearing now are `changes.new`; absent keys are `changes.resolved`. This is a view delta, not a state transition.

The output identifies the approved pilot channel separately from the future desktop surface and reports that scheduling is off. It never answers a captain hold, marks a blocker done, restarts an endpoint, merges a PR, probes credentials, changes a service, or installs an update. Source-specific credential and service/update decisions remain explicit unknowns for the owning native surfaces.
