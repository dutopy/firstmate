# Discord workspace

Firstmate's private Discord operations workspace is an offline-supported integration for one captain-owned operations guild.
It is separate from the public Relay integration and separate from any future Hermes audience bots.
The repository support in this phase validates configuration, plans setup, plans outbound messages and artifacts, links requests to work, preserves pending final replies, and exercises intake through offline fixtures only.
It does not contact Discord or Groq, create live resources, decrypt secrets, install tools, arm a live source, or post live messages.

## Presentation contract

The supported workspace is one private operations guild.
The active profile categories are ProApplis, Folium, and ARFAL.
Each active profile has exactly two configured Discord forum channels for this phase.
One forum is the profile's exchanges forum.
One forum is the profile's artifacts forum.
Each forum post or thread is the Discord analogue of an operator tab.
Voice messages, uploaded audio, and transcripts stay in the relevant exchange post.
Every artifact is canonical in exactly one tagged artifact-forum post.
The related exchange receives only a concise card and a link to that artifact post or private artifact URL.
LBDB and Maratone Labs remain disabled inventory entries until a later captain approval activates them.
There is no live voice-channel capture in this phase.

## Bot identity boundary

One Firstmate operations bot handles text intake, artifact cards and index links, audio transcription replies, and status replies.
Do not create feature-specific bots, webhook personas, or separate bot identities for visual activities.
Make profile context visible through categories, forum tags, artifact cards, and profile metadata.
Separate Hermes audience bots may exist later when an activated security or audience boundary needs them.
Those Hermes bots are outside this integration and must never share Firstmate Discord workspace credentials or private Firstmate authority.

## Non-secret config

The default non-secret config path is `config/discord-workspace.json` under the effective `FM_HOME`.
Use `bin/fm-discord-workspace.sh sample-config` to print a copyable draft.
Use `bin/fm-discord-workspace.sh config-check --config <json>` to validate the local file.
The config schema is owned by `bin/fm_discord_workspace_lib.py` and surfaced through `bin/fm-discord-workspace.sh --help`.
The schema names one operations guild id, one bot application id, one bot user id, captain Discord user ids, disabled profiles, three active profiles, category ids, exchange forum ids, artifact forum ids, optional thread allowlists, exchange tags, artifact tags, artifact policy, audio policy, transcription references, and disabled live choices.
Exchange tag defaults are request, decision, work, status, blocked, and done.
Artifact tag defaults are report, board, document, image, audio, draft, final, and expired.
The script validates ids and duplicate channel assignments but never creates any category, channel, thread, or tag.
The config stores secret file paths and key names only.
It must never store Discord tokens, Groq keys, plaintext `.env` values, or decrypted secret material.

## Setup and health dry-runs

Run `bin/fm-discord-workspace.sh setup --dry-run --config <json>` to render the planned guild tree, forum ids, thread allowlists, tag vocabulary, and permission integers.
The dry-run prints temporary setup and steady-state permission integers without contacting Discord.
The dry-run also prints every live choice that remains unapproved or inactive.
`setup --apply` refuses in this phase.
Run `bin/fm-discord-workspace.sh health --local --config <json>` for local config and state checks without network access.
`health --secrets`, `health --discord`, and `health --transcription` report the planned checks and refuse before live secret or network use.
Live choices remain configurable but disabled for Discord `MESSAGE_CONTENT`, Omarchy versus VPS host, hosted Groq consent and limits, artifact access and expiry, temporary setup permissions, Community-mode requirement, live polling, and live posting.

## Inbound process-event adapter

`bin/fm-procevent-discord-workspace.sh` is the built-in process-event adapter for this integration.
Its canonical source id is `discord-workspace`.
`arm --dry-run` prints the registration command and does not register a live source.
A non-dry-run arm refuses in this phase even when config contains a future live-polling choice.
The source command reads only offline fixtures named by `FM_DISCORD_WORKSPACE_FIXTURE` or by `poll.fixture_file` in config.
Without a fixture it refuses before any network call.
The adapter accepts only messages from the configured operations guild, configured exchange forum posts or allowlisted exchange threads, configured captain user ids, and non-bot authors.
It ignores DMs, bots, unknown guilds, unknown channels, unknown authors, artifact-forum input, disabled profiles, and invalid message ids.
Accepted text, voice transcript, audio transcript, and audio rejection events are passed to `bin/fm-inbox.sh note` with `--source discord-workspace` and a validated `--external-id`.
The existing captain inbox remains the durable authority and wake owner.
The process-event adapter declares self-announcing so a successfully handled Discord event produces only the ordinary captain-inbox notification.

## Inbox replay idempotency

`bin/fm-inbox.sh note` accepts `--source <name> --external-id <id> [--metadata-file <json>]` for trusted external intake.
The external source and id are non-secret identifiers.
The inbox writes a private map under `state/inbox/external/`.
A replay with the same source and external id returns the original note id and appends no second notification.
The metadata file must be bounded JSON and is copied into private inbox state.
The note body remains the durable human-readable captain note.

## Outbound replies and final follow-ups

Workers must not post to Discord directly.
Use `bin/fm-discord-workspace.sh reply`, `status`, `artifact`, `publish-artifact`, `link-task`, and `followup` to plan private outbound work.
Every outbound plan uses `allowed_mentions: { "parse": [] }`.
A live post receipt is represented by a nonce-keyed private record under `state/discord-workspace/receipts/`.
A retry with the same nonce and identical planned payload returns the existing receipt instead of authorizing a duplicate post.
`link-task` records a Discord-originated request under `state/discord-workspace/requests/` and links the task under `state/discord-workspace/task-links/`.
When final replies are required, it also creates a pending final-reply record under `state/discord-workspace/pending-followups/`.
`followup --final` keeps the pending record unresolved in dry-run mode and marks it delivered only when a validated live receipt id is recorded.
`bin/fm-teardown.sh` refuses to clean up a task while its private Discord workspace final reply is still pending unless explicit discard authority is carried through `--force`.

## Artifact protection

Direct Discord attachments are for small, deliberately selected files only.
The default direct attachment cap is 8 MiB and cannot exceed Discord's documented 10 MiB default in this phase.
Allowed direct types are UTF-8 Markdown or text, PNG, JPEG, GIF, WebP, and generated PDF files.
The artifact helper blocks secret-looking names, archives, databases, dumps, raw logs, credential files, unknown MIME types, MIME mismatches, files under `projects/`, directories, symlinks, and files outside configured allowed roots.
Client-confidential artifacts are blocked unless config opts in and the command carries explicit captain approval for that file.
The canonical artifact plan posts the binary or private URL only in the artifacts forum.
The exchange plan receives only a summary card and link.
For larger or interactive artifacts, use `publish-artifact` with a private HTTPS URL, an access mode, and an expiry.
The helper records source digest, policy, destination, and revocation metadata but does not operate the private publication host in this phase.

## Audio and transcription

Phase 1 handles Discord voice messages and uploaded audio files only.
Live voice-channel capture is excluded.
Audio intake validates the Discord CDN host, MIME or extension, size, and duration before transcription planning.
Discord voice messages must carry the voice-message flag and exactly one audio attachment.
The conversion plan names `ffmpeg`, records that temporary raw audio should be deleted by default, and does not invoke live conversion in this phase.
Tests may use `transcription.provider` set to `fake` with fixture transcripts.
Hosted Groq support is only a design and configuration boundary in this phase.
A later live task must use a dedicated Firstmate Discord/transcription secret file decrypted with sops and age into process memory.
No plaintext `.env`, Hermes recipient, client recipient, shared client key, Groq network call, or committed secret is part of this phase.

## Rollback and retirement

`bin/fm-discord-workspace.sh retire --config <json>` is a dry-run retirement check.
It refuses while pending final replies remain.
It preserves `state/discord-workspace/` so receipts, request links, artifact records, and pending replies remain auditable.
If a live process-event source is activated later, retire that source through `bin/fm-procevent.sh retire discord-workspace` or a stricter owner-matching command printed by the activation task.
Do not delete live Discord channels, categories, posts, bot permissions, or secrets without a separate explicit captain-approved live operation.
Rotate the Discord bot token or dedicated transcription key if compromise is suspected.
