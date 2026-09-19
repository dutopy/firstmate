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
  `MESSAGE_COMPONENT`.
  The captain's press on the decisive option records its exact value through the
  real keyed-answer intake: the fixture home's `data/backlog.md` gains one
  `Resolution recorded by fm-captain-hold.` block carrying `Oui, vas-y.`, and the
  card record reads `status: answered` with `answer.label: Oui`.
- A second delivery of the same interaction id records no second resolution
  block, and its callback is answered again.
- Every press is answered through Discord's interaction callback: two type-6
  deferred updates for the recorded press and its duplicate, and four type-4
  ephemeral replies for the free-form option and the three refusals.
- The deferred update is followed by a `PATCH` of the card message whose buttons
  all carry `disabled: true`.
- A non-captain press, a custom id naming no card, and a malformed custom id are
  each refused and audited under `cards/interactions/<interaction-id>.json` with
  the reason `non-captain`, `unknown-card`, and `unknown-custom-id`.
- A `later` option records the dated deferral: the fixture backlog reads
  `hold-until: 2026-10-01` for the task.
- `card` refuses while the permanent connection source is not registered, and its
  `--dry-run` prints the plan with no network call.

## What remains to confirm live

A real Discord round trip was **not** performed from this worktree.
Two facts put that step past this branch rather than inside it.
A posted button can only be answered by the running console, whose registered
gateway source still executes the pre-change code, so a card posted now would be
exactly the unanswerable button the contract forbids.
And the press itself is the captain's own action in Discord, not something this
suite can mint.
Until a real card is pressed against the restarted console, the following remain
to confirm live: the real gateway delivering `INTERACTION_CREATE` on the permanent
connection, the real callback and
`PATCH /webhooks/<app>/<token>/messages/@original` endpoints accepting the
type-6-then-edit sequence, and the live card rendering its buttons for the
captain.

The post-merge live check is one card and one press:

```sh
bin/fm-captain-hold.sh hold card-live-check --title "Card live check" --reason "Live card check" --repo firstmate
bin/fm-discord-conversation-console.sh card --config config/discord-conversation-console.json \
    --channel <firstmate channel id> --card-file <card json>
```

The recorded answer is then observable in that task's backlog row through
`bin/fm-tasks-axi.sh show card-live-check`.
