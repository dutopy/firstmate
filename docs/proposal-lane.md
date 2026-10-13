# Proposal lane

The lane that notices recurring friction in the records a Firstmate home already writes and brings the improvement proposals the captain would otherwise have had to think of himself.
It exists because the best improvements this fleet shipped - a one-tap confirmation for an uncertain reading, an immediate wake instead of a poll - were proposed by the captain, and every one of them was friction the records already showed.
`bin/fm-proposal-lane.sh` owns every mechanic; run `bin/fm-proposal-lane.sh --help` for the commands.

## What it observes

It reads only records that already exist under the effective `FM_HOME`, and never a project, a network endpoint, or another home:

- `state/<id>.status` - the append-only worker status events of every task.
- the home's backlog - including the rows held for the captain.
- `state/inbox/*.note` and `state/inbox/handled/*.note` - the captain's captured notes.
- `data/captain.md` - the durable preference record.
- `data/*/report.md` - the closing reports of finished tasks.

Two detectors run over those five sources.

The **friction catalog** in `bin/fm-proposal-rules.tsv` declares one rule per known friction family.
A rule names its source, an extended-regular-expression pattern, and the minimum number of matching lines and distinct sources it needs before it may propose anything.
Matching is applied to each record's own text, so a rule can anchor on the start of a status line and describe a friction event rather than any line that mentions its subject.
Adding a friction family is one added line in that file and needs no code change.

The **emergent pass** needs no rule: it collects the blocked, paused, and needs-decision lines that carry a `[key=...]`, normalizes each key into a shape by replacing a long identifier with `<id>`, a long hex run with `<hash>`, and any digit run with `<n>`, and proposes a shape that recurred at least `key_min` times across at least `key_min_tasks` distinct sources.
A generic key that names no subject, such as `default`, is excluded.
An emergent family whose every evidence line a fired rule already claimed is skipped, so one friction yields one proposal.

## The evidence contract

A proposal cannot exist without evidence.
Every proposal stores at least one captured citation of the form `<record>:<line>: <text>`, naming the exact record and line number it came from, and the citation is copied into the ledger when the proposal is created, so it survives the task record being cleaned up later.
A rule that does not reach its own thresholds creates nothing at all, and the emergent pass respects the same rule.
The card carries one evidence line per proposal and points at `bin/fm-proposal-lane.sh show <id>` for the rest, and the full record is what an accepted backlog item carries into its body.

## The ledger

`data/proposals.jsonl` is the durable ledger, one compact JSON object per proposal, rewritten atomically.
`bin/fm-proposal-lane.jq` owns the merge contract a pass applies to it, and that contract is the reason a decline sticks:

- `proposed` is the only state the card may carry, and the only state a pass may refresh in place.
- `accepted` means the captain accepted it; the record keeps the backlog item id in `work`.
- `declined` means the captain declined it; the record keeps his reason, and a later pass never revives it, never refreshes it, and never proposes it again.
- `superseded` means the proposal was replaced by a better one or its evidence stopped appearing for `stale_days`; the record and its evidence survive, and a superseded record is not automatically revived even if the evidence returns.

`bin/fm-proposal-lane.sh reopen <id>` is the only way a decided proposal becomes open again, and only the captain's word justifies it.

## The card

`bin/fm-proposal-lane.sh digest` renders one bounded card of at most `card_max` proposals, best evidence first, ranked by how many distinct sources recorded the friction and then by how many events it saw.
Each entry carries what repeated and where, what it would change, a rough cost, and the exact answer command.
The captain answers per entry, the accepted one becomes ordinary queued work through the normal backlog path, and the declined one is recorded.

The card is delivered on a bounded cadence, `interval` seconds apart, defaulting to one week.
`bin/fm-proposal-lane.sh arm` writes `state/proposals.check.sh`, binds its bytes with `bin/fm-check-register.sh`, and lets the running watcher turn a due card into one ordinary `check` wake; `disarm` retires it through `bin/fm-check-unregister.sh`.
The lane writes the cadence record only when it actually emits that wake, so one card can never be delivered twice by the same cadence.
An unarmed home never wakes on its own; `/proposals` still renders the card on demand.

`.agents/skills/proposals/SKILL.md` owns what the agent does with the card: how it is rendered to the captain, how a numbered answer maps back to a proposal, and how the decision is recorded.

## Asking on demand

The captain asks by invoking `/proposals`, which runs the same card immediately and whatever the cadence says.
`/proposals pause` and `/proposals resume` drive the switch below.

## Pausing the lane

`bin/fm-proposal-lane.sh pause` writes `"paused": true` into `config/proposals.json`.
A paused lane runs no observation pass, adds no ledger entry, and emits no wake or card; only `list`, `show`, `status`, and the decision commands still work, so a card already in front of the captain can still be answered.
`bin/fm-proposal-lane.sh resume` restores it.
`bin/fm-proposal-lane.sh scan --force` runs one observation pass even while paused, which is the documented way to refresh the ledger without reopening the lane.

## Configuration

`config/proposals.json` is optional, local, gitignored, and an object; every key has a default.
[`docs/configuration.md`](configuration.md#proposal-lane-configproposalsjson) owns the key list, the accepted ranges, and the matching `FM_PROPOSAL_*` overrides.
A malformed or out-of-range value is refused with the file path rather than silently defaulted.

## What this lane will never do

- It never changes fleet behaviour, and it ships no improvement by itself; an accepted proposal is ordinary work with its own task, review, and merge authority.
- It never files work that was not accepted, and it files at most the one backlog item an acceptance names.
- It never proposes without evidence from the records, and it never invents an evidence line.
- It never re-proposes a declined idea.
- It never sends more than the one bounded card, never one card per idea, and never a vague wish list.
- It never posts anything on its own: the card reaches the captain through the ordinary supervision turn, and the lane itself writes only its ledger, its cadence records, and the backlog item an acceptance creates.
- It never writes a project, reaches a network, or reads another home's records.

## Undo

Each live-facing change has one exact undo:

- A card woke the captain: `bin/fm-proposal-lane.sh pause` silences the lane, and `resume` restores it.
- The check was armed: `bin/fm-proposal-lane.sh disarm` removes `state/proposals.check.sh` and its trust binding.
- A proposal was accepted: `bin/fm-proposal-lane.sh reopen <id>` reopens the proposal, and the backlog item it created is removed with the ordinary `tasks-axi rm <item>` (or kept as ordinary work and closed normally).
- A proposal was declined or superseded: `bin/fm-proposal-lane.sh reopen <id>` reopens it.
- The whole ledger: deleting `data/proposals.jsonl` starts the lane from an empty board, which re-proposes what live evidence still supports; use `decline` to keep an idea out rather than deleting the ledger.

## Verification

`tests/fm-proposal-lane.test.sh` drives the real command line against synthetic homes and proves the evidence contract, the decline that survives a later pass, the emergent family and its skip, the bounded card, the cadence, accept through the real backlog path, pause and resume, and arm and disarm.
Run it with `bin/fm-test-run.sh tests/fm-proposal-lane.test.sh`.
The installed check shim is exercised by running the generated file directly, and the wiring is exercised through `bin/fm-check-register.sh` and `bin/fm-check-unregister.sh`, the same owners the running watcher uses.
What that test does not exercise: a live watcher cycle that dispatches the installed shim, and a card answered while a real fleet is under way.
