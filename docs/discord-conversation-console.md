# Discord conversation console

The conversation console lets the captain talk to Firstmate from Discord.
It reads the `#firstmate` text channel that exists on each internal server, turns
each captain message into durable firstmate input, and posts Firstmate's answer
back into the same conversation.

One conversation is one thread.
A message posted in a thread under `#firstmate` keeps that thread identity, so its
answer returns to that thread and several parallel conversations never cross.

It is separate from, and reuses, the private Discord operations workspace
(`discord-workspace.md`) and the per-project session mirror
(`discord-session-mirror.md`).
`bin/fm-discord-conversation-console.sh` is the only entrypoint for this
capability, and `bin/fm_discord_conversation_console_lib.py` owns its config
schema, state records, inbound pass, and outbound reply.
The console also carries the captain's native Pi session mirror
(`Session mirror` below), which is a different surface from the per-project
session mirror: it posts into this console's own channel, through this
console's own bot, and it is off by default.
It reuses `bin/fm_discord_workspace_lib.py` for the shared config, state, lock,
and receipt primitives, and `bin/fm_discord_live.py` for the Discord HTTP client,
token decryption, retry bounds, and token redaction.

## Configuration

The default config path is `config/discord-conversation-console.json` under the
effective `FM_HOME`; `--config` overrides it.
It is non-secret and gitignored.
Print a copyable draft and validate it with:

```sh
bin/fm-discord-conversation-console.sh sample-config
bin/fm-discord-conversation-console.sh config-check --config <json>
```

It names:

- `secret_file` and `discord_bot_token_key`: the same normalized
  `config/<name>.sops.yaml` reference and key name the other Discord surfaces use.
- `bot.user_id` and `captain_user_ids`: the exact bot identity and the only
  Discord accounts whose messages are accepted.
- `channels`: one entry per internal server, each with a `label`, the server
  `guild_id`, and the `#firstmate` `channel_id`.
- `live.polling` and `live.posting`: the two independent switches that permit the
  inbound read and the outbound write; both default to off.
- `live.gateway`: prefer the permanent Discord gateway connection over the
  bounded REST polling pass; defaults to off.
- `fast_path`: the instant acknowledgement, the Jev-gated record-backed answer,
  and the typing indicator; off by default. `docs/discord-conversation-console.md`
  owns the keys and the contract.
- `prepare`: the advisory request-preparation step that attaches a structured
  packet to the durable intake note; off by default. `docs/discord-conversation-console.md`
  owns the keys and the packet schema.
- `mirror`: the native Pi session mirror's switch, target channel, and bound;
  off by default. `Session mirror` below owns the contract.
- `gateway`: the gateway `url`, the `intents` bitfield, the reconnect
  `backoff_base_seconds` and `backoff_max_seconds`, and the
  `fallback_poll_seconds` and `fallback_after_attempts` that bound the polling
  fallback.
- `audio`: the Discord CDN host allowlist and the size and duration bounds for an
  incoming voice message or uploaded audio attachment.
- `transcription`: the Groq Whisper switch, the API key reference, the model, the
  language, the vocabulary prompt, the transcript display choice, and the
  second-reading confidence check with its duration bound; on by default.
- `bounds`: the per-pass message, thread, and retained ignored-record caps, and
  `bounds.reply_max_chars`, the hard character bound the reply path renders and
  trims every captain-facing answer to.

The config stores only secret file paths and key names, never a token or an API
key value. The Groq key itself is resolved from the environment first and then
from `GROQ_API_KEY=` in the home's gitignored `.env`, so the native secret
integration materializes it without a second bridge.

## Inbound

One bounded pass reads each configured `#firstmate` channel and the active and
archived public threads under it, newest messages last, after a durable
monotonic cursor per channel or thread.
An accepted message is a non-empty text message whose author is one of
`captain_user_ids` and is not the bot, or an audio message from the same captain
whose text is produced by transcription (`Audio transcription` below).
Each accepted message becomes one durable captain-inbox note through
`bin/fm-inbox.sh note --source discord --external-id <message id>`
(`inbox replay idempotency` in `discord-workspace.md` owns that seam).
The note body carries the request id and the thread or channel, so the answer can
be routed back without guessing.

Capture is exactly once across restarts: the inbox external id is the Discord
message id, so replaying a message yields the original note and appends no second
notification even when a cursor was lost.
Every other message `#firstmate` receives is ignored and recorded as ignored with
its reason, so a message is never silently dropped; repeated replays do not
duplicate an ignored record.
Cursors advance only after a message's handoff succeeds.

## Permanent connection

With `live.gateway` enabled, the console holds one long-lived Discord gateway
websocket instead of polling.
The bot appears online because the connection identifies with an `online`
presence, and each captain `MESSAGE_CREATE` dispatch is fed into the same
durable capture path the polling pass uses, idempotent by message id, so the
answer returns to the originating thread exactly as it does in polling mode.
A dispatch is accepted only from a configured `#firstmate` channel or a thread
whose parent is one; an unknown channel is resolved once through the REST API
and remembered, and any other guild, channel, author, or bot message is never
accepted.

The connection reconnects on its own with bounded exponential backoff and
resumes its gateway session, so a dropped or killed connection is recovered
without a duplicate capture.
If the connection cannot be established or re-established after
`fallback_after_attempts` consecutive failures, the console falls back to the
existing bounded polling pass at `fallback_poll_seconds`, still retrying the
gateway, so it never goes silent; the fallback ends as soon as a connection is
established.
The transport is a supervised process, never an LLM agent, and consumes no model
quota.

## Fast path

The transport is instant, but a full firstmate turn takes tens of seconds to drain
the fleet queue, review state, and answer.
The fast path removes that wait for the messages that do not need a full turn,
without changing what happens to the ones that do.
It is off by default; `fast_path.enabled` turns it on, and it does nothing unless
`live.posting` is also on.

For every accepted captain message the console first posts a short deterministic
acknowledgement in the same thread (or channel) - `fast_path.acknowledgement`,
no model and no wait - so a reaction is visible at once.
`fast_path.acknowledgement_enabled` (default on) turns that message off while
keeping the typing indicator; at least one visible sign of activity must remain,
so a config that disables both is refused.
Then Jev, through `bin/fm-jev-console-route.sh`, decides whether the message is a
plain status lookup answerable from durable records or needs the full turn.
A confident `fast_answer` builds the answer deterministically from
`bin/fm-crew-state.sh`, the backlog, and the in-flight list, and posts it in the
same thread; the full-turn route captures the message exactly as before.

Fail-closed is the whole contract: any missing classifier, error, timeout,
malformed verdict, low confidence, unbuildable answer, or failed post sends the
message to the full firstmate turn through the same durable external-id capture.
The fast path never guesses and never answers a message it cannot state from the
records.
The decision record keeps that distinction: a classifier full turn is recorded
with the classifier's own verdict, confidence, reason, and flag, while the
literal reason `classifier unavailable or refused` is reserved for a classifier
that was missing, failed, timed out, or emitted an unreadable verdict.

Idempotence is by request id.
The acknowledgement, the fast answer, and the decision each have a durable record
under `fast_path/` in the console state, so a replayed capture posts no second
acknowledgement and no second answer; the full-turn capture keeps its existing
external-id idempotence.
Every message also gets one `fast-path/audits/<request>.json` record under the
console state naming the classifier verdict, its confidence, and the chosen path,
so the routing is auditable.
`status` reports the fast-path switch, the acknowledgement and typing switches,
the acknowledgement and audit counts, and the last route.

The config keys are `fast_path.enabled`, `fast_path.answers`,
`fast_path.acknowledgement`, `fast_path.acknowledgement_enabled`,
`fast_path.typing`, `fast_path.classifier_command`,
`fast_path.classifier_timeout_seconds`, and `fast_path.max_answer_chars`.

## Prepared request

The captain writes free-form prose; the main turn then spends its first moments
working out what kind of message it is, which project and task it is about, and
which records to read.
The prepared request removes that work from the turn: one bounded advisory step
reads the message before the main turn and attaches a structured packet to the
durable intake note.
It is off by default; `prepare.enabled` turns it on.

Preparation is advisory and read-only with respect to the fleet.
It never answers the captain, never dispatches work, never changes a task
record, and never calls anything but the classifier and the read-only records.
The captain's raw message always travels with the packet and stays the
authority.

### The packet

One packet is recorded durably per message under `prepare/` in the console
state, and the same content is rendered into the note the session reads:

```json
{
  "schema": "fm-discord-conversation-console.prepared-request.v1",
  "request_id": "discord:<guild>:<channel>:<message>",
  "intent": "state_question | new_work | decision_answer | chat",
  "intent_confidence": 0.96,
  "project": "firstmate",
  "entity": "discord-console-jev-request-preparation",
  "ask": "the captain's own words, whitespace-normalised onto one line",
  "identifiers": {
    "task": "the task id the message is about, or empty",
    "pr": ["https://github.com/<owner>/<repo>/pull/<n>"],
    "date": ["2026-09-20"],
    "received": "2026-09-20",
    "channel": "<channel or thread id>",
    "thread": "<thread id, or empty>"
  },
  "facts": ["three to five lines read from the records"],
  "raw_message": "the captain's exact message",
  "raw_message_chars": 96,
  "raw_message_sha256": "<sha256 of the raw message>",
  "prepared_at": "<UTC timestamp>"
}
```

The note renders it as a `PREPARED REQUEST` block - `intent`, `project` and
`entity`, `ask`, `identifiers`, and `facts` - followed by `RAW MESSAGE
(authoritative)` and the captain's exact text.
A note with no packet is byte-for-byte the note the console wrote before this
step existed.

`intent` is one of four classes: a state question answerable from current
records, new work, an answer or decision for something firstmate asked, or chat
that needs no lookup.
`ask` is a faithful one-line normalisation - whitespace collapsed, bounded -
and never a paraphrase, so the packet cannot become a second, model-authored
version of the request that diverges from what the captain sent.
`identifiers` is read from the message and the records: a task id is reported
only when it names a task that exists, a pull request only when its full URL
appears in the text, and a date only when the message carries one.
`received` is the message's own creation date.
Each `facts` line is a read of an existing record - the reconciled task state
(`bin/fm-crew-state.sh`), the backlog line, the task's latest recorded event, a
recorded pull-request link, the in-flight list, the project registry - and
nothing is inferred.

`project` and `entity` are selected, never generated: the console passes the
model the code-built candidate lists (the registry's project ids, and the task
ids the message names plus the in-flight backlog), so it can only choose a value
that already exists.
A candidate list that is empty is not asked about, and that axis answers
`null`.

### Fail-closed preparation

Every outcome other than a confident, well-formed verdict is the fallback, and
the fallback is the raw message alone.
A disabled switch, an unavailable or missing classifier command, an API or
network error, a malformed response, an out-of-vocabulary answer, a confidence
below `FM_JV_PREPARE_THRESHOLD` (default 0.9), and the wall-clock bound all
produce a durable outcome with `status: fallback` and a reason naming what
happened, and the note keeps the raw message with no `PREPARED REQUEST` block.
`FM_JV_PREPARE_TIMEOUT` bounds the classifier wall clock, and the console's own
`prepare.timeout_seconds` (default 4, at most 60) bounds the child: a stuck
preparer is killed, never waited on.

Preparation is separate from the reply path.
It cannot answer a message, and it cannot change the route: the fast path still
decides between a record-backed answer and the full turn, exactly as before.
A message the fast path answers posts its answer and never becomes a note, so
its started preparation is cancelled at once instead of being waited on.
An uncertain transcription is not prepared at all.

The config keys are `prepare.enabled`, `prepare.classifier_command`,
`prepare.timeout_seconds` (default 4, at most 60), and `prepare.max_facts`
(default 5, between 3 and 5).
The classifier's own floor and bound are `FM_JV_PREPARE_THRESHOLD` (default 0.9)
and `FM_JV_PREPARE_TIMEOUT` (default 20).

### Cost and timing

The preparer is started beside the route gate and read only at the handoff, so
its call runs concurrently with the advisory call the capture already makes
rather than adding a second wait to the wake path.
It is the only new cost: the packet's facts are local record reads.
A real packet produced from a real captain message, next to that message, and
the measured cost and overlap proof are recorded in
[`verification/discord-console-prepared-request.md`](verification/discord-console-prepared-request.md).

### Seeing that a packet was used or skipped

- `status` reports `request preparation: on|off`, `packets prepared: <n>`,
  `packets skipped: <n>`, and `prepare last: <status> (<reason>)`.
- `latency` prints each request's `prepare` status and its `prepare_ms`, and its
  medians include `prepare_ms`, so the capture cost and the prepared/skipped mix
  are readable per request and in aggregate.
- Every message's durable outcome is one JSON record under `prepare/` in the
  console state, keyed by the request: `status`, `reason`, `duration_ms`, and the
  `packet` itself when it was used.
- The note itself is the third signal: the `PREPARED REQUEST` block is present
  exactly when a packet was used.

### Undoing a live change

Preparation ships off, so nothing changes until it is enabled.
Each live-facing change and its exact undo:

- Enabling it is `prepare.enabled: true` in `config/discord-conversation-console.json`.
  Its undo is to set that back to `false` (or remove the `prepare` block) and
  restart the listener with `bin/fm-discord-conversation-console.sh stop --config
  <json>` then `bin/fm-discord-conversation-console.sh start --config <json>`.
- The durable outcomes it writes are `prepare/` under the console state.
  Its undo is to delete that directory, after which `status` reports zero
  prepared and zero skipped.
- The code itself is this capability's commits.
  Its undo is to revert them on the default branch, because nothing else in the
  console depends on them.

## Captain-message fast lane

The capture path is instant, but a captain note still has to reach Firstmate's
session.
On the Pi primary harness the session is often mid-turn on fleet work, and a
wake queued as a follow-up waits for that whole turn to finish - the live
latency journal measured stage 4 at 250-565 s on such a busy session.
`fast_path.acknowledgement_enabled` does not change this: the acknowledgement
is posted by the console, not by the session.

A captain-inbox note wake (`check: captain inbox note ...`) is therefore
delivered as Pi **steering input** rather than as a follow-up.
Pi hands steering input to the running run at the next LLM boundary, so the note
is drained and answered without waiting the turn out, while every other main
wake keeps the follow-up delivery the continuity and replacement-handoff
contract was built on.
The wake itself, the durable captain-inbox note, and the durable wake queue are
unchanged: only the moment Pi surfaces the already-durable wake moves, so a
session replacement still replays an unconsumed wake and the poll and queue
remain the fallback.
This is a Pi-only behavior; another primary harness keeps its existing delivery
until its own wake path is converted.
Shortening the wake path itself was the rejected alternative: the watcher cycle
that surfaces the note is the durable, fail-closed scanner, and its busy period
is legitimate work, so cutting it would need a second delivery path or a new
scheduling rule and would put the durable queue guarantee at risk for a smaller
win than the delivery-mode change.

## Short captain-facing answers

Captain chat is read on a phone, so the reply text itself is short: a few
sentences of outcome, not a report.
The captain-inbox note body carries that instruction next to the exact reply
command, so the requirement travels with the request.

## Reply presentation

The reply command renders one deterministic shape; the reply path never sends the
raw answer file.
A blank line splits the answer into sections, the first line of a multi-line
section (or a short line ending in `:`) becomes a bold label, list lines are
normalized to `- ` bullets, and a URL is left intact so Discord auto-links it.
A plain one-line sentence is not bolded, so an ordinary answer reads unchanged.
The renderer is model-free and takes no extra call.

The whole rendered reply is then cut to `bounds.reply_max_chars` (default 1900,
never above Discord's 2000-character body limit), on a whitespace boundary and
never through a URL, so the reply stays short by construction rather than by
trusting the prose.
The same bound applies to a record-backed fast answer.

## Action cards

A card is one captain-facing message - a decision, a blocker, or a clarification -
carrying up to five labelled option buttons, so answering is one press instead of a
typed sentence.
Post one with:

```sh
bin/fm-discord-conversation-console.sh card [--config <json>] --card-file <json>
    (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
    [--task-id <id>] [--nonce <n>] [--dry-run]
```

The card file is local JSON owned by the caller:

```json
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "the-held-task",
  "body": "The body the captain reads.",
  "fallback_hint": "Or answer directly in the conversation.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "the captain's exact words"},
    {"label": "Non", "action": "answer", "value": "another exact answer"},
    {"label": "Plus tard", "action": "later", "until": "2026-10-01"},
    {"label": "Je reponds en chat", "action": "chat"}
  ]
}
```

The caller supplies every word; the card path never invents an option from prose.
`body` and `fallback_hint` together stay inside `bounds.reply_max_chars`, `options`
carries one to five entries, each `label` is unique, an `answer` or `release`
option requires its exact `value`, and a `later` option requires an `until` date.
An optional `style` picks the button colour (1 primary, 2 secondary, 3 success, 4
danger), defaulting to primary for an answer, success for a release, and secondary
otherwise.

Posting needs `live.posting` and `live.gateway`, and refuses while the permanent
connection source is not registered, because a bounded poll cannot receive an
interaction and a card posted without one would render with buttons that could
never be answered.
Posting also refuses unless the card's task is still an open captain call,
checked against the authoritative hold state (`bin/fm-captain-hold.sh open`) and
never the card's prose: an unheld queued task and an already-closed task both
refuse with an error naming the task and the reason, so every button on a posted
card can validate.
Only one card may be open for a task at a time, so the open card must be answered
before a new one is posted for the same task.
The posted card's task id, option set, body, and message id are stored durably
under `cards/` in the console state, keyed by a card id derived from the nonce, so
a replay with the same nonce posts no second card.

Opening a captain call can also publish its card in the same act:
`bin/fm-captain-hold.sh hold <task-id> ... --card-file <json>` (plus one
`--card-request-id`, `--card-thread`, or `--card-channel` target) posts the
card through this same card path, so a held call surfaces its card with no
manual step. The card's body and options are entirely the caller's file,
while the command line's task id is what the card binds to (passed through as
`card --task-id`), so a reused card file can never link the card to the wrong
held call. The posting path's own guards still refuse a second open card for
the task and a card for a call whose answer is already recorded. A publication
failure never fails the hold: the call stays held and visible through the
ordinary channels, and the failure is reported on stderr rather than swallowed.

A held card left unanswered is reminded once, and only once. The permanent
connection loop runs a bounded nudge scan at most once per ten minutes; a task
card that has been open past 24 hours (`CARD_NUDGE_DELAY_SECONDS`) while its
task is still an open captain call gets exactly one reminder message in its
channel, and the single attempt is recorded on the card whether it is
delivered or not, so a broken gateway can never spin. A card that is answered,
already nudged, too young, or whose call is no longer open receives none, and
a failed or undeliverable attempt is recorded as a visible delivery gap rather
than retried. `card-nudges [--dry-run]` runs the same bounded pass by hand.

A press arrives as a gateway `INTERACTION_CREATE` dispatch of type
`MESSAGE_COMPONENT`.
The console also posts one card of its own, with the same record store, press
handler, and wake seam but a different target: an uncertain transcription's
confirmation card, owned by `Confirming an uncertain reading` above.
The presser is resolved through the same fallback the message path uses for an
author: the top-level `user` for a direct payload, else `member.user` for a guild
payload.
The console accepts it only from a configured captain user id and only for a
button of a card it posted in that same channel and message.
An identified non-captain or any other mismatch is refused with a private
follow-up and recorded; a payload carrying no usable identity is recorded
distinctly as unidentified and is never told that only the captain may answer.
Every received press is acknowledged first, before any validation or state read,
with a type-6 deferred update, so it reaches Discord inside its 3-second window; a
failed acknowledgement is recorded with its reason instead of being swallowed.
That short-bounded acknowledgement is never retried.
Because the first callback consumes the interaction response, every later answer
travels the interaction webhook: a recorded option edits the card message, while a
refusal or the free-form "answer in chat" option posts a private follow-up
message.
The interaction token in the path is its credential, so the bot token is never
sent on that path.

A recorded option feeds the same keyed-answer intake a typed reply uses:
`bin/fm-captain-hold.sh answer <task-id> --decision-file <file>` for `answer` (with
`--release` for `release`), and `bin/fm-captain-hold.sh hold <task-id> --reason ...
--until <date>` for `later`.
The two decisive actions are deliberately different: an `answer` button writes the
captain's exact words and closes the call, while a `release` button only lifts the
hold so already-authorized work continues - it is a liberation, not a
work-closing answer. The intake enforces the same distinction and refuses the
inverse error: a recorded release cannot be replayed as a close, and a recorded
answer cannot be replayed as a release.
The card is then edited to show the recorded answer and its buttons are disabled;
a failed intake leaves the buttons enabled and says so, so the captain can retry.
The press-time intake is the second line of defence behind the posting hold
check, and its recorded failure reason is the intake's own clear hold message
(for example `task <id> is not held for the captain`), distinct from an
unidentified presser.
The interaction id is recorded durably under `cards/interactions/`, so a repeated
delivery edits the card again without recording a second answer.
A validated press also appends exactly one durable wake through the same
captain-inbox seam a typed message uses
(`bin/fm-inbox.sh note --source discord-card --external-id <interaction id>`), so
firstmate's ordinary supervision picks the recorded answer up without the captain
saying anything in chat.
The interaction id is the inbox external id, so a repeated delivery appends no
second wake, and a refused or failed press appends none.
The wake body names the task and the recorded option
(`card answer <task-id>: <label>`).
`chat` records nothing and posts one private follow-up line asking for a chat
answer.

## Typing indicator

A full turn can take a minute or more, so the captain should see that firstmate is
working.
When a message is routed to the full turn, `fast_path.typing` (default on) starts a
bounded typing keeper for that conversation: a short-lived detached process that
re-emits the Discord typing indicator every `fast_path.typing_interval_seconds`
until the durable stop marker is removed or `fast_path.typing_max_seconds`
passes.
The reply command removes the marker, so the indicator stops when the answer is
posted; the hard deadline bounds a keeper whose answer never comes.
There is exactly one keeper per conversation, a replayed capture never restarts
one, and a fast answer or an ignored message never starts one.
`status` reports how many keepers are active.

## Audio transcription

The captain can talk instead of typing.
When a captain message carries a Discord voice message or a supported audio
attachment and no typed caption, the console downloads the audio inside the
configured CDN allowlist, transcribes it through Groq Whisper
`whisper-large-v3` in French with the captain's vocabulary prompt, and feeds the
transcript into the exact same capture path as a typed message.
The acknowledgement, the fast path, the typing indicator, and the full turn
behave identically, the durable request id still names the originating thread, and
the answer lands there.

The transcript is shown in the thread (`transcription.post_transcript`, default
on) so the captain can see what was heard before firstmate answers.
Transcription is on by default (`transcription.enabled`, `transcription.provider=groq`);
setting `transcription.enabled=false` turns it off, and then an audio message is
ignored exactly as before.

### Transcription confidence

A short phrase can mishear into a phonetically adjacent sentence with the
opposite meaning, and a garbled question about state is indistinguishable from a
garbled instruction, so an unchecked transcript would be trusted rather than
questioned.
The transcript is therefore read twice for audio at or under
`transcription.confidence_check_max_seconds` (default 30): the same audio, the
same French language, and the same vocabulary prompt, decoded once more at a
different temperature through one extra bounded call.
Readings that agree on the words - ignoring case, accents, punctuation,
spacing, and a word more or less - are delivered unmarked.
Two readings that disagree mark the transcript, and so does a second call that
fails, because an unverified reading is not a settled one.
The first reading is always delivered: the point is to make the doubt visible,
never to withhold or replace what was heard.

An uncertain transcript reaches both readers:

- the thread shows it under `Transcription incertaine - à confirmer : ` instead
  of the ordinary prefix;
- the durable note carries `transcription-uncertain` with the reason, the second
  reading as `transcription-second-reading` when there was one, and the
  instruction to have the captain confirm the spoken words before answering;
- the fast path is skipped for it, because a record-backed answer to a question
  the captain may not have asked is worse than a slower confirmation, so the
  message always takes the full turn and no `On it - checking the records.`
  acknowledgement is posted for it.

The extra call is bounded: one call, no retry, only for short audio (a longer
attachment is read once and its record says the check was skipped), and a second
call that is slower than `min(transcription.timeout_seconds, 20)` is marked as
unverified rather than retried or silently accepted.
Two readings agree when their words are at least 75% similar at the word level,
which leaves an ordinary decode difference alone and separates a reading that
heard a different sentence.
`transcription.confidence_check` (default on) turns the whole check off.
The confidence record keeps only a status, the uncertainty flag, whether the
check ran, the agreement ratio, the second reading, and a bounded redacted
reason, so no key and no audio can reach a durable record.

The temporary audio lives in one mode-0600 file under the console state, is read
once, and is deleted before the request returns, including on every failure path.
The transcript record keeps only text and non-secret metadata, so no audio and no
API key ever reaches a durable record or a log.

The config keys are `transcription.enabled`, `transcription.provider`,
`transcription.api_key` (the uppercase secret reference, default `GROQ_API_KEY`),
`transcription.model` (fixed at `whisper-large-v3`, never turbo),
`transcription.language` (default `fr`), `transcription.prompt`,
`transcription.base_url`, `transcription.timeout_seconds`,
`transcription.transcript_prefix`, `transcription.post_transcript`,
`transcription.confidence_check`, and
`transcription.confidence_check_max_seconds`, plus
`transcription.confirm_card` (default on) for the confirmation card below.
The shared `audio` section owns `max_bytes`, `max_duration_secs`,
`delete_temporary_raw`, and `allowed_cdn_hosts`.
A transcription is exactly once per request id: a replayed capture reuses the
first transcript and never downloads or calls Groq again.
A missing key, an unsupported or oversized attachment, a download error, or a
failed transcription is answered with one honest line in the same conversation
instead of silence, and the failed request is recorded durably.
`status` reports the switch, the recorded transcript counts, and the model and
language.

### Confirming an uncertain reading

An uncertain transcript already stops the fast path and asks the captain to
confirm the spoken words; the confirmation card makes that confirmation one
press instead of a typed correction, and it is an addition to the existing chat
confirmation rather than a replacement for it.
When the readings disagree, or the second reading failed, and the console is
posting, it posts the uncertain reading as an action card in the same
conversation, immediately after the transcript message, and the durable note
names that card.
The card's three buttons are the three existing card actions, mapped onto that
reading:

- `C'est bien ça` is the card's `answer` option: the reading as it was heard is
  confirmed, and the confirmation is recorded on the card and on the reading's
  own transcript record.
- `Je corrige` is the card's `chat` option: nothing is recorded as an answer, the
  console posts the ordinary answer-in-chat line, and the recorded outcome is
  that a correction is coming in the conversation.
- `À jeter` is the card's `release` option: only that reading is dropped, and
  no durable record and no second reading is deleted with it.

A press is handled by the same card path every task card uses: it is
acknowledged first, accepted only from a configured captain user id, refused with
a private follow-up otherwise, idempotent by interaction id, recorded durably,
and announced as exactly one durable wake through the same captain-inbox seam.
The buttons are then disabled and the card shows the recorded outcome.
The wake names the reading's own request id rather than a task, because an
uncertain reading is not a captain-held backlog task and the console never
creates one for it: `transcript confirmed <request-id>: <label>`,
`transcript correction requested <request-id>: <label>`, or
`transcript reading discarded <request-id>: <label>`.

A card is posted only where a press could arrive: `transcription.confirm_card`
(default on), `live.posting` and `live.gateway` on, and the permanent connection
registered.
When any of those is missing, or the reading cannot be rendered as a card, no
card is posted, the reading's record says why, and the existing chat
confirmation is the only path, exactly as before.
One card belongs to one reading: the card id is derived from the request id, so a
replayed capture posts no second card and records no second outcome.

When nothing is pressed, nothing else happens: the card stays open, the reading
stays marked uncertain, the note's instruction to confirm the words stands, the
captain can still answer in chat, and no reminder or retry is posted.

`status` reports the switch and the posted and open confirmation-card counts,
and `config-check` reports the switch.
Each posted card is a `cards/<card-id>.json` record with `kind: transcript`, the
reading's request id, and an empty `task_id`; each press is a
`cards/interactions/<interaction-id>.json` record; the reading's
transcript record gains `confirm_card` (posted, or skipped with its reason) and
`confirmation` (confirmed, correcting, or discarded, with the presser and the
time).
Posting an uncertain reading as a card never touches a captain hold and never
changes what is transcribed or stored about the audio.

## Outbound

Post Firstmate's answer into the conversation it answers:

```sh
bin/fm-discord-conversation-console.sh reply --request-id discord:<guild>:<channel>:<message> --text-file <file>
bin/fm-discord-conversation-console.sh reply --thread <thread id> --text-file <file>
bin/fm-discord-conversation-console.sh reply --channel <firstmate channel id> --text-file <file>
```

`--request-id` is the request the note carried; the message id is its anchor.
A message that had no thread is answered in the channel itself.
Every write is refused unless the config enables `live.posting`, posts with
`allowed_mentions: {"parse": []}`, and reuses the shared nonce-keyed receipt so a
retry with the same text never posts twice.
`--dry-run` prints the plan and the rendered reply with no network call.
The bot token is decrypted into process memory only and is redacted from every
failure path; operational supervision text is refused before any publish.
The note body asks for a short answer; see `Short captain-facing answers` above.
The reply path renders the presentation shape owned by `Reply presentation`
before posting, and the fast path renders its record-backed answer through the
same function.
The full reply path is unchanged otherwise - no model call is added and no answer
is guessed.

## Session mirror

The captain's terminal Pi session can be mirrored into the same `#firstmate`
channel, so what happens at the keyboard is visible on Discord too.
It is off by default and it introduces no second identity: the mirror posts
through this console's own bot, into a channel named by this config.

Two owners, one concern each:

- `.pi/extensions/fm-discord-session-mirror.ts` owns WHICH dialog is new: a
  durable cursor over the live Pi session file, consulted at every turn end.
- `bin/fm-discord-conversation-console.sh mirror` owns the delivery: the
  configured channel, the console identity, the bound, and the shared
  nonce-keyed receipt.

The extension is tracked with the other Pi extensions, so it loads from the
project's own extension directory like the watcher and the supervision branch.
It is inert until the config enables it, and it reads the live session only
through Pi's own session manager: it writes no session file.

### What is mirrored

One completed turn's visible conversational text: the captain's terminal
messages, attributed `[captain]`, and Firstmate's visible answers, attributed
`[main]`.
Everything else stays out: tool calls and results, reasoning, operational
injections (watcher wakes, session starts, launch briefs, the away supervisor),
an assistant message that failed, and any item with no visible text once
trimmed.
Collection happens at turn end, never mid-turn, so a partial turn is never
posted.

### Configuration

- `mirror.enabled` (default off) is the switch.
- `mirror.channel_id` is the target, and it must be one of the configured
  `#firstmate` channels; an enabled mirror with no channel, or with a channel
  outside the list, is refused at config load instead of guessed.
- `mirror.max_chars` (default 1800, at least 100 and never above Discord's 2000
  character body limit) is the bound every mirrored item is rendered to.

The config is re-read at every turn end, so turning the switch off stops the
mirror at the next turn boundary with no Pi restart.

### Delivery and idempotence

```sh
bin/fm-discord-conversation-console.sh mirror [--config <json>] --text-file <f>
    --item-key <durable item identity> [--tag captain|main] [--channel <id>] [--dry-run]
```

`--item-key` is the durable identity of the source item, built from the session
file and the entry's position, and it is what the receipt is keyed by.
The identity is the source position and never the text, so a restart, a
replayed turn, or a cursor lost between a post and its cursor write all converge
on one receipt and post nothing twice, while two identical lines from two
positions still post twice because they are two items.
A live replay of an already-delivered item prints `mirror exists for item ...;
no second post` and posts nothing.

A post is `[captain] <text>` or `[main] <text>`, bounded to `mirror.max_chars`
with any omission stated in place - `[mirror truncated: N characters omitted]`
between the head and the tail - so a long item is one bounded message rather
than a silently partial one.
An empty item is refused before any Discord call.
Operational text is a settled skip: nothing is posted, no receipt is written,
and the command exits successfully so its caller moves past that item instead
of retrying it forever.

### The durable cursor

The extension keeps one cursor record at
`state/discord-workspace/conversation-console/mirror-cursor.json`: the session
file, the entry position, when it last advanced, and the last delivery error.
It advances only after an item's delivery is settled, so a failed delivery
leaves the un-delivered items for the next turn end and records its reason
there, and a turn end delivers at most eight items so a backlog mirrors as a
bounded sequence rather than one burst.
A session the mirror has never recorded is seeded at its current position and
nothing is posted, which is what keeps enabling the mirror mid-session from
dumping that session's history into the channel.
`status` reports the cursor's file and position.

### Seeing that it works

- `config-check` prints `session mirror`, `mirror channel`, and `mirror bound`.
- `status` prints those and the cursor, so the position the mirror will resume
  from is readable without reading any record by hand.
- Every delivery writes the shared receipt under
  `state/discord-workspace/receipts/`, carrying `kind: mirror`, the item nonce,
  the target channel, and the Discord message id it posted.
- `--dry-run` prints the plan and the bounded body and posts nothing.

### Undoing a live change

The capability ships off, so merging the code alone changes no running
behavior.
Each live-facing change and its exact undo:

- Turning it on is `mirror.enabled: true` plus `mirror.channel_id` in
  `config/discord-conversation-console.json`.
  Its undo is to set `mirror.enabled` back to `false`, or to remove the `mirror`
  block entirely; either takes effect at the next turn end, with no Pi restart,
  because the extension re-reads the config every turn.
- Its durable records are `mirror-cursor.json` under the console state and the
  `kind: mirror` receipts.
  Their undo is to delete them, after which `status` reports no cursor and a
  replay of that session mirrors again from the seed position instead of
  trusting a receipt.
- The posted items are ordinary messages in the mirrored channel.
  Their undo is to delete them there; no other record depends on them beyond the
  receipts above.
- The code itself is this capability's commits.
  Its undo is to revert them on the default branch, because nothing else in the
  console depends on them.

### Cost

The mirror adds no model call.
One turn end with new dialog spawns at most eight short-lived commands, each one
Discord post bounded by `DELIVERY_TIMEOUT_MS` in the extension and by the
Discord client's own retry bounds, and a turn end with nothing new spawns none.

## Status

```sh
bin/fm-discord-conversation-console.sh status --config <json>
```

`status` reads local records only.
It never contacts Discord and changes no durable state, so it is safe to run in a
loop.
It reports a health verdict (`healthy`, `starting`, `stopped`, `polling-disabled`,
`polling-fallback`, `secret-missing`, `config-invalid`, or `state-malformed`),
each configured channel and its last cursor, the live switches, whether the
listener is registered, the connection mode and state, the last pass counts, the
posted, open, and recorded-interaction card counts, and the transcript
confirmation-card counts (`Confirming an uncertain reading` above).
It also reports the preparation switch, the prepared and skipped packet counts,
and the last preparation outcome (`Prepared request` above).
It reports the session mirror's switch, channel, bound, and durable cursor
(`Session mirror` above).
When the permanent connection is unavailable, the connection mode reads
`polling-fallback` so the fallback is visible.

A second read-only report,
`bin/fm-discord-conversation-console.sh latency --config <json> [--limit <n>] [--json]`,
prints the five measured stages per captured request and their medians: Discord
creation to console ingest, console handling, the wake reaching the session (the
watcher `.seen-inbox` marker), the session's acknowledgement (the
`fm-inbox.sh drain --ack` marker), and the turn up to the reply.
It also reports each capture's `transport` and the delivery gaps recorded when a
message reached the console through polling while `live.gateway` was enabled, or
when the permanent connection itself fell back.
The stages and the measured numbers are recorded in
[`verification/discord-console-latency.md`](verification/discord-console-latency.md).
A local captain-inbox note also kicks the waiting watcher so the note no longer
waits for a poll cycle; the durable queue and the poll remain the fallback.

## Run model

The continuous listener is the repository's process-event source pattern, not a
permanently running agent:

```sh
bin/fm-discord-conversation-console.sh start --config <json> [--dry-run]
bin/fm-discord-conversation-console.sh stop  --config <json>
```

`start` registers the permanent-connection source
`discord-conversation-console-gateway`
(`bin/fm-procevent-discord-conversation-console.sh gateway`) when `live.gateway`
is enabled, and the bounded REST source `discord-conversation-console`
(`bin/fm-procevent-discord-conversation-console.sh source`) otherwise, retiring
the other transport so polling and the permanent connection never both collect
the same message.
It refuses while `live.polling` is disabled.
`stop` retires both source ids.
The watcher reconciles and supervises the registered source: a crashed
connection daemon is launched again on the next cycle, and a dropped gateway
connection is re-established in process.
An operator can also run one polling pass by hand with `listen --config <json>`,
or hold the permanent connection in the foreground with
`connect --config <json>` (bounded for testing by `--once` or `--max-seconds`).

## Bot permissions

The bot must be a member of each configured internal server and needs these
permissions on the `#firstmate` channel (or its category):

- View Channel
- Send Messages
- Read Message History
- Send Messages in Threads

Optional: Embed Links and Attach Files for answers that contain links or small
files.
That is the shared steady-state thread permission integer used elsewhere in this
integration (`274878024704`).
The bounded polling pass reads the REST API, so no privileged Message Content
intent is required for it.
The permanent connection does require the privileged Message Content intent on
the Firstmate application, because a gateway `MESSAGE_CREATE` dispatch carries
the message text directly.
An action-card press needs no additional permission or privileged intent:
Discord delivers `INTERACTION_CREATE` over the same connection, and the reply is
sent through the interaction token in its own callback path.
Neither transport needs Manage Channels, Manage Threads, or Create Threads
permission: the captain creates threads, and the bot only reads and answers.
It never requires any Discord administration permission.

## Safety

Only the configured `#firstmate` channels and threads under them are read or
written; an unknown channel, thread, guild, author, or bot message is never
accepted.
There is no delete, archive, rename, or tag path, no channel or thread creation,
and no configuration of the Discord server structure.
The client guild and the orchestrator gateways are out of scope, and the shared
no-mistakes daemon is never touched.

## Verification

`tests/fm-discord-conversation-console.test.sh` drives the public interface
against a fake local Discord server and a fake local gateway websocket: a
captain message is captured exactly once across a restart, a non-captain message
is ignored and recorded, an answer lands in the originating thread with two
threads kept separate, a channel conversation is answered in its channel, the
reply renders the presentation shape and is cut to the configured bound, `status`
changes no durable state, `start` and `stop` register and retire the selected
transport, the permanent connection identifies with an online presence and
re-delivers a message after a forced disconnect without a second capture, an
unreachable connection falls back to polling without a duplicate capture, and a
crashed connection daemon is launched again by the next supervision cycle.

That suite also drives action cards through the same fake server and gateway: a
posted card carries its option buttons and a durable card record, a captain press
records the option's exact value through the real keyed-answer intake and disables
the buttons, a repeated interaction id records nothing a second time, a
non-captain or unknown button is refused and audited, and the interaction
callbacks are answered so no press is left unanswered.

`tests/fm-discord-console-fast-path.test.sh` drives the fast path against the
same fakes: the acknowledgement and the record-backed answer are posted in the
channel and in the thread with no full-turn capture, an uncertain and a failing
classification both fall back to the full turn and still capture, a replayed
capture posts no second acknowledgement, the disabled default leaves the
existing capture path unchanged, the acknowledgement switch off posts no
acknowledgement while the typing indicator still appears, the acknowledgement
defaults on when the switch is absent, disabling both the acknowledgement and
the typing indicator is refused, and the typing indicator is bounded to a full
turn and stops with the answer.
`tests/fm-jev-console-prepare.test.sh` drives the preparation classifier against
a fake System One server, covering the confident verdict, the code-built
candidate lists, and every fail-safe path.
`tests/fm-discord-console-prepare.test.sh` drives the prepared request end to
end: the packet and the raw message reach the same note, every fallback leaves
the raw message alone, a fast answer skips preparation without waiting for it,
the disabled default writes no preparation state, preparation never posts an
answer and never changes a task record, the prepared and skipped outcome is
visible through `status` and `latency`, preparation is exactly-once across a
replay, and the measured capture cost proves the preparer call runs beside the
route call rather than after it.
The measured numbers and method are recorded in
[`verification/discord-console-prepared-request.md`](verification/discord-console-prepared-request.md).
`tests/fm-jev-console-route.test.sh` drives the console-route classifier against
a fake System One server, covering both routes and every fail-safe path.
The measured live latencies and the observed full-turn baseline are recorded in
[`verification/discord-console-fast-path.md`](verification/discord-console-fast-path.md).

`tests/fm-discord-console-latency.test.sh` pins the wake-stage fix and the
latency report: with the local wake kick enabled a queued note is surfaced
inside the short bound, with it disabled the note waits for the poll, and the
`latency --json` report folds the durable watcher and inbox markers into the five
stages.
`tests/fm-pi-watch-extension.test.sh` pins the fast lane: a captain-inbox note
is delivered to main as steering input while every other main wake stays a
follow-up.
`tests/fm-pi-fast-lane-live-e2e.test.sh` measures the busy-session delivery
against the real installed Pi: a captain note reaches a mid-turn run at the next
tool boundary, well before the follow-up control.
The before and after numbers are recorded in
[`verification/discord-console-latency.md`](verification/discord-console-latency.md).

`tests/fm-discord-console-mirror.test.sh` drives the session mirror's delivery
path against the same fake server: one item posts once through the console's own
identity with an empty `allowed_mentions`, a replayed item key posts nothing
again, two identical lines from two positions post twice, a long item posts one
body inside the bound with its omission stated, an empty item posts nothing, and
operational text is a settled skip that records no receipt.
It also pins the configuration surface: `mirror.channel_id` decides the
destination, an unconfigured `--channel` is refused, a disabled mirror and a
disabled `live.posting` both refuse, the dry run posts nothing, and
`config-check` and `status` report the switch, the channel, the bound, and the
cursor without changing any durable state.
`tests/fm-pi-session-mirror-extension.test.sh` drives the real tracked extension
through a stubbed Pi session manager and the real `mirror` command against the
same fake server: a disabled mirror is inert, a session under the mirror's watch
mirrors its captain and answer lines in order, a lost cursor replays nothing
because the receipts own idempotence, an empty, tool-only, or errored item is
skipped while the cursor still advances, an operational injection stays
unmirrored, a mid-session enable seeds instead of dumping history, a refused
delivery holds the cursor and records its reason until the next turn delivers
it, and one turn end delivers at most eight items.
The live demonstration, its posted identifiers, and the replay that posted
nothing twice are recorded in
[`verification/discord-console-session-mirror.md`](verification/discord-console-session-mirror.md).

`tests/fm-discord-conversation-console-audio.test.sh` drives transcription
against a fake local Discord CDN and a fake local Groq API: a captain voice
message becomes the message text and is answered in its thread, the transcript is
shown there, a replay makes no second Groq call and posts no second transcript,
the temporary audio is deleted after success and after failure, the bot token and
the Groq key never reach durable state or the listener output, a corrupt and an
oversized audio each produce one honest reply instead of a crash, and a disabled
transcription leaves audio on the existing ignored path.
It also pins the confidence check on the exact request: the model, `fr`, and the
vocabulary prompt on every reading with only the temperature differing between
them; agreement unmarked; a disagreement and a failed second reading each marked
in the thread, in the note, and in the durable record, with the uncertain message
taking the full turn while the settled readings still answer from records; and a
long attachment read exactly once.
It also pins the confirmation card: one card per uncertain reading with the three
existing card actions and no card for a settled reading, the card named in the
note and recorded on the reading, and a replay posting no second card.
The dependency contract is owned by
[`verification/discord-console-audio-transcription.md`](verification/discord-console-audio-transcription.md).

`tests/fm-discord-conversation-console.test.sh`'s focused interaction checks also
drive the confirmation card's press path: a captain press records the
confirmation on the card and on the reading, a discard records the discarded
reading without deleting it, a correction records the chat path, a repeated
interaction id records nothing again, a non-captain press is refused and wakes
nobody, and no transcript press ever feeds the keyed-answer intake.
The measured evidence and what remains live are recorded in
[`verification/discord-console-uncertain-transcription-card.md`](verification/discord-console-uncertain-transcription-card.md).
