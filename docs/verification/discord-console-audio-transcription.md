# Discord console audio transcription - verification

This record holds the empirical claims behind the #firstmate console audio
transcription: the dependency contract, the transcription and transcript-display
behavior, the exactly-once and cleanup guarantees, the secret boundary, and the
bounded failure behavior.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md);
this page is evidence, not a second contract.

## Dependency contract

The only transcription provider is Groq, with the OpenAI-compatible endpoint
`POST https://api.groq.com/openai/v1/audio/transcriptions` and multipart form
fields `file`, `model`, `language`, `prompt`, `response_format=json`, and
`temperature=0`.
The model is fixed at `whisper-large-v3`; `bin/fm_groq_whisper.py` refuses any
other model, so the code default `whisper-large-v3-turbo` can never be used by
accident.
The language defaults to `fr` and the vocabulary prompt is passed verbatim:

```
Hermes, Firstmate, ProApplis, Folium, ARFAL, herdr, Mnemosyne, dutopy, Astra, Luna, Jeff, kanban, worktree
```

The API key reference is `GROQ_API_KEY`: the process environment wins, then
`GROQ_API_KEY=` in the home's gitignored `.env`, matching the Relay and typed
dispatch key pattern, so the native secret integration materializes it without a
second bridge.
The CDN, size, duration, and MIME rules are the same ones the Discord workspace
already owns in `bin/fm_discord_workspace_lib.py`; the console config exposes the
same non-secret `audio` section.
The size bound is 25 MB and the duration bound is 600 s by default.

## Transcription and display

`tests/fm-discord-conversation-console-audio.test.sh` drives the public interface
against one fake local HTTP server standing in for both the Discord REST API and
the Groq API, so no real token or key is read and no request leaves loopback.
It proves, on that path:

- a captain voice message with no caption is detected, downloaded inside the CDN
  allowlist, transcribed, and fed into the same capture path as text: the note
  body carries the transcript, a reply command naming the originating thread, and
  the transcription provenance line;
- the transcript is shown in the thread and the channel as
  `Transcription : <text>` (the configured prefix), so the captain sees what was
  heard before the answer;
- because the fast path is enabled in that home, the same deterministic
  acknowledgement is posted for a transcribed message as for a typed one;
- the answer to a transcribed thread message returns to that thread and nowhere
  else, because the durable request id keeps the originating channel.

The request the console sends is the real Groq contract; only the endpoint is
replaced by the loopback fake.
A live Discord-plus-Groq round trip was **not** performed from this worktree: the
console's live switches are on in the firstmate home, but the Groq key is not
present in that home's environment or `.env` at verification time, and a real
captain voice message in Discord is the captain's own action.
Until one real voice message is sent, the following remain to confirm live:
`provider=groq`, `model=whisper-large-v3`, `language=fr`, a non-empty transcript,
and the exact spelling of the vocabulary terms.

## Exactly once and cleanup

The suite also proves:

- a replay with its cursors removed makes no second Groq request and posts no
  second transcript, because the transcript is one durable record keyed by the
  request id;
- the temporary audio lives under the console state, is read once, and is absent
  after both a successful and a failed transcription;
- no audio bytes, bot token, or Groq key appears in any file under the home's
  `state`, and neither secret appears in the listener's captured output.

## Bounded failure

A failing Groq response (HTTP 500) and an attachment whose real bytes exceed the
configured cap each produce one honest French line in the same conversation and a
durable failed-transcript record, with the listener exiting cleanly rather than
crashing.
An attachment whose declared size exceeds the cap is refused before any download.
With `transcription.enabled` off, an audio message is ignored with the reason
`audio-transcription-disabled`, exactly the pre-existing behavior.

## Commands

```sh
bash tests/fm-discord-conversation-console-audio.test.sh
bash tests/fm-discord-conversation-console.test.sh
bash tests/fm-discord-console-fast-path.test.sh
```

The first two were green on 2026-09-18 with the fakes above; the fast-path suite
remained green, proving the added audio path did not change the text path.
