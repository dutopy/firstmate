# AXI status contract

`bin/fm-axi-status.sh` is the phase-1 structured status boundary.
Its no-argument form reads the complete versioned event journal, projects the newest event for each task, and reconciles live state through `bin/fm-crew-state.sh` whenever current task metadata exists.
A structured event without current metadata is reported as `unknown` because event history is not current-state truth.
`--full` emits complete canonical path and PR values without truncation.
`--width N` controls every compact output line, with a minimum of 20 characters.
Compact output preserves task, state, kind, capability, error code, error message, and merge-state signals on labelled continuation lines.
When a path or PR is present, compact output says `details=omitted;`, `rerun --full`, and `for path/pr` rather than silently cutting the canonical value.

The public commands are:

    bin/fm-axi-status.sh
    bin/fm-axi-status.sh --full
    bin/fm-axi-status.sh --width 80
    bin/fm-axi-status.sh write --task-id ID --state working
    bin/fm-axi-status.sh write --task-id ID --state done --kind delivery --path /absolute/artifact
    bin/fm-axi-status.sh validate
    bin/fm-axi-status.sh validate FILE

The writer stores deterministic `axi-status.v1` percent-encoded key/value records in `state/axi-status.v1.log`.
Every record requires `task_id` and `state`.
A `kind=delivery` record also requires `path` or `pr`.
`capability`, `error_code`, and `error_message` are named fields rather than prose conventions.
An explicit `merge_state` accepts `open`, `merged`, or `unknown`, and an asserted open or merged state requires a PR identity.
The reader trusts that assertion only while the projected event PR still equals the current PR identity.
An exact matching `state/<task>.pr-poll-merge-notified` marker is stronger authoritative evidence and renders `merged`.
Missing evidence renders `unknown`, and metadata replacement or clearing invalidates stale event and marker evidence.
No task name or status prose contributes merge evidence.

Each successful append or update atomically republishes one complete journal containing all prior records plus the new event.
An update merges supplied fields into the newest event for that task, validates the complete result, and appends it without changing prior event bytes.
An exact `event_id` retry returns `unchanged`.
Reusing an event ID for different content or a different task fails with `EVENT_ID_COLLISION`.
Repeated identical unkeyed operations also return `unchanged`; changing any semantic field creates a new event.
Validation occurs before retry or collision handling, so an invalid request cannot succeed merely because its event ID already exists.
Publication uses a same-directory temporary file, `fsync`, and atomic rename under an exclusive writer lock, so readers observe either the old complete journal or the new complete journal.

Errors are TOON-like named blocks on standard error with `code`, optional `field`, and JSON-quoted `message` entries.
Invalid state, missing required fields, missing delivery references, unknown or duplicate options, malformed percent triplets, and percent bytes that are not valid UTF-8 fail nonzero.
`--help` lists the supported operations, while `write --help` and `validate --help` provide concise subcommand references.

Migration is additive and does not convert existing records.
Legacy `state/<task>.status` files remain byte-preserved append-only wake-event history under their existing owners.
New producers may opt into the v1 journal, while current-state consumers continue to use `fm-crew-state.sh` or the existing fleet snapshot contracts.
The AXI reader combines only the v1 event projection with authoritative current metadata and current-state evidence.
Removing the v1 journal rolls back this opt-in boundary without rewriting legacy data.

The fixed pre-change proxy fixture is `phase1-ship-v1`.
Its complete single-task full row carries task `ship`, current state `working`, kind `delivery`, path `/private/axi-phase1-fixture/artifact-with-a-canonical-long-name`, PR `https://github.com/example/project/pull/42`, and merge state `unknown`.
The pre-change capture used `LC_ALL=C wc -c` and ceiling bytes divided by four, producing 167 bytes and a 42-unit proxy estimate.
The behavioral test derives both complete representations from the same fields and checks value equality before reporting its own reproducible byte counts and ceiling bytes-divided-by-four values.
These numbers are byte proxies, not tokenizer measurements or actual token usage.

The following rationale uses the ten principles published at [axi.md](https://axi.md/), retrieved on 2026-09-08.
Principle 6 appears first as required by this phase's acceptance contract:

1. Principle 6, predictable errors: every failure exits nonzero and emits a stable code, optional field, and quoted message; unknown flags and malformed records fail closed without prompts.
2. Principle 1, token-efficient output: default output uses a compact line form rather than a verbose object envelope, and the retained proxy measurement makes no unsupported token-savings claim.
3. Principle 2, minimal default schemas: the first line contains only task, current state, and kind; exceptional capability, error, and merge signals appear only when present.
4. Principle 3, content truncation: compact output omits long canonical path and PR values with an explicit `--full` route, while full output preserves them intact.
5. Principle 4, pre-computed aggregates: the no-argument command aggregates all current metadata and journal tasks without requiring task-by-task calls.
6. Principle 5, helpful empty states: an empty home prints `no AXI records` instead of an empty response.
7. Principle 7, ambient context: the executable resolves the operational home from `FM_HOME` or the repository default, and producers opt into the journal while reads remain available on demand.
8. Principle 8, useful no-argument behavior: invoking the executable without arguments returns the live aggregate.
9. Principle 9, contextual next steps: compact rows that omit canonical references say `rerun --full`; diagnostics name the field that needs correction.
10. Principle 10, consistent help: the top-level command and both subcommands provide concise `--help` references.

The status boundary uses no dutopy-config runtime dependency.
The source definitions were independently captured and reviewed in dutopy-config as prerequisite evidence; this repository retains only the implementation rationale and public source link.
