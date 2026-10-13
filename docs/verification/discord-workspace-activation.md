# Discord workspace activation - verification

This record holds the empirical claims behind activating and verifying the
captain's private Discord workspace: the applied structure, the routing proof,
the artifact-link proof, the transcription proof, the two live defects the
activation surfaced, and the exact undo of every live-facing change.
The structure itself is [`discord-workspace-structure.md`](discord-workspace-structure.md);
the contract is [`../discord-workspace.md`](../discord-workspace.md); this page is
evidence, not a second contract.

## Environment and commands

Measured on 2026-09-20 on the firstmate host from the task's own worktree:
Python 3.12, `sops` 3.13.3, Discord API v10, bot user `1545668675972112484`.

The published changes are covered by loopback fakes and reach no network:

```sh
bin/fm-test-run.sh tests/fm-discord-session-mirror.test.sh tests/fm-discord-conversation-console-audio.test.sh
```

The live runs below are the real Discord API through the real
`bin/fm-discord-session-mirror.sh`, with the token decrypted into process memory
by `bin/fm_discord_live.py` and never written to disk.

## Applied structure

Three internal workspaces are active and equal-rank - System / Firstmate,
ProApplis and Folium - and share one template: a `Control` category carrying the
lane's one `#exchanges` forum and its `#firstmate` control channel, `Operations`,
and one category per active project carrying `#sessions` and `#artifacts` forums.
Every task belongs to exactly one project category.

The full live table, with every guild, category and forum id, is
[`discord-workspace-structure.md`](discord-workspace-structure.md), read from
`GET /guilds/{id}/channels` on the same date and published as the tagged
`rapport` artifact of this task.

`docs/discord-workspace.md`'s "Presentation contract" describes the single
`System / Firstmate`, `ProApplis`, `Folium` category triple of the captain's
archived Firstmate workspace; the live lanes above are what the three
equivalent projects, `config/discord-session-mirror.json` and
`data/discord-ossature-plan.md` actually use.

## Routing proof

`bin/fm-discord-session-mirror.sh sync --task firstmate-discord-workspace` ran
live and created one thread for this task in the project's own category:

| item | value |
| --- | --- |
| thread | `1551154556107358221` |
| name | `Firstmate & Supervision - firstmate-discord-workspace - atelier-17` |
| forum | `1550358900912689162` (`#sessions`) |
| category | `1550358810479165480` (`Firstmate & Supervision`, System / Firstmate lane) |
| tags | `session`, `worktree`, `actif` |
| identity | webhook `1550452099039633499`, username `Firstmate & Supervision - atelier-17` |

Read back from Discord rather than from the durable record, the card carries the
project context and the reconciled state, so the current work is visible without
a status request:

```text
**Projet :** Firstmate & Supervision
**Session :** firstmate-discord-workspace
**Worktree :** atelier-17
**Branche :** fm/firstmate-discord-workspace
**Etat :** working
```

Choosing the category is what selects the context: a task is matched to a
project by the `project=` path in its `state/<id>.meta`, longest matching path
first, and that project's `sessions_forum_id` is the only forum its thread may
land in. `report` shows the same mapping for every live task, and the live
config maps `atelier` and `dutopy-config` and `hermes-agent` into the System /
Firstmate lane, `proapplis` into ProApplis, and `proapplis-folium` into Folium.

## Artifact-link proof

`bin/fm-discord-session-mirror.sh artifact --task firstmate-discord-workspace
--kind rapport --title "Discord workspace - applied live structure"
--body-file docs/verification/discord-workspace-structure.md` ran live:

| item | value |
| --- | --- |
| artifact thread | `1551157711578865677` |
| name | `Firstmate & Supervision - firstmate-discord-workspace - rapport` |
| forum | `1550358995255042098` (`#artifacts`) |
| tag | `1550444494925860869` (`rapport`) |
| identity | webhook `1550452102256398348`, username `Firstmate & Supervision - firstmate-workspace` |
| link message | `1551157713751248957` in the session thread |

The canonical artifact therefore exists exactly once, in its project's artifacts
forum, under one tag. The related exchange post - this task's session thread -
received only a link line, not a copy:

```text
Artefact (rapport) : Discord workspace - applied live structure
https://discord.com/channels/1525898345338372136/1551157711578865677
```

A replay of the identical body is a no-op: the same command prints "artifact
already recorded for this content" and posts nothing twice.

## Transcription proof

Voice messages are proven live: the console holds 28 successful transcripts of
real captain voice messages recorded between 2026-09-19 and 2026-09-20 under
`state/discord-workspace/conversation-console/transcripts/`, each with
`audio_kind=voice`, `model=whisper-large-v3`, `language=fr` and a real French
transcript, for example:

```json
{"audio_kind": "voice", "duration_secs": 10.1, "language": "fr", "model": "whisper-large-v3",
 "recorded_at": "2026-09-20T07:24:06Z", "status": "ok", "text": "On va pas y arriver, est-ce que tu peux me mettre ces commandes entre simple backticks s'il te pla\u00eet ?"}
```

Uploaded audio was implemented but neither tested nor exercised: `audio_kind`
had never been anything but `voice`, and no test covered a caption-less message
carrying an audio file instead of a Discord voice message. That half is now
covered in `tests/fm-discord-conversation-console-audio.test.sh`, which proves on
the loopback fakes that such a message is downloaded, transcribed once, shown as
`Transcription : ...`, captured as a durable note, and recorded with
`audio_kind=audio-upload`, and that a caption-less message carrying two audio
files fails honestly instead of crashing. Removing the non-voice detection from
`audio_attachment_present` makes exactly that case fail
(`listened: scanned=2 captured=0 ignored=2`), so the case has teeth.

The live upload half is **not** verified: it needs the captain to send an audio
file to `#firstmate`.

## Two live defects found and fixed

Both were reproduced live on the artifact path and are now refused or cleared
before the call, with the loopback fake encoding Discord's own rule.

1. **A webhook username containing `discord` is refused.** The artifact identity
   is `<project label> - <task id>`, and this task's id is
   `firstmate-discord-workspace`, so the live post returned
   `HTTP 400 {"code": 50035, "errors": {"username": ... "USERNAME_INVALID_CONTAINS",
   "message": "Username cannot contain \"discord\""}}`. `session_identity` now
   drops the forbidden words and closes the seam they leave, so the live post
   uses `Firstmate & Supervision - firstmate-workspace`.
2. **The artifact body bound did not account for the title.** The post composes
   `**<title>**\n\n<body>`, so a body at its own 2000-character limit exceeded
   Discord's 2000-character content limit:
   `HTTP 400 {"code": 50035, "errors": {"content": ... "Must be 2000 or fewer in
   length."}}`. The composed content is now bounded as one string and refused
   locally with the real budget; the first live retry printed
   `the artifact title and --body-file together would post 2044 characters of
   content; Discord accepts at most 2000`, which is what forced this record's
   body down to its published size.

The session card passes through the same content bound, so a long task id can no
longer produce the same opaque failure.

## Undo

The activation created exactly two live Discord resources and changed nothing
else - no category, forum, tag, webhook, permission, channel or secret:

```sh
# 1. the task's session thread in the Firstmate & Supervision #sessions forum
DELETE /channels/1551154556107358221
# 2. the artifact thread in the Firstmate & Supervision #artifacts forum
DELETE /channels/1551157711578865677
```

Deleting a thread removes its card and, for the session thread, the link line it
holds. The local undo is the ordinary one for this branch: the mirror's durable
records are
`state/discord-workspace/session-mirror/sessions/firstmate-discord-workspace.json`
and `state/discord-workspace/session-mirror/artifacts/<content-digest>.json`
(`a0e89ecf4435cdc68343909913446f85cb4eea1b36f0793f6901c91f8c9df407` for the
published body), and removing them lets a later pass adopt or recreate the
threads rather than duplicate them.

## Not verified

- **Uploaded-audio transcription on a real message.** Proven on the loopback
  fakes only; it needs the captain to send an audio file to `#firstmate`.
- **The captain's own workspace as three equal-rank categories.** The live
  applies are three equal-rank *lane workspaces*; whether the archived Firstmate
  workspace's literal single-guild `System / Firstmate`, `ProApplis`, `Folium`
  category triple is meant to be recreated is a captain decision, and
  `data/discord-ossature-plan.md` records the per-project structure as its
  replacement.
- **No live category, forum or tag was created by this task.** Every live
  resource the proofs touch already existed; the task's contribution there is the
  verification and the two path defects, not new structure.
- **The workspace capability's own live layer is pointed at the archived guild.**
  `config/discord-workspace.json` still names guild `1544908007891271753`, so
  `bin/fm-discord-live.sh health` answers
  `Discord API GET /guilds/1544908007891271753 failed with HTTP 404: {"message": "Unknown Guild", "code": 10004}`
  and `setup-apply`, `live-reply`, `live-source` and `live-roundtrip` cannot run.
  Nothing depends on them: the active path is the conversation console plus the
  session mirror, and no `discord-workspace` process-event source is registered.
  Repointing or retiring that config is a captain decision and was not taken
  here.
