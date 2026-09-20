# Discord console prepared request - verification

This record holds the empirical claims behind the #firstmate console prepared
request: what one real packet looks like next to the captain's raw message, how
often a real message reaches a packet, the measured cost preparation adds to the
capture, the fallback path, and the before and after numbers for both halves the
captain asked about.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md)
("Prepared request"); this page is evidence, not a second contract.

## Environment and commands

Measured on 2026-09-20 on the firstmate host, Python 3.12.
The classifier measurements use the real System One endpoint; every pinned
suite uses the loopback fakes and reaches no network:

```sh
bash tests/fm-jev-console-prepare.test.sh
bash tests/fm-discord-console-prepare.test.sh
bash tests/fm-discord-console-latency.test.sh
bash tests/fm-discord-console-fast-path.test.sh
```

The real packet and the accept-rate numbers below come from the real console
preparation path over a read-only copy of the live records, driven from the real
captured event metadata of real captain messages:

```sh
FM_HOME=<scratch-home> TYPESAFE_API_KEY=<set> \
  FM_JV_PREPARE_CORE=<shared core> \
  python3 <measurement driver> <real note> <real event metadata>
```

## The packet schema

One packet per message, recorded under `prepare/` in the console state and
rendered into the durable intake note:

```json
{
  "schema": "fm-discord-conversation-console.prepared-request.v1",
  "request_id": "discord:<guild>:<channel>:<message>",
  "intent": "state_question | new_work | decision_answer | chat",
  "intent_confidence": 1.0,
  "project": null,
  "entity": null,
  "ask": "the captain's own words, whitespace-normalised onto one line",
  "identifiers": {"task": "", "pr": [], "date": [], "received": "2026-09-19", "channel": "<id>", "thread": ""},
  "facts": ["three to five lines read from the records"],
  "raw_message": "the captain's exact message",
  "raw_message_chars": 146,
  "raw_message_sha256": "<sha256 of the raw message>",
  "prepared_at": "2026-09-20T05:08:24Z"
}
```

## A real example

The captain's message is the real captured text of Discord message
`1551020028726485212` (2026-09-19, channel `1550470253551685734`):

```
Bon alors qu'est-ce qui tourne en ce moment ? Sur quoi on travaille ? Qu'est-ce qu'il reste à faire ? Je pense qu'il y a encore pas mal de choses.
```

The packet the real preparation produced for it, at the default confidence floor
of 0.9, in 716.2 ms:

```json
{
  "ask": "Bon alors qu'est-ce qui tourne en ce moment ? Sur quoi on travaille ? Qu'est-ce qu'il reste à faire ? Je pense qu'il y a encore pas mal de choses.",
  "entity": null,
  "facts": [
    "in flight: 19 (discord-console-jev-request-preparation, oracle-vps-purpose-review, quota-pi-auth-visibility-r2, discord-console-audio-transcription, discord-console-latency-trace, discord-console-fast-path) (+13 more)",
    "backlog: 40 open, 14 done",
    "projects registered: 6"
  ],
  "identifiers": {
    "channel": "1550470253551685734",
    "date": [],
    "pr": [],
    "received": "2026-09-19",
    "task": "",
    "thread": ""
  },
  "intent": "state_question",
  "intent_confidence": 1.0,
  "prepared_at": "2026-09-20T05:08:24Z",
  "project": null,
  "raw_message": "Bon alors qu'est-ce qui tourne en ce moment ? Sur quoi on travaille ? Qu'est-ce qu'il reste à faire ? Je pense qu'il y a encore pas mal de choses.",
  "raw_message_chars": 146,
  "raw_message_sha256": "886ef98a516bb466083f71401e841584c258d8e9c881ed9018898babd880d25e",
  "request_id": "discord:1525898345338372136:1550470253551685734:1551020028726485212",
  "schema": "fm-discord-conversation-console.prepared-request.v1"
}
```

The durable note the real capture path wrote for it carries both, packet first
and the captain's words after it:

```
PREPARED REQUEST (advisory, derived from the raw message below)
intent: state_question (confidence 1.0)
project: none | entity: none
ask: Bon alors qu'est-ce qui tourne en ce moment ? Sur quoi on travaille ? Qu'est-ce qu'il reste à faire ? Je pense qu'il y a encore pas mal de choses.
identifiers: received=2026-09-19 channel=1550470253551685734
facts:
- in flight: 19 (discord-console-jev-request-preparation, oracle-vps-purpose-review, quota-pi-auth-visibility-r2, discord-console-audio-transcription, discord-console-latency-trace, discord-console-fast-path) (+13 more)
- backlog: 40 open, 14 done
- projects registered: 6

RAW MESSAGE (authoritative)
Bon alors qu'est-ce qui tourne en ce moment ? Sur quoi on travaille ? Qu'est-ce qu'il reste à faire ? Je pense qu'il y a encore pas mal de choses.
```

The real message that asked for this feature - the captain's 2026-09-20 question
about having the request dissected before firstmate reads it - is the clearest
real fallback: the model classified its intent as `state_question` at confidence
0.81, below the 0.9 floor, so the packet was refused and the note kept the raw
message alone:

```
status=fallback
reason=intent state_question at confidence 0.81 is below the 0.9 floor; task discord-console-jev-request-preparation at confidence 0.59 is below the 0.9 floor
```

## How often a real message reaches a packet

Fourteen real captured captain messages from 2026-09-19 and 2026-09-20, run
through the real preparation path and the real records at four confidence
floors.
The floor is `FM_JV_PREPARE_THRESHOLD`; 0.9 is the default and matches the route
classifier's own floor.

| floor | packets produced | fell back |
| --- | --- | --- |
| 0.9 (default) | 2 of 14 | 12 |
| 0.8 | 5 of 14 | 9 |
| 0.6 | 5 of 14 | 9 |
| 0.4 | 9 of 14 | 5 |

At the default floor an unambiguous message is prepared - a plain status
question scored 1.0, an explicit request for a fresh pass scored 0.96 - and the
mixed conversational messages that make up most of the captain's prose fall
back to the raw message.
That is the fail-closed contract working as designed, and it is also the
honest limit of this feature at its default setting: preparation helps most on
the messages that are already typed, and never guesses on the rest.
The preparation cost over the same fourteen messages was 767 ms median and
870 ms maximum wall clock, well inside the console's 4 s default bound.

## Before and after: the captain's message to firstmate activation

Method: the console's own latency journal reads the durable markers per request.
Stage 1 is Discord creation to console ingest, stage 2 is ingest to capture,
stage 3 is capture to the session's wake marker, stage 4 is wake to the session's
acknowledgement, stage 5 is acknowledgement to reply.
The journal is read with:

```sh
bin/fm-discord-conversation-console.sh latency --json --limit 200
```

### Before (real traffic, 2026-09-19 15:29 to 2026-09-20 02:12)

Twenty-four usable records out of fifty-five; the other thirty-one are a polling
pass re-reading old history, which the journal itself makes visible with an
unusable stage 1 and stage 3, and they are excluded.

| measure | median | min | max |
| --- | --- | --- | --- |
| stage 1 Discord to console | 1.281 s | | |
| stage 2 console handling | 1.147 s | | |
| stage 3 wake | 19.936 s | | |
| message to wake (stages 1+2+3) | 21.995 s | 3.789 s | 119.185 s |

The wake stage is the watcher's own cycle, and it is the term the earlier
delivery work already shortened; `tests/fm-discord-console-latency.test.sh`
still pins that A/B at 11.05 s vs 0.70 s.

### After: preparation does not move the wake

Preparation is started beside the route gate and read only at the handoff, so
its advisory call runs in the window the capture already spends on an advisory
call. `tests/fm-discord-console-prepare.test.sh` measures the capture stage with
a 0.6 s server delay in both configurations and proves the two calls overlap
from the fake server's own request timestamps:

```
PREPARE_LATENCY_STAGE2_OFF=1.035
PREPARE_LATENCY_STAGE2_ON=1.070
PREPARE_CALLS_OVERLAPPED=yes
```

Three runs of the same measurement on the same host:

| run | capture stage, preparation off | capture stage, preparation on | difference |
| --- | --- | --- | --- |
| 1 | 1.035 s | 1.070 s | 0.035 s |
| 2 | 1.015 s | 1.106 s | 0.091 s |
| 3 | 0.978 s | 1.130 s | 0.152 s |
| median | 1.015 s | 1.106 s | 0.091 s |

So the packet costs about 0.09 s on the capture stage when the fast path is on,
and the sleep after the capture - stages 3 and 4, which are what the captain
feels - is unchanged by construction: the note append, the wake kick, and the
durable queue are untouched.
With the fast path off there is no advisory call to overlap with, so that
configuration pays the preparation wall clock itself; the same measurement
driver reports the real cost of one preparation (767 ms median, 870 ms maximum)
and the console bounds it at `prepare.timeout_seconds` (4 s default).
A message the fast path answers skips preparation without waiting for it at
all: with a preparer bound to 20 s, the fast answer returned in 0.29 s, 0.37 s,
and 0.39 s over three runs.

## Before and after: the main turn's duration

Method, two layers, because the two costs are different in kind.

The session's own reasoning time is not measurable from here - it needs a real
model turn - so it is measured after this ships, by the same journal, split by
the preparation outcome each request recorded:

```sh
bin/fm-discord-conversation-console.sh latency --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)["rows"]
for row in rows:
    print(row["message_id"], row["path"], row["prepare_status"] or "off", row["prepare_ms"], row["stage4_session_activation"])
'
```

`status` reports the same split as `packets prepared` and `packets skipped`.

### Before (real traffic)

| measure | median | min | max |
| --- | --- | --- | --- |
| wake to reply (stages 4+5) | 76.335 s | 26.063 s | 247.633 s |

That is the wait the packet is meant to shorten, and stage 5 alone is
effectively zero (median -0.041 s) because the session acknowledges the note
when it has handled it, so the whole turn sits inside stage 4.

### After: the record-gathering phase the packet removes

The packet's facts are the reads the turn would otherwise make.
Measured on the same real records, for the fleet-shape packet above and for a
named-task packet:

| what the turn reads | before | after |
| --- | --- | --- |
| fleet facts: in-flight backlog section + project registry | 32,673 bytes | 266 bytes of facts, 1,126 bytes of whole packet, already in the note |
| the same two files read whole | 66,012 bytes | as above |
| one named task: `bin/fm-crew-state.sh <task>` plus its backlog line and latest event | 0.30 s median for the reconciliation call alone, and two more reads | 4 to 5 fact lines in the note |

The commands behind those numbers:

```sh
sed -n '/^## In flight/,/^## /p' data/backlog.md | wc -c
wc -c data/projects.md data/backlog.md
time bin/fm-crew-state.sh <task>          # 0.29-0.30 s over three runs
```

So the packet replaces 32.7 KB to 66.0 KB of record text, or a 0.30 s
reconciliation call plus two record reads, with at most 1.1 KB that is already in
the note the session is reading anyway.

## The fallback path

`tests/fm-jev-console-prepare.test.sh` drives the classifier itself: a settled
verdict, a candidate list that is empty and so is not asked about, a
low-confidence intent, a low-confidence selection, an API error, a malformed
response, an out-of-vocabulary intent, a non-finite confidence, invalid input,
the wall-clock timeout, an unusable bound, a missing key, the `.env` key
fallback, file input, and the usage errors.
Every failure resolves to `flag` set with exit 0, never to a guessed packet.

`tests/fm-discord-console-prepare.test.sh` drives the capture path over four
real fallback shapes - a missing preparer command, a preparer that exits
non-zero, a preparer that outlives its 1 s bound while the server sleeps 30 s,
and an uncertain verdict - and proves in each case that the note is captured
exactly once, still carries the raw message, carries no packet block, and has a
durable fallback outcome naming the reason.
That suite also proves the preparation never posts an answer to the captain,
never changes a task record (the backlog and both task metadata files are
byte-identical across the capture), writes no preparation state at all while
disabled, and stays exactly once across a replayed capture.

## What this measurement does not cover

- The session's own reasoning time over a packet, which needs a live turn with a
  real model; the after numbers for it accumulate in the journal once the step is
  enabled, split by `prepared` and `fallback` as described above.
- The real Discord round trip: the pinned suites run against loopback fakes, so
  the capture-stage figures exclude it, exactly as the fast-path record notes.
- The accept rate is measured over fourteen messages of one captain's prose;
  it is a real sample, not a general one.

## Undo

Every live-facing change and its exact undo is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md)
("Prepared request", "Undoing a live change"): flip `prepare.enabled` back to
`false` and restart the listener, delete the `prepare/` state directory, or
revert this capability's commits.
Nothing in the step is enabled by default, so merging the code alone changes no
running behavior.
