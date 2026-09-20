# Discord console uncertain-transcription confirmation card - verification

This record holds the active empirical claims behind the #firstmate console's
confirmation card for an uncertain voice transcription: the one-card-per-reading
posting, the three existing card actions it maps onto, the captain-only and
idempotent press, the durable records, and what remains to be pressed live.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md)
("Confirming an uncertain reading"); this page is evidence, not a second
contract.

## Environment and commands

Measured on 2026-09-20 on the firstmate host, Python 3.12, against the fake local
Discord HTTP server and fake local gateway websocket the two suites own, plus the
real Groq endpoint and the real console records of the firstmate home.
No real token is read by the suites and no suite request leaves loopback.

```sh
bash tests/fm-discord-conversation-console-audio.test.sh
bash tests/fm-discord-conversation-console.test.sh
```

The relevant suite lines are:

```
ok - an uncertain transcription carries a visible marker into the note and the thread
ok - an uncertain reading carries a confirmation card the captain can press, once
ok - an uncertain reading's card is posted by the console once and its presses are captain-only and task-free
```

`bin/fm-lint.sh` is green over the changed shell and test files.

## What the suites prove

On the fake Discord server the audio suite drives the real capture path, and the
console suite drives the real press handler:

- One confirmation card follows one uncertain reading: it is posted in the
  reading's own conversation, immediately after the transcript message, with a
  single action row of three buttons - `C'est bien ça` (style 3), `Je corrige`
  (style 2), `À jeter` (style 4) - whose custom ids are
  `fmcard:<card-id>:<index>` and whose card id is derived from the request id.
  A settled reading posts no card.
- The card body carries the reading under the ordinary uncertain marker, the
  durable note names the card for that reading, and the reading's transcript
  record gains `confirm_card: {status: posted, card_id}`.
- The post is where its press could arrive and nowhere else: with the permanent
  connection not registered, or posting off, or the switch off, no card is posted
  and the reading's record carries `confirm_card: {status: skipped, reason}`.
- A replay posts no second card and no second transcript, and keeps one open
  card, because the card id is derived from the request id.
- A captain press on the confirmation option records `status: recorded` with
  `action: answer`, moves the card to `answered` with the reading as its recorded
  value, and folds `confirmation: {status: confirmed, ...}` into the reading's
  transcript record with the second reading still intact.
- A repeated delivery of the same interaction id records nothing a second time
  and appends no second wake.
- A non-captain press on the card is recorded `refused` / `non-captain`, appends
  no wake, leaves the card open, and folds no confirmation into the reading.
- The discard option maps onto the existing `release` action: the card records
  it, the reading's transcript record reads `confirmation: {status: discarded}`,
  and the transcript text and the second reading are still there - nothing is
  deleted.
- The correction option maps onto the existing free-form `chat` action: no answer
  is recorded, the reading's record reads `confirmation: {status: correcting}`,
  and one wake names the requested correction.
- Every transcript press appends exactly one durable wake through the same
  captain-inbox seam a task card uses, with `transcript confirmed <request-id>:
  <label>`, `transcript correction requested <request-id>: <label>`, or
  `transcript reading discarded <request-id>: <label>`.
- No transcript press ever feeds the keyed-answer intake: the intake command is
  asserted never to be called for a transcript card, because an uncertain reading
  is not a captain-held task and the console never mints one for it.
- The task-card command refuses a transcript card file and names the console as
  the poster, so the two card owners cannot be confused.
- `status` reports the switch and the `transcript confirmation cards: <n> posted,
  <n> open` counts, and `config-check` reports the switch: on the real home both
  read `transcription confirmation card: on`.

## Live evidence

The console's own records hold the uncertain reading this work is about - one real
captain voice message, transcribed live on 2026-09-20:

```
request_id:  discord:1525898345338372136:1550470253551685734:1551182432139747400
reading:     Est-ce que tu m'entends ? Cette audio est un test.
second:      cette audio est un test
status:      disagree, word agreement 0.625, uncertain: true
recorded_at: 2026-09-20T10:45:12Z
```

Running this branch's own card builder over that real record (real request id,
real reading, no network call) produced:

```
card_id:  32ffffa1b502660b
body:     Transcription incertaine - à confirmer : Est-ce que tu m'entends ? Cette audio est un test.

          Deux lectures du même audio divergent : confirme la lecture, corrige-la, ou jette-la.
buttons:  C'est bien ça (style 3) | Je corrige (style 2) | À jeter (style 4)
custom:   fmcard:32ffffa1b502660b:0 | fmcard:32ffffa1b502660b:1 | fmcard:32ffffa1b502660b:2
```

The real home's preconditions were read live, read-only:

```sh
FM_HOME=/home/dutopy/atelier bin/fm-discord-conversation-console.sh config-check --config /home/dutopy/atelier/config/discord-conversation-console.json
FM_HOME=/home/dutopy/atelier bin/fm-discord-conversation-console.sh status --config /home/dutopy/atelier/config/discord-conversation-console.json
```

```
health: healthy
live posting: on
live gateway: on
listener registered: yes
connection mode: gateway
transcription confirmation card: on
```

The uncertain verdict itself was also reproduced against the real Groq endpoint on
2026-09-20, with the real `GROQ_API_KEY` from the firstmate home and locally
synthesized speech, through `bin/fm_groq_whisper.py`'s `transcribe_checked` (the
exact function the console's capture path calls):

```
Are_you_listening,_you_are_astray.ogg  0.61s  disagree  ratio 0.111
  reading:  Vous écoutez ? Vous êtes en étrange.
  second:   Est-ce que tu écoutes ? Tu es en train de se déranger.
Are_you_stopped_right_now.ogg          0.69s  agree     ratio 1.0
Is_everything_all_right.ogg            0.88s  agree     ratio 1.0
```

So the real uncertainty branch and the real "settled reading gets no card" branch
both rest on live endpoint evidence, and the real card body, buttons, and card id
above are built from the captain's real uncertain reading.

The press machinery the card rides is live-proven on the task-card surface: the
live console state holds 41 posted cards and 47 interaction records, 39 of them
`recorded` presses carrying the captain's own user id `1487196891757154484` with
real message ids, and 2 early `refused` / `non-captain` presses. What this branch
adds is the transcript target, not a new transport, callback, or identity path.

## What remains to confirm live

A real press on a **transcript** card is not minted from this worktree, for the
same reason the task-card work could not mint one: the registered permanent
connection still runs the pre-change module until this branch lands and the
console restarts, so a card posted now would be an unanswerable button, which the
contract forbids, and the press itself is the captain's own action in Discord.
The live confirmation is therefore one restart and one press after the merge:

```sh
bin/fm-discord-conversation-console.sh stop  --config config/discord-conversation-console.json
bin/fm-discord-conversation-console.sh start --config config/discord-conversation-console.json
# then one uncertain voice message, and one press on its card
bin/fm-discord-conversation-console.sh status --config config/discord-conversation-console.json
```

`status` then reports `transcript confirmation cards: 1 posted, 0 open`, the
reading's `transcripts/<sha256>.json` carries
`confirmation: {status: confirmed}`, and the card message in the conversation
shows the recorded answer with its buttons disabled.

Not implemented, deliberately: an emoji-reaction surface for the same
confirmation. It is not free - it needs a new gateway intent and a second inbound
event path with its own identity fallback and its own idempotence across two
surfaces that could confirm one reading twice - while the card already gives the
one-press confirmation the captain asked for, and the captain's refinement made
the card the required affordance and kept emoji only if it came for free.

Also not verified: that Discord renders this card's three buttons for the captain
(the shape is the one live task cards already render, but no transcript card was
posted live), and that a real correction typed in chat is matched back to the
reading by the session (the console records `correcting` and wakes firstmate; the
chat answer itself is the existing typed path, unchanged).

The brief's "keep the audio available" is satisfied within this task's stated
scope as "keep the durable records": the raw audio path is explicitly out of
scope and still deletes its temporary file after transcription, while both
readings and the reading's status remain in the transcript record.

## Undoing a live change

The branch itself changes no running behavior until the console restarts, so
reverting the commits on the default branch before a restart is the complete
undo of the code.

Each live-facing change and its exact undo:

- The switch is `transcription.confirm_card` in
  `config/discord-conversation-console.json`, default on.
  Its undo is to set it to `false` and restart the listener with
  `bin/fm-discord-conversation-console.sh stop --config <json>` then
  `bin/fm-discord-conversation-console.sh start --config <json>`; the transcript
  path then behaves exactly as before and each reading's record says
  `confirm_card: {status: skipped, reason: the confirmation card is off}`.
- The durable records it writes are `cards/<card-id>.json` with
  `kind: transcript`, `cards/interactions/<interaction-id>.json`, and the
  `confirm_card` and `confirmation` blocks inside the reading's
  `transcripts/<sha256>.json`.
  Their undo is to delete the transcript-kind card records and those two blocks;
  the task-card records and the transcripts themselves are untouched.
- The posted card is one ordinary message in the conversation.
  Its undo is to delete it there; nothing else depends on it beyond the records
  above.
