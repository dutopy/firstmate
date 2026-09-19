# Discord console latency - verification

This record holds the active empirical claims behind the Discord console latency
tracing: the five measured stages, the before and after wake numbers, the gateway
delivery evidence, and the delivery-gap visibility.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md);
this page is evidence, not a second contract.

## Environment and commands

Measured on 2026-09-19 on the firstmate host.
The before numbers come from the durable records of six real captain messages on
2026-09-18: the inbox note `at=`, the watcher `.seen-inbox-<note>` marker mtime,
and the reply receipt.
The controlled wake comparison runs the real `bin/fm-watch.sh` and the real
`bin/fm-inbox.sh note --source discord` at the production `FM_POLL=15`, three
runs each, and is pinned by:

```sh
bash tests/fm-discord-console-latency.test.sh
```

The report the live console now writes is read with:

```sh
bin/fm-discord-conversation-console.sh latency [--limit N] [--json]
```

## The five stages

The console writes one bounded latency-journal record per request.
Stage 1 is Discord creation to console ingest, stage 2 is ingest to capture,
stage 3 is the wake reaching the session (the `.seen-inbox` marker), stage 4 is
the note acknowledgement (`fm-inbox.sh drain --ack` marker), and stage 5 is the
turn up to the reply.
Stages 3 and 4 are read back from the durable markers the capture path already
produced, never re-timed.

## Before and after: the wake stage

Six real captain messages on 2026-09-18, medians:

| stage | value |
| --- | --- |
| stage 1 Discord to console | 0.49 s |
| stage 3 wake | 42.2 s (min 0.4 s, max 56.5 s) |
| activation plus turn | 34.8 s |
| total | 80.2 s |

The controlled before and after, measured from the note append to the
`.seen-inbox` marker:

| run | before (no kick, old sleep-15) | after (kick plus fine queue poll) |
| --- | --- | --- |
| 1 | 11054 ms | 683 ms |
| 2 | 10912 ms | 702 ms |
| 3 | 11066 ms | 775 ms |

The kick is a best-effort local USR1 to the waiting watcher, identity-guarded by
the lock's `pid-identity`; the durable queue stays the authority and the poll
stays the fallback.

## Gateway delivery evidence

The live console's `connection.json` read `mode=gateway`, `state=connected`.
Stage 1 was sub-second on all six real messages, from 0.20 s to 1.20 s, which a
bounded REST poll could not produce repeatably.
Every capture is now tagged with its `transport`, and `status` reports the tally.
A message captured through polling while `live.gateway` is enabled, and any fall
back of the permanent connection itself, are recorded in a bounded
`delivery-gaps.json` so the fallback is visible instead of silent.
`tests/fm-discord-conversation-console.test.sh` asserts a gateway-tagged capture
and a recorded `gateway-fallback` gap.

## What remains slow

The wake stage is sub-second and the transport is sub-second.
The remaining latency is the turn itself, roughly 35 s here, and it is dominated
by the session's accumulated context rather than by any transport in the chain.
