# Treehouse pool-slot reconciliation: verification

Audience: maintainer verification.

This record supports two active guarantees: a finished task that shares a reused Treehouse pool slot with other finished records can return that slot and be cleaned up, while a slot holding preserved unlanded work, a live co-owner endpoint, an unfinished co-owner, or a deliverable that exists only inside the copy still refuses - including under `--force` - and a finished task whose endpoint is provably gone stops producing stale notifications.

Owners: [`bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s header ("Shared-slot reconciliation") owns the rule and the proof sequence, [`bin/fm-wake-lib.sh`](../../bin/fm-wake-lib.sh)'s `fm_treehouse_slot_reconciled_*` owns the durable receipt, and [`bin/fm-watch.sh`](../../bin/fm-watch.sh)'s `finished_task_endpoint_settled` owns the watcher classification.
Refresh this record by rerunning the two regression scripts named at the end after changing any of them.

## The rule

When several task records name one Treehouse pool slot, teardown refuses unless all three proofs hold: this task's own record is a `done:` task whose deliverable is recorded outside the worktree; every other record naming that slot is also a `done:` task whose endpoint is provably dead or missing and, for a scout, whose report exists outside the worktree; and the shared copy holds nothing unlanded under the ordinary landed-work rules with `--force` and the scout exemption cleared.
Only then is the slot returned exactly once, with a `.fm-slot-reconciled` receipt beside the slot naming the releasing task and every record it carried, so each co-owner's later teardown skips every slot step and cleans up only its own records.
Anything short of all three refuses exactly as before, and `--force` never lifts it.
A `done:` task whose endpoint is provably dead or missing is also settled by the watcher instead of re-surfaced as stale, while an open captain call, any other status verb, or any ambiguous, unreadable, or unverified endpoint keeps the ordinary stale path.

## What was run

Date: 2026-09-18.
Tree: this change's branch on Linux with GNU bash 5.2.21, rebased onto `81eddd24` (`main`), with that commit's tree used for the "before" half, and the repo's own scripts.
Fixture: one scratch directory per case holding a sandbox home (`state/`, `data/`, `config/`), a real project clone, and a real Treehouse-shaped pool slot at `<pool>/1/project` reached through a `worktree=` record.
Two task records per case name that one slot through `worktree=`, with `kind=`, `mode=local-only`, and a status log.
`tmux` and `treehouse` are logged stubs, so no backend, agent, or model runs; the stub reports a co-owner window only in the live-endpoint case and never removes the slot directory, which keeps the released-slot state observable.
The four cases are the four pairs observed on 2026-09-18: a finished ship against a finished scout whose report is already outside the copy, a finished ship against a parked task holding preserved work, two finished records over a copy holding preserved work, and two finished records where the co-owner's endpoint is still alive.
Each case ran `bin/fm-teardown.sh <task> [--force]` and, for the first case, the co-owner's own teardown afterwards.

## Before: both records refused, so neither could be cleaned up

The pre-change tree at `9bc051ff` refuses every pair, each refusal naming the other record as the blocker:

```
REFUSED: task session-mirror's recorded worktree /pool/1/project is also task review-scout's recorded worktree.
REFUSED: task connectors-install's recorded worktree /pool/1/project is also task parked-reading's recorded worktree.
REFUSED: task team-design-study's recorded worktree /pool/1/project is also task parked-update's recorded worktree.
REFUSED: task worker-profile-study's recorded worktree /pool/1/project is also task email-lot's recorded worktree.
```

No case returned the slot, so all eight records stayed in place with their panes lingering - the recurring stale-endpoint notifications.

## After: the safe pair releases once, every unsafe pair still refuses

The settled pair returns the slot exactly once, records the reconciliation, and lets the co-owner finish its own cleanup without touching the slot again:

```
session-mirror teardown            ALLOWED (rc=0)
review-scout teardown              ALLOWED (rc=0)
    slot returns: 1
    reconciliation receipt: present
    records left: 0
```

The three unsafe pairs still refuse under `--force`, each naming the concrete missing proof, and the preserved copy survives:

```
connectors-install --force   REFUSED  The shared slot is not provably settled: task parked-reading is not a finished task.
team-design-study --force    REFUSED  The shared slot is not provably settled: the shared copy holds work that has not landed.
worker-profile-study         REFUSED  The shared slot is not provably settled: task email-lot still has a live or unproven endpoint.
    preserved copy intact: yes
    slot returns: 0
```

## Before and after: the recurring stale notification

The same finished-task fixture was run against both trees, with the co-owner endpoint absent and the task's own status log ending in `done:`.
The pre-change watcher surfaced the lingering pane as a stale wake; the changed watcher settles it and advances its suppressor, so no later poll of that finished task fires again:

```
main:     not ok - watcher exited for a finished task with a gone endpoint (should settle): stale: test:fm-finished
branch:   ok - a finished task whose endpoint is gone is settled instead of re-surfaced
branch:   ok - an unfinished captain call with a gone endpoint still surfaces
```

## Durable regression owners

`tests/fm-teardown-shared-slot.test.sh` pins the release, the receipt, the co-owner skip, receipt supersession by a new claim, the unreadable-receipt refusal, and every unsafe refusal under `--force`.
`tests/fm-watch-triage.test.sh` pins the settled finished task and its open-captain-call control.
