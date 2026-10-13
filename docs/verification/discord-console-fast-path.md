# Discord console fast path - verification

This record holds the active empirical claims behind the #firstmate console fast
path: the acknowledgement and fast-answer latencies, the observed full-turn
baseline they are compared against, the fail-closed routing, the replay
idempotence, the unchanged legacy behavior, and the typing indicator.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md);
this page is evidence, not a second contract.

## Environment and commands

Measured on 2026-09-18 on the firstmate host, Python 3.12, against the fake local
Discord HTTP server and fake local System One server the test suites own, so no
real token is read and no request leaves loopback.
The end-to-end fast-path suite prints its two latency figures and asserts them:

```sh
bash tests/fm-discord-console-fast-path.test.sh
```

The last measured green run printed:

```
FAST_LATENCY_ACK=0.213
FAST_LATENCY_ANSWER=0.309
```

The classifier's own matrix runs with:

```sh
bash tests/fm-jev-console-route.test.sh
```

## Acknowledgement and fast-answer latency

The `FAST_LATENCY_ACK` figure is the wall time from the start of the capture pass
to the moment the deterministic acknowledgement is posted: 0.21 seconds.
The `FAST_LATENCY_ANSWER` figure is the wall time to the record-backed answer:
0.31 seconds.
Both are asserted below five seconds by the suite, and both are measured on the
identical code path the live console uses, with only the Discord and System One
HTTP endpoints replaced by the loopback fakes.

What the figures do not include, and could not measure from here:

- The real Discord round trip. The fake Discord server answers on loopback, so a
  live acknowledgement adds roughly twice the host's round trip to Discord; the
  relay's own published framing/cost work is the closest comparable number.
- The real System One round trip beyond the fake's immediate answer. The console
  gate's own bound and the fail-closed fallback cover a slow or unavailable
  answer, so a slow model can delay the answer but can never delay the
  acknowledgement.

## The current full-turn baseline

The captain's complaint is the full firstmate turn, so the honest comparison is
the delay he already experienced.
The console's own durable records hold five real captain exchanges from
2026-09-18.
Each capture writes a note id whose leading epoch is the capture second, and each
answer writes a reply receipt whose `recorded_at` is the post second, so the
full-turn latency is the difference:

| Captain message | Captured (UTC) | Answered (UTC) | Full-turn latency |
| --- | --- | --- | --- |
| `1550596241266704455` | 19:56:34 | 19:57:46 | 72 s |
| `1550596167925235712` | 19:56:34 | 19:57:46 | 72 s |
| `1550596958593486951` | 19:59:02 | 20:00:53 | 111 s |
| `1550607279026339861` | 20:39:44 | 20:40:38 | 54 s |
| `1550607185506083009` | 20:39:22 | 20:40:38 | 76 s |

The five exchanges took 54 to 111 seconds, median 72 seconds.
The fast path's 0.21-second acknowledgement and 0.31-second answer are therefore
between roughly 170 and 350 times faster than the turn they replace for a status
question, while a message that needs a full turn still waits exactly as before.

## Fail-closed routing and replay

The end-to-end suite proves, on the same fake servers:

- a confident fast answer posts the acknowledgement and the record-backed answer
  and writes no full-turn note;
- a low-confidence classification posts the acknowledgement, writes exactly one
  full-turn note, posts no answer, and audits the message as `full_turn`;
- a classifier that exits nonzero does the same, so a failing gate falls back;
- clearing the cursors and replaying the capture posts no second acknowledgement
  and appends no second note, because the acknowledgement, answer, and decision
  are durable records keyed by request id;
- the disabled default leaves every message on the existing capture path and
  writes no fast-path record at all.

`tests/fm-jev-console-route.test.sh` proves the classifier itself resolves
`full_turn` with exit 0 for a low confidence, an out-of-range confidence, a
missing key, an API error, a malformed response, an unexpected route, invalid
input, a stale core, and its wall-clock bound, and that its output is always
strict JSON with a numeric confidence.

## Typing indicator

The same suite drives the full-turn route with the typing keeper enabled and
proves the indicator reaches both the channel and the thread, that a live typing
marker exists for each, that the reply command removes the channel marker and the
keeper exits, that `typing --stop` removes the thread marker, that `status`
reports zero active keepers afterwards, and that the fast path and an ignored
message start no keeper.

## Legacy behavior

`tests/fm-discord-conversation-console.test.sh` continues to pass unchanged with
the fast path off, covering exactly-once capture across a restart, ignored
non-captain messages, thread-scoped replies, the side-effect-free status report,
the transport registration, the permanent gateway connection and its resume, the
polling fallback, and the supervised relaunch.
