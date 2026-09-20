---
name: proposals
description: >-
  Bring the fleet's own improvement proposals to the captain as one bounded card, and record what he accepts or declines.
  Use when the captain invokes /proposals or asks what the system itself would improve, when he answers an open card ("1 oui, 2 non"), and on a check wake naming a due proposal card from bin/fm-proposal-lane.sh.
  Accepting files exactly one ordinary backlog item and nothing else; a decline is remembered so the same idea is never proposed again.
user-invocable: true
metadata:
  internal: true
---

# proposals

The lane that reads the records the fleet already writes and brings the improvements the captain would otherwise have had to think of himself.
`bin/fm-proposal-lane.sh` owns every mechanic, and [`docs/proposal-lane.md`](../../../docs/proposal-lane.md) owns the behaviour contract, its never-do list, and what the lane will not do.
This skill owns only what the supervising agent does with it: render one card, record the answers, and nothing else.

The lane is armed once per home with `bin/fm-proposal-lane.sh arm`.
An unarmed lane still answers `/proposals`; it simply never wakes anyone on its own cadence.

## Invocation modes

- Plain `/proposals` renders the card now, whatever the cadence says.
- A check wake naming a due proposal card renders the same card the same way.
- `/proposals pause` and `/proposals resume` drive the documented switch and report the new state in one line.
- Any other `/proposals` text is a decision on a card already in front of the captain; handle it with "Answering a card" below.

## Rendering a card

1. Run `bin/fm-proposal-lane.sh digest --json` and read the JSON lines it prints, one proposal per line.
2. If the command refuses because the lane is paused, say so in one line, offer to resume it, and stop.
   If it prints nothing, say that the records show nothing new to propose yet, and stop.
3. Render the proposals in one captain-facing message, in French, on one page, numbered from 1.
   Each entry carries exactly three things: what repeated and where the fleet recorded it, what it would change, and a rough cost.
   Never carry a proposal the lane did not list, never add a wish of your own to an entry, and never send one message per idea.
4. Keep the identifiers to yourself: the captain answers by number, and you map the number back to the proposal id.
   The citation in the entry is the record the evidence came from (`state/<id>.status:<line>`), never an internal record id.
5. Ask for the decision in the same message, one line: he answers `n oui` or `n non` per entry.

A card with fewer than three entries is a normal card: say plainly that the records show only that many, and never pad it.

## Answering a card

Work from the card this session rendered.
When the card is no longer in this session's context, run `bin/fm-proposal-lane.sh digest --json` again to recover the same list before acting.

- Accept: `bin/fm-proposal-lane.sh accept <id>`, then report in plain words that the entry is now ordinary queued work.
  The command files the backlog item itself through `bin/fm-tasks-axi.sh`; never file it yourself, and never accept an entry the captain did not name.
- Decline: `bin/fm-proposal-lane.sh decline <id> --reason "<the captain's own reason, translated into one short English note>"`.
  A decline is permanent: the lane keeps it and never proposes that idea again.
- Leave every entry the captain did not answer open; a partial answer is a normal answer, and the rest stays on the board.
- If he changes his mind after a decline, `bin/fm-proposal-lane.sh reopen <id>` puts it back on the board; do that only when he asks for it.
- Report the outcome of the whole card in one message: what was accepted, what was declined, and what is still open.

Accepted work is ordinary queued work.
It waits for the normal dispatch decision like any other queued item, and nothing in this skill dispatches, validates, or merges it.

## What this skill never does

[`docs/proposal-lane.md`](../../../docs/proposal-lane.md) owns the lane's never-do list.
What binds this skill at the moment of a card is narrower:

- Never decide for the captain: he answers entry by entry, and an approval of the card as a whole is not an approval of any entry he did not name.
- Never render an entry the lane did not list, and never invent, soften, or drop an evidence line.
- Never send the card anywhere but the one captain-facing message.
- Never dispatch, validate, or merge the work an acceptance creates; that work has its own task and its own gates.
- Never use this lane to carry an unrelated blocker, a PR, or a decision that belongs on its own wake path.
