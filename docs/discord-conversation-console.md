# Discord conversation console

The conversation console lets the captain talk to Firstmate from Discord.
It reads the `#firstmate` text channel that exists on each internal server, turns
each captain message into durable firstmate input, and posts Firstmate's answer
back into the same conversation.

One conversation is one thread.
A message posted in a thread under `#firstmate` keeps that thread identity, so its
answer returns to that thread and several parallel conversations never cross.

It is separate from, and reuses, the private Discord operations workspace
(`discord-workspace.md`) and the session mirror (`discord-session-mirror.md`).
`bin/fm-discord-conversation-console.sh` is the only entrypoint for this
capability, and `bin/fm_discord_conversation_console_lib.py` owns its config
schema, state records, inbound pass, and outbound reply.
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
- `gateway`: the gateway `url`, the `intents` bitfield, the reconnect
  `backoff_base_seconds` and `backoff_max_seconds`, and the
  `fallback_poll_seconds` and `fallback_after_attempts` that bound the polling
  fallback.
- `audio`: the Discord CDN host allowlist and the size and duration bounds for an
  incoming voice message or uploaded audio attachment.
- `transcription`: the Groq Whisper switch, the API key reference, the model, the
  language, the vocabulary prompt, and the transcript display choice; on by
  default.
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
    [--nonce <n>] [--dry-run]
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

A press arrives as a gateway `INTERACTION_CREATE` dispatch of type
`MESSAGE_COMPONENT`.
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

The temporary audio lives in one mode-0600 file under the console state, is read
once, and is deleted before the request returns, including on every failure path.
The transcript record keeps only text and non-secret metadata, so no audio and no
API key ever reaches a durable record or a log.

The config keys are `transcription.enabled`, `transcription.provider`,
`transcription.api_key` (the uppercase secret reference, default `GROQ_API_KEY`),
`transcription.model` (fixed at `whisper-large-v3`, never turbo),
`transcription.language` (default `fr`), `transcription.prompt`,
`transcription.base_url`, `transcription.timeout_seconds`,
`transcription.transcript_prefix`, and `transcription.post_transcript`.
The shared `audio` section owns `max_bytes`, `max_duration_secs`,
`delete_temporary_raw`, and `allowed_cdn_hosts`.
A transcription is exactly once per request id: a replayed capture reuses the
first transcript and never downloads or calls Groq again.
A missing key, an unsupported or oversized attachment, a download error, or a
failed transcription is answered with one honest line in the same conversation
instead of silence, and the failed request is recorded durably.
`status` reports the switch, the recorded transcript counts, and the model and
language.

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
listener is registered, the connection mode and state, the last pass counts, and
the posted, open, and recorded-interaction card counts.
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

`tests/fm-discord-conversation-console-audio.test.sh` drives transcription
against a fake local Discord CDN and a fake local Groq API: a captain voice
message becomes the message text and is answered in its thread, the transcript is
shown there, a replay makes no second Groq call and posts no second transcript,
the temporary audio is deleted after success and after failure, the bot token and
the Groq key never reach durable state or the listener output, a corrupt and an
oversized audio each produce one honest reply instead of a crash, and a disabled
transcription leaves audio on the existing ignored path.
The dependency contract is owned by
[`verification/discord-console-audio-transcription.md`](verification/discord-console-audio-transcription.md).
