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

The same suite reads the multipart bodies the fake receives, so the request
itself is evidence rather than an assumption: every call carries
`model=whisper-large-v3`, `language=fr`, the vocabulary prompt verbatim, and
`response_format=json`; the first reading carries `temperature=0` and the
confidence reading of the same audio carries `temperature=0.6`.

## Transcription confidence

One reported defect drove this: the captain's French question
"Tu es à l'arrêt là ?" was transcribed as "Salut à tous !" - phonetically
adjacent, semantically opposite - and the answer addressed the wrong sentence
with nothing in the delivered text to show the transcript was untrustworthy.

The mitigation is one extra bounded reading of the same audio at a different
decode temperature, compared against the first. On the scripted cases above the
suite proves:

- two readings of the same sentence that differ only by case, accents,
  punctuation, spacing, or one extra word are delivered unmarked, recorded as
  `agree`, and still answered by the fast path (so the check costs nothing but
  the extra call when it agrees);
- the reported pair - "confidence-task, tu es a l'arret la ?" against
  "Salut a tous !" - is recorded as `disagree` at a word-level agreement of 0.18
  against the 0.75 threshold, and the delivered transcript is marked
  `Transcription incertaine - à confirmer : ` in the thread; the comparison rule
  itself is asserted at the module boundary on the mishearing pair, on the same
  sentence with and without a function word, on a reading that heard far fewer
  words, and on an empty reading;
- a second reading that fails (HTTP 500) is recorded as `unavailable` with the
  failure reason redacted, and the first reading is still delivered under the
  same marker;
- a 45 s attachment is read once and recorded as `skipped`, so the extra cost
  stays on the short phrases that mishear;
- an uncertain transcript takes the full turn: it appends a durable note with
  `transcription-uncertain`, the second reading as `transcription-second-reading`,
  and the instruction to confirm the spoken words, posts no record-backed
  acknowledgement, and no fast answer, while the two settled readings in the same
  pass still answer from records;
- the scripted 500 body deliberately contains the Groq key, and the key appears
  in no note, no posted message, no transcript record, and no file under the
  home's `state`.

A live French recording of the elided phrase was **not** possible from this
worktree: no French speech source exists here - `espeak-ng`, `pico2wave`,
`piper`, `gtts`, and `edge-tts` are all absent, `ffmpeg`'s `flite` filter speaks
only English, there is no French audio asset in the repository, and the console
deletes the captain's raw audio by design, so "Tu es à l'arrêt là ?" itself is no
longer on disk.
The genuine recording is therefore the captain's own voice message.
Speech synthesis through the same Groq account was attempted and is not
available: `/openai/v1/audio/speech` and `/openai/v1/models` both answer HTTP 403
(`error code: 1010`) for this key, while `/audio/transcriptions` works.

Two live runs against the real endpoint were possible with locally synthesized
speech (falling back to English voices), each a real first reading plus a real
confidence reading, 0.6-0.7 s for both calls:

- an English phrase pinned to `fr`, "Are you stopped right now?", came back as
  `Vous êtes arrêté maintenant ?` against second readings of `Vous êtes arrêté ?`
  and then the same sentence again - word agreement 0.75 and 1.0 across two
  runs, delivered unmarked both times, which is the ordinary decode variation
  the threshold is meant to leave alone;
- the same French sentence read by an English voice came back as `tout cela`
  against second readings of `2SEL-REDLA` and `toussulritlov` - word agreement
  0.0 both times, marked uncertain with the second reading kept, which is what a
  genuine mishearing on short audio looks like.

That first live pair is also why the comparison is word-level rather than
character-level: at 0.744 on a character metric, a second reading that merely
dropped one word would have been marked as doubt, and the captain would have been
asked to confirm an ordinary variation.

## Live endpoint

The request the console sends is the real Groq contract; only the endpoint is
replaced by the loopback fake.
A full live Discord-plus-Groq round trip was **not** performed from this
worktree, because a real captain voice message in Discord is the captain's own
action; the live Groq half was exercised directly, and `GROQ_API_KEY` resolves
from the firstmate home's `.env` and transcribes successfully on that route.
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

`tests/fm-discord-conversation-console-audio.test.sh` was green on 2026-09-19
with the confidence cases above added, and
`tests/fm-discord-conversation-console.test.sh` and the fast-path suite were green
with the same change in place, proving the added confidence path did not change
the text path.
The first two were green on 2026-09-18 with the fakes above.
