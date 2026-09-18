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
- `bounds`: the per-pass message, thread, and retained ignored-record caps.

The config stores only secret file paths and key names, never a token.

## Inbound

One bounded pass reads each configured `#firstmate` channel and the active and
archived public threads under it, newest messages last, after a durable
monotonic cursor per channel or thread.
An accepted message is a non-empty text message whose author is one of
`captain_user_ids` and is not the bot.
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
`--dry-run` prints the plan with no network call.
The bot token is decrypted into process memory only and is redacted from every
failure path; operational supervision text is refused before any publish.

## Status

```sh
bin/fm-discord-conversation-console.sh status --config <json>
```

`status` reads local records only.
It never contacts Discord and changes no durable state, so it is safe to run in a
loop.
It reports a health verdict (`healthy`, `stopped`, `polling-disabled`,
`secret-missing`, `config-invalid`, or `state-malformed`), each configured
channel and its last cursor, the live switches, whether the listener is
registered, and the last pass counts.

## Run model

The continuous listener is the repository's process-event source pattern, not a
permanently running agent:

```sh
bin/fm-discord-conversation-console.sh start --config <json> [--dry-run]
bin/fm-discord-conversation-console.sh stop  --config <json>
```

`start` registers `bin/fm-procevent-discord-conversation-console.sh source` under
the source id `discord-conversation-console` and refuses while `live.polling` is
disabled.
`stop` retires it.
The watcher reconciles and supervises the registered source, so each pass is
bounded and no agent is left running.
An operator can also run one pass by hand with `listen --config <json>`.

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
The listener polls the REST API, so no privileged Message Content intent is
required, and it needs no Manage Channels, Manage Threads, or Create Threads
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
against a fake local Discord server: a captain message is captured exactly once
across a restart, a non-captain message is ignored and recorded, an answer lands
in the originating thread with two threads kept separate, a channel conversation
is answered in its channel, `status` changes no durable state, and `start` and
`stop` register and retire the bounded listener.
