# Discord console action cards - verification

This record holds the active empirical claims behind the #firstmate console action
cards: the posted button shape, the press routing into the shared keyed-answer
intake, the interaction callback, dedupe, the refusal audit, and the free-form and
deferral options.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md);
this page is evidence, not a second contract.

## Environment and commands

Measured on 2026-09-19 on the firstmate host, Python 3.12, against the fake local
Discord HTTP server and fake local gateway websocket the suite owns.
The fixture home runs the real `bin/fm-captain-hold.sh` against a real tasks-axi
markdown backlog, so the press is recorded through the production intake rather
than a stub.
No real token is read and no request leaves loopback.

```sh
bash tests/fm-discord-conversation-console.test.sh
```

The action-card section of that suite prints:

```
ok - the console posts an action card with labelled option buttons
ok - a press records the chosen option through the shared keyed-answer intake
ok - every press is answered, deduped, and audited
ok - the console refuses to post a card for an unheld queued task
ok - the console refuses to post a card for an already-closed task
ok - the console posts a card for a legitimately held task
ok - focused interaction checks pass
ok - a guild payload and the acknowledgement ordering are covered by focused checks
ok - a later option defers the task through the shared intake
ok - a card is refused on any path that cannot receive an interaction
```

`bin/fm-lint.sh` is green over the changed shell and test files.

## What the suite proves

On the same fake server and gateway:

- `card` posts one message whose `components` array is a single action row of four
  buttons with `fmcard:<card-id>:<index>` custom ids, and stores the card's task
  id, option set, body, and message id under `cards/` in the console state.
- A press arrives as a gateway `INTERACTION_CREATE` dispatch of type
  `MESSAGE_COMPONENT`, shaped like a real guild payload: the presser is carried
  under `member.user` with no top-level `user` field.
  The captain's press on the decisive option records its exact value through the
  real keyed-answer intake: the fixture home's `data/backlog.md` gains one
  `Resolution recorded by fm-captain-hold.` block carrying `Oui, vas-y.`, and the
  card record reads `status: answered` with `answer.label: Oui`.
- A guild-shaped `MESSAGE_CREATE` with no `author` object but a
  `member.user` id is captured as the captain rather than ignored as
  `missing-author`.
- A second delivery of the same interaction id records no second resolution
  block, and its card edit is replayed.
- Every press is acknowledged first: seven type-6 deferred updates for the seven
  delivered payloads and no other callback type, so the acknowledgement is
  proven to leave before any validation or state read.
  Five later answers travel the interaction webhook as private follow-ups (the
  free-form option, the non-captain refusal, the unknown card, the malformed
  custom id, and the unidentified payload).
- The deferred update is followed by a `PATCH` of the card message whose buttons
  all carry `disabled: true`.
- A non-captain press, a custom id naming no card, and a malformed custom id are
  each refused and audited under `cards/interactions/<interaction-id>.json` with
  the reason `non-captain`, `unknown-card`, and `unknown-custom-id`.
  A payload carrying no identity is audited as `status: unidentified` /
  `reason: missing-user-id`, and its follow-up is not the captain-only line.
- Focused checks over fake payloads prove the acknowledgement ordering (the
  acknowledgement precedes the card read and the intake), that a timed-out
  interaction request is never retried, and that a failed acknowledgement is
  recorded with its reason rather than swallowed.
- A `later` option records the dated deferral: the fixture backlog reads
  `hold-until: 2026-10-01` for the task.
- `card` only posts while its task is still an open captain call, checked against
  the authoritative hold state (`bin/fm-captain-hold.sh open`) rather than the
  card's prose: an unheld queued task and an already-closed task each refuse with
  an error naming the task and the reason, while a legitimately held task posts.
  The press-time intake remains the second line of defence and records the
  intake's own clear hold reason, distinct from an unidentified presser.
- `card` refuses while the permanent connection source is not registered, and its
  `--dry-run` prints the plan with no network call.

## Live evidence and what remains

The first real press against the pre-fix console failed in production: a guild
interaction carries the presser under `member.user`, the handler read only a
top-level `user`, and the empty id was refused as `non-captain` while the
acknowledgement left too late for Discord's 3-second window.
This branch resolves the guild identity, acknowledges first inside that window
with a short bound that is never retried, records an acknowledgement failure, and
answers refusals and the free-form option as webhook follow-ups.

A real card was **not** minted from this worktree.
The registered gateway source still runs the pre-change code until the branch
lands and the console restarts, so a card posted now would be exactly the
unanswerable button the contract forbids.
And the press itself is the captain's own action in Discord, not something this
suite can mint.

The posting hold guard was checked live against a throwaway home with a real
markdown backlog and a registered gateway source, with no network call reached:

```sh
bin/fm-tasks-axi.sh add card-live-unheld "Live unheld card target" --kind ship
bin/fm-discord-conversation-console.sh card --config <config> \
    --channel <firstmate channel id> --card-file <card json> --nonce live-unheld
# fm-discord-workspace: task card-live-unheld is not held for the captain
```

Until a real card is pressed against the restarted console, the following remain
to confirm live: the real gateway delivering `INTERACTION_CREATE` to the fixed
handler, the real callback and the
`PATCH /webhooks/<app>/<token>/messages/@original` and
`POST /webhooks/<app>/<token>` endpoints accepting the acknowledge-first
sequence, and the live card rendering its buttons for the captain.

The post-merge live check is one card and one press:

```sh
bin/fm-captain-hold.sh hold card-live-check --title "Card live check" --reason "Live card check" --repo firstmate
bin/fm-discord-conversation-console.sh card --config config/discord-conversation-console.json \
    --channel <firstmate channel id> --card-file <card json>
```

The recorded answer is then observable in that task's backlog row through
`bin/fm-tasks-axi.sh show card-live-check`.
