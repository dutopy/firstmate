# Discord console session mirror - verification

This record holds the empirical claims behind the native Pi session mirror: one
real Pi session mirrored end to end into the captain's console, the identifiers
Discord accepted, the restart and replay that posted nothing twice, and the
exact undo of every live-facing change.
The behavior contract is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md)
("Session mirror"); this page is evidence, not a second contract.

## Environment and commands

Measured on 2026-09-20 on the firstmate host: Pi 0.85.1, model
`opencode-go/deepseek-v4.1-flash`, Python 3.12.
The console channel is the captain's own `#firstmate` console, channel
`1550470253551685734` in guild `1525898345338372136`, and the posting identity is
the console's own bot, user `1545668675972112484` - the same identity the console
already answers with, so no second bot or webhook identity was introduced.

The pinned suites run entirely against loopback fakes and reach no network:

```sh
bash tests/fm-discord-console-mirror.test.sh
bash tests/fm-pi-session-mirror-extension.test.sh
bash tests/fm-pi-primary-types.test.sh
```

The live runs below are the real extension, the real
`bin/fm-discord-conversation-console.sh mirror` command, and the real Discord API.
One run is one real non-interactive Pi session with only the mirror extension
loaded, so nothing else in the fleet participates:

```sh
FM_HOME=<firstmate home> \
FM_ROOT_OVERRIDE=<firstmate code root> \
FM_STATE_OVERRIDE=<firstmate home>/state \
FM_CONFIG_OVERRIDE=<firstmate home>/config \
pi -ne -e <code root>/.pi/extensions/fm-discord-session-mirror.ts \
  -nc -ns -np --session-dir <session dir> -p "<prompt>"
```

The mirror was enabled for the run with, in
`config/discord-conversation-console.json`:

```json
"mirror": {"enabled": true, "channel_id": "1550470253551685734", "max_chars": 1800}
```

## One Pi session mirrored end to end

The first real run wrote session file
`2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8.jsonl`, whose
captain prompt and visible answer were both posted, in order, by the console bot:

| item | Discord message id | nonce | posted at |
| --- | --- | --- | --- |
| `[captain] Réponds en une seule phrase courte, sans utiliser doutil : confirme que la démonstration du miroir natif Pi vers le canal Discord est en cours.` | `1551144173460263013` | `mirror:1550470253551685734:2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8:2` | 2026-09-20T08:13:09Z |
| `[main] Je ne peux pas la confirmer : je n'ai aucune information sur une telle démonstration en cours.` | `1551144175611936770` | `mirror:1550470253551685734:2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8:3` | 2026-09-20T08:13:10Z |

Read back from Discord rather than from the durable records, the channel held
exactly those two lines, authored by the console bot:

```json
{"id": "1551144173460263013", "author_id": "1545668675972112484", "bot": true, "content": "[captain] Réponds en une seule phrase courte, sans utiliser doutil : confirme que la démonstration du miroir natif Pi vers le canal Discord est en cours."}
{"id": "1551144175611936770", "author_id": "1545668675972112484", "bot": true, "content": "[main] Je ne peux pas la confirmer : je n'ai aucune information sur une telle démonstration en cours."}
```

Two properties this pins beyond "a message appeared":

- The attribution is the mirror's own, `[captain]` and `[main]`, so what the
  captain typed and what Firstmate answered are separable on the phone.
- The item identity is the source position, never the text. The receipt nonces
  above are the session file's stem plus the entry's index, which is what lets a
  replay be refused without ever suppressing a legitimately repeated line.

The durable cursor the run left behind:

```json
{"schema": "fm-discord-conversation-console.mirror-cursor.v1", "file": "<session dir>/2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8.jsonl", "index": 4, "recorded_at": "2026-09-20T08:13:10.514Z", "last_error": ""}
```

A second real run continued the conversation in a new session file; only its own
exchange was posted, so the two identifiers from the first run stayed the only
messages carrying the first exchange:

| item | Discord message id | nonce |
| --- | --- | --- |
| `[captain] Réponds en une seule phrase courte : deuxième tour de la démonstration.` | `1551144296412090429` | `mirror:1550470253551685734:2026-09-20T08-13-37-058Z_01a0bde0-bba2-745b-a775-b690500ed9d9:2` |
| `[main] Deuxième tour de la démonstration, tout fonctionne correctement.` | `1551144298588938241` | `mirror:1550470253551685734:2026-09-20T08-13-37-058Z_01a0bde0-bba2-745b-a775-b690500ed9d9:3` |

## The extension loads from the project's own extension directory

The live runs above passed the extension explicitly with `-e`, which proves the
code but not the loading path a captain's own session uses.
A separate real Pi process was therefore run with NO `-e` at all, from a scratch
project holding nothing but a copy of the extension in `.pi/extensions/`, with
`--approve` trusting that project's local files and only `FM_DISCORD_LIVE_API_BASE`
and `FM_DISCORD_LIVE_SOPS` pointed at a loopback fake:

```sh
cd <scratch project with .pi/extensions/fm-discord-session-mirror.ts>
FM_HOME=<scratch home> FM_ROOT_OVERRIDE=<firstmate code root> ... \
  pi --approve -nc -ns -np --session-dir <dir> -p "Réponds uniquement par : découverte automatique confirmée."
```

The fake endpoint received exactly the two expected items, in order, with an
empty `allowed_mentions` - which means the file is discovered by Pi's ordinary
project-extension scan and needs no explicit load line:

```
900000000000000001 666000000000000001 [captain] Réponds uniquement par : découverte automatique confirmée. {"parse": []}
900000000000000002 666000000000000001 [main] découverte automatique confirmée. {"parse": []}
```

## The replay that posted nothing twice

Two independent replays were run against the live channel.

### The delivery boundary

The exact item `...:2` was replayed by hand, with the same text file and the
same durable item key:

```sh
bin/fm-discord-conversation-console.sh mirror \
  --config <home>/config/discord-conversation-console.json \
  --tag captain --channel 1550470253551685734 \
  --item-key 2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8:2 \
  --text-file <the same text>
```

```
mirror exists for item 2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8:2; no second post
```

### The whole chain, with the cursor rewound to zero

The durable cursor was then rewound to `index: 0` for that same real session
file, which is the strongest shape of the same question: the extension is told
the whole session is unmirrored, so it re-collects both already-delivered items
and hands them to the real command against the real API.
The real tracked extension was driven over the real session file for exactly
this replay.

Result: the channel still held exactly four mirror-attributed messages - the two
from the first exchange and the two from the second - and the cursor advanced
back to `index: 4`.
Both re-collected items were refused by their receipts, so a restart, a replayed
turn, or a cursor lost between a post and its cursor write cannot duplicate a
post.

### An honest note on the first replay attempt

The first run of that harness parsed the session file itself and kept Pi's
session header line, which `SessionManager.getEntries()` omits.
Every index was therefore shifted by one, the replayed item at the shifted index
hit the receipt of a *different* already-delivered item and was skipped, and the
one genuinely new index posted a duplicate of the first answer as Discord message
`1551144422794731523`.
That was a defect in the measurement harness, not in the capability, and it was
removed rather than left in the record: the duplicate message was deleted from
the channel, its stray receipt was deleted from
`state/discord-workspace/receipts/`, and the harness was corrected to match
`getEntries()` before the result above was taken.
The channel therefore shows the four intended lines and nothing else.

## The configuration surface

Live, on the firstmate home's own config:

```sh
FM_HOME=<firstmate home> bin/fm-discord-conversation-console.sh config-check --config <home>/config/discord-conversation-console.json
```

```
live posting: on
session mirror: off
mirror channel: 1550470253551685734 (Hermes)
mirror bound: 1800 chars
```

```sh
FM_HOME=<firstmate home> bin/fm-discord-conversation-console.sh status --config <home>/config/discord-conversation-console.json
```

```
health: healthy
session mirror: off
mirror channel: 1550470253551685734 (Hermes)
mirror bound: 1800 chars
mirror cursor: <session dir>/2026-09-20T08-13-06-619Z_01a0bde0-44bb-7032-a4ea-c8910c3b2be8.jsonl at entry 4
mirror cursor recorded: 2026-09-20T08:14:32.148Z
```

Three independent refusals keep the target honest, and each is pinned by
`tests/fm-discord-console-mirror.test.sh` rather than only observed once: an
enabled mirror with no `channel_id`, an enabled mirror whose `channel_id` is not
one of the configured `#firstmate` channels, and an unconfigured `--channel`.

## What the bound is and is not

`mirror.max_chars` is pinned by the suite, not by the live run: a 6000-character
item posts one 1800-character body whose middle states
`[mirror truncated: N characters omitted]`, so a long item is bounded and
visibly bounded rather than silently partial.
An empty item posts nothing, and operational text is a settled skip that records
no receipt, both pinned by the same suite.

## What this does not cover

- The mirror's behavior under a crash between a Discord post and its receipt
  write is reasoned about, not observed: the item would be re-collected and
  re-posted rather than dropped, because the receipt is what suppresses it and
  there would be no receipt yet.
- The live runs used `pi -p`, one turn per process, so a same-process multi-turn
  cursor advance was covered by the extension suite and the rewind replay rather
  than live.
- The measurement ran against one console channel; the other two configured
  channels were not posted to.

## Undo of the live-facing changes

The exact undo is owned by
[`docs/discord-conversation-console.md`](../discord-conversation-console.md)
("Session mirror", "Undoing a live change").
What this measurement changed on the live home, and its undo:

- `config/discord-conversation-console.json` gained a `mirror` block, and the
  mirror was enabled for the runs and then set back to `enabled: false`.
  A semantic comparison against the pre-change backup
  (`config/discord-conversation-console.json.pre-pi-mirror-demo`) shows the
  `mirror` block as the only difference in the whole file.
  The undo is to remove that block, or to set `mirror.enabled` to `true` to turn
  the capability on; the extension re-reads the config at every turn end, so
  either direction needs no Pi restart.
- The durable records the runs wrote are the cursor at
  `state/discord-workspace/conversation-console/mirror-cursor.json` and four
  `kind: mirror` receipts under `state/discord-workspace/receipts/`.
  Their undo is to delete them.
- The posted items are the four Discord messages listed above.
  Their undo is to delete them in Discord.
- The mirror's own messages are also recorded in the console's bounded ignored
  journal, with reason `bot-author`, because the console's inbound pass sees
  everything in its channel; no wake is appended for them.
