# Discord session mirror

The session mirror is the Firstmate half of the per-project Discord structure.
It puts every live Firstmate session where the captain expects to find it - in
the sessions forum of the project that session belongs to - keeps that thread's
tags on the reconciled current state, files durable deliverables in the same
project's artifacts forum, and turns a thread the captain creates into a session
bound to that thread.

It is separate from, and reuses, the private Discord operations workspace
(`docs/discord-workspace.md`). One owner per concern:

- `bin/fm-discord-session-mirror.sh` is the only entrypoint for this capability.
- `bin/fm_discord_session_mirror_lib.py` owns the config schema, planning, state
  records, idempotence, and the thread-as-request intake.
- `bin/fm_discord_workspace_lib.py` owns the shared config/state safety
  primitives, atomic JSON, the state lock, and receipts.
- `bin/fm_discord_live.py` owns the Discord HTTP client, token decryption, retry
  bounds, and token redaction.
- `bin/fm-crew-state.sh` owns the reconciled current state of a task.

This document is the operating contract: which channel, which tags, which
trigger. A future session can follow it without reading the task brief that
produced it.

## Channels

The server structure is built and owned outside this repository: one category per
project, each holding a sessions forum, usually an artifacts forum, a journal and
a board channel, plus the two fixed poles `00 · Pilotage` and `90 · Operations`.
The mirror never creates, renames, moves, or deletes a category, channel, forum,
or tag. It posts only into forums that its config already names.

`/home/dutopy/atelier/data/discord-ossature-plan.md` is the canonical record of
the structure and `/home/dutopy/atelier/data/discord-cartographie.md` the
inventory of the live guilds.

## Configuration

The default config path is `config/discord-session-mirror.json` under the
effective `FM_HOME`; `--config` overrides it. It is non-secret and gitignored.
Print a copyable draft with:

```sh
bin/fm-discord-session-mirror.sh sample-config
bin/fm-discord-session-mirror.sh config-check --config <json>
```

It owns, and the code never hard-codes:

- `projects`: one entry per Firstmate project, mapping a project key to a
  `label`, the `guild_id`, the project's `sessions_forum_id`, an optional
  `artifact_forum_id` with an optional `artifact_tags` map, an optional
  `tag_ids` map, and the absolute `paths` of that project's clones. A task is
  matched to a project by the `project=` path in its `state/<id>.meta`, longest
  matching path first.
- `session_tag` and `worktree_tag`: the two always-applied forum tags.
- `state_tags`: the reconciled-state-to-tag table. The default maps `working` to
  `actif`, `parked` and `paused` to `en-attente`, `blocked` and `failed` to
  `bloque`, `done` to `termine`, and `unknown` to `en-attente`. Every reconciled
  state must be mapped.
- `tag_ids`: the forum tag vocabulary as a name-to-id map. A member bot reads
  that vocabulary live; a webhook cannot read a channel at all, so the webhook
  transport needs it here.
- `captain_user_ids`: the Discord accounts allowed to start a session request.
- `live.posting`: the only switch that permits a Discord write. It is off by
  default, and every write command is a printed plan while it is off.
- `allow_untagged`: with it off, an unconfigured `tag_ids` entry blocks the post
  and says so; with it on, the session thread is published without tags and the
  exact missing names are printed on every creation.
- `webhook_file`: the captain-owned webhook inventory, `config/discord-webhooks.json`
  by default.
- `bounds.max_tasks_per_pass` and `bounds.max_thread_listing`: the per-pass and
  per-forum API bounds.

## Posting identity

The primary transport is a Discord webhook from the configured webhook file,
matched to the project forum by `kind` (`sessions`, `artifacts`, `emails`) and
`channel_id`. A webhook needs no bot membership, which is what lets the mirror
publish into a guild the Firstmate bot has not been invited to. When no webhook
matches the target forum, the mirror falls back to the member-bot transport.

Each session posts under a readable per-session identity,
`<project label> - <worktree name>` (for example
`Firstmate & Supervision - atelier-24`), so the captain sees who is speaking,
while the exact worktree name stays in the thread title and in the card.

A webhook is bounded by design: it can create a forum post, edit the message it
created, and post a link message into a thread of its own forum. It cannot read
a channel, so thread recognition still needs the member-bot transport; and it
cannot change an existing thread's tags, so with the webhook transport the state
tag is applied when the thread is created and later state changes are carried by
the live card. `sync` says exactly that when it happens instead of silently
pretending the tags moved.

## Session card and triggers

The bot token follows the existing Firstmate Discord convention: only the
reference is stored here (`secret_file`, a normalized
`config/<name>.sops.yaml` path, plus `discord_bot_token_key`). The value is
decrypted into process memory by the shared owner in `bin/fm_discord_live.py`,
is never printed, logged, or written to disk, and is redacted from every failure
path. A token-like or operational string is refused before any publish. Webhook
execute urls and their tokens are read from the webhook file at runtime, kept in
memory, and never printed, logged, or written into mirror state.

## One session thread per live task

`sync` runs one bounded pass over this home's live tasks - every
`state/<id>.meta` with `kind=ship` or `kind=scout`, in task-id order - and for
each one whose project is mapped:

1. reads the reconciled state from `bin/fm-crew-state.sh` (never the append-only
   `state/<id>.status` log);
2. ensures exactly one forum thread in that project's sessions forum, named
   `<project label> - <task id> - <worktree name>`;
3. applies exactly three tags: `session`, `worktree`, and the single state tag
   for the reconciled state;
4. writes or edits, in place, one session card carrying the project, the task
   id, the worktree name, the branch, and the state.

The worktree name is the pooled treehouse identity
(`<project>-<slot>`, for example `atelier-24`), or the worktree directory name
outside a treehouse pool. It is the primary carrier of worktree identity: it is
in the thread title and repeated as a labelled card field. The thread is never
renamed, and the card is a message that is edited in place rather than
reposted, so a later extension can attach embeds, buttons, or a webhook identity
to the same thread without a second thread. The card never carries a filesystem
path, a transcript, captain wording, or client content.

The thread is reconciled, never appended: a state change patches the thread's
tags and edits the same card. A task whose project is unmapped, or whose forum
lacks a required tag, is reported with its exact reason and skipped rather than
guessed.

## Idempotence and bounds

Posting is exact-once across restarts. Each task's thread id, card message id,
card digest, and applied tag ids live in a durable per-task record under
`state/discord-workspace/session-mirror/sessions/`. A member-bot pass that finds
no record still looks for an existing thread by the deterministic title in the
forum's active threads and, only then, in that forum's archived public threads -
so a crash between Discord creating the thread and the record landing adopts the
existing thread instead of creating a second one, and a record that outlives
`state/<id>.meta` is reported as orphaned rather than deleted. The webhook
transport cannot read those listings, so it records a create intent before it
posts and refuses to create again until that intent is resolved; the reported
remedy is a `bind --task <id> --thread <id>` after checking the forum.

A pass makes no poll loop and no sleep: it is one bounded sequence of API calls,
deferred past `bounds.max_tasks_per_pass` with the deferred task ids printed.
Concurrent passes are serialized by the shared Discord state lock.

`report` prints the current mirror state - per task: project, worktree,
reconciled state, state tag, recorded thread and title, plus the request and
artifact record counts. It reads local records only and never contacts Discord,
so it is safe to run at any time.

## Artifacts

When a task produces a durable deliverable, file it in the project's artifacts
forum:

```sh
bin/fm-discord-session-mirror.sh artifact --task <id> --kind report|patch|pr \
  --title "<title>" --body-file <bounded file>
```

The artifact becomes one thread in the configured artifacts forum carrying the
config's tag for that kind, and the session thread receives a single link line
instead of a copy of the content. A replay of identical content is a no-op, and
an artifact is refused when the project has no configured artifact forum, when
the forum lacks the configured kind tag, or when the body looks operational or
secret.

## A thread as a session request

A thread the captain creates in a project sessions forum is a session request.
Recognition is explicit and deterministic:

```sh
bin/fm-discord-session-mirror.sh request --thread <thread id> [--text-file <ask>]
```

The thread is recognized only when it is a forum thread whose parent is a
configured project sessions forum and whose starter message was written by a
configured captain account and not by a bot. Recognition reads the thread, so it
needs the member-bot transport; with only webhooks configured, `request` says so
and `bind` is the path. On acceptance the mirror writes a
durable request record, wakes firstmate through the existing captain-inbox seam
(`bin/fm-inbox.sh note --source discord-session-mirror --external-id <thread>`),
and the session is bound to that thread with:

```sh
bin/fm-discord-session-mirror.sh bind --thread <thread id> --task <task id>
```

An explicit plain-language request is the same command with `--thread` naming
the target thread and `--text-file` carrying the captain's words, and a thread
whose id is known (from the captain, or from the project orchestrator) is bound
with `bind` even when only the webhook transport is configured.

Anything else is refused in the same thread, with the exact reason and the list
of recognized forums, and the refusal is recorded durably - an unrecognized or
ambiguous request is never silently dropped. A thread already refused cannot be
bound, and a task already mirrored in another thread is refused rather than
moved.

## Safety

Only the sanitized session identity, state, project, worktree, branch, and links
are ever posted. Worker transcripts, captain wording, operational supervision
text (`FIRSTMATE_OP:`, watcher wakes, rendered notes), credentials, and client
content are refused before any publish. The client-facing guild is out of scope
for this capability, and the mirror performs no destructive Discord operation:
there is no delete, archive, rename, or tag-creation path.

## Operating cadence

`sync` is a bounded pass, not a daemon. Run it when a session starts, ends, or
changes state, and at fleet heartbeats. `report` is the read-only check. Both
are safe to re-run at any time.
