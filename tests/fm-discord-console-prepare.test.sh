#!/usr/bin/env bash
# Behavior tests for the #firstmate console request preparation.
#
# Everything runs against a fake local HTTP Discord server and a fake local
# typesafe.ai System One server (which serves the route question and the
# preparation questions from one base URL), so no real token is read and no
# network call leaves loopback. Covers:
#   - a prepared packet attached to the durable intake note, with the raw
#     message alongside it and the durable outcome recorded;
#   - every fallback: a missing preparer, a failing preparer, a preparer that
#     times out, and an uncertain verdict, each leaving the note on the raw
#     message alone;
#   - a fast answer skipping preparation at once instead of waiting out the
#     preparer's bound;
#   - the disabled default that writes no preparation state at all;
#   - preparation never answering the captain and never changing a task record;
#   - the measured cost of preparation on the capture stage, and the proof that
#     the preparer call runs beside the route call rather than after it;
#   - exactly-once preparation across a replayed capture;
#   - `status` and `latency` showing whether a packet was used or skipped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-console-prepare-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
FAKE_TOKEN=faketoken-prep-abc123
FAKE_KEY=typesafe-test-key
SHARED_CORE=${FM_JV_CONSOLE_ROUTE_CORE:-/home/dutopy/atelier/data/jev_decide.py}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_CONSOLE_ROUTE_CORE to run this suite)"
  exit 0
}
export FM_JV_CONSOLE_ROUTE_CORE="$SHARED_CORE"
export FM_JV_PREPARE_CORE="$SHARED_CORE"
export FM_JV_PREPARE_THRESHOLD="${FM_JV_PREPARE_THRESHOLD:-0.9}"

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }

cleanup_all() {
  local code=$?
  [ -n "${DISCORD_PID:-}" ] && kill "$DISCORD_PID" 2>/dev/null || true
  kill %1 2>/dev/null || true
  [ -n "${TS_PID:-}" ] && kill "$TS_PID" 2>/dev/null || true
  pkill -f "typing --config $TMP_ROOT" 2>/dev/null || true
  local home
  for home in "${H:-}" "${H2:-}" "${H3:-}" "${H4:-}" "${H5:-}" "${H6:-}" "${H7:-}" "${H8:-}" "${H9:-}"; do
    [ -n "$home" ] && FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
  exit "$code"
}
# The exit trap keeps the real status, so a failing assertion still fails the
# suite instead of being masked by cleanup.
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT

CONSOLE_STATE="state/discord-workspace/conversation-console"

note_file() { # note_file <home> -> the one note path, or empty
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | sort | head -1
}

note_count() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

prepare_records() { # prepare_records <home> -> one line per outcome record
  local dir="$1/$CONSOLE_STATE/prepare"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.json' 2>/dev/null | sort
}

posts() { # posts <channel> -> posted message contents, one per line
  python3 - "$WORLD" "$1" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
for message in world.get("posts", {}).get(sys.argv[2], []):
    print(message["content"].replace("\n", "\\n"))
PY
}

seed_message() { # seed_message <channel> <id> <content>
  python3 - "$WORLD" "$1" "$2" "$3" "$CAPTAIN" <<'PY'
import json, sys
world, channel, message_id, content, captain = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
world.setdefault("messages", {}).setdefault(channel, []).append(
    {
        "id": message_id,
        "content": content,
        "author": {"id": captain},
        "channel_id": channel,
        # A real Discord message carries its own creation time; the fixture
        # states it so the packet's received date is the real one rather than
        # one derived from the fixture's synthetic message id.
        "timestamp": "2026-09-20T05:00:00+00:00",
    }
)
json.dump(world, open(sys.argv[1], "w"))
PY
}

start_server() { # start_server <world-file> <port-file>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" "$GUILD" > "$TMP_ROOT/fake-server.log" 2>&1 <<'PY' &
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORLD, PORT_FILE, TOKEN, GUILD = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BOT = "333333333333333333"

def load():
    with open(WORLD, encoding="utf-8") as f:
        return json.load(f)

def save(world):
    tmp = WORLD + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(world, f)
    import os
    os.replace(tmp, WORLD)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self, world):
        return self.headers.get("Authorization") == f"Bot {world.get('token') or TOKEN}"

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)
        world = load()
        if not self._authorized(world):
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 4 and parts[0] == "guilds" and parts[2] == "threads" and parts[3] == "active":
            self._send(200, {"threads": world.get("threads", {}).get(parts[1], [])})
        elif len(parts) == 5 and parts[0] == "channels" and parts[2:4] == ["threads", "archived"] and parts[4] == "public":
            self._send(200, {"threads": world.get("archived", {}).get(parts[1], [])})
        elif len(parts) == 2 and parts[0] == "channels":
            channel = world.get("channels", {}).get(parts[1])
            if channel is None:
                self._send(404, {"message": "not found"})
            else:
                self._send(200, channel)
        elif len(parts) == 3 and parts[2] == "messages":
            after = int(query.get("after", ["0"])[0])
            limit = int(query.get("limit", ["100"])[0])
            msgs = [m for m in world.get("messages", {}).get(parts[1], []) if int(m["id"]) > after]
            msgs.sort(key=lambda m: int(m["id"]), reverse=True)
            self._send(200, msgs[:limit])
        else:
            self._send(404, {"message": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {}
        world = load()
        if not self._authorized(world):
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 3 and parts[2] == "typing":
            world.setdefault("typing", []).append({"channel_id": parts[1], "at": time.time()})
            save(world)
            self.send_response(204)
            self.end_headers()
            return
        if len(parts) == 3 and parts[2] == "messages":
            if body.get("allowed_mentions") != {"parse": []}:
                self._send(400, {"message": "allowed_mentions must be empty parse"})
                return
            world["counter"] = int(world.get("counter", 900000000000000000)) + 1
            message = {"id": str(world["counter"]), "content": body.get("content"),
                       "author": {"id": BOT, "bot": True}, "channel_id": parts[1],
                       "at": time.time()}
            world.setdefault("posts", {}).setdefault(parts[1], []).append(message)
            save(world)
            self._send(200, message)
        else:
            self._send(404, {"message": "not found"})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  DISCORD_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$2" ] && break
    sleep 0.1
  done
  [ -s "$2" ] || fail "fake Discord server did not start"
}

# --- fake sops, fake crew state, and the fake typesafe server ----------------
mkdir -p "$TMP_ROOT/worktree"
cat > "$TMP_ROOT/fake-sops" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "-d" ] || exit 64
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: $FAKE_TOKEN\n'
FAKE
chmod +x "$TMP_ROOT/fake-sops"

cat > "$TMP_ROOT/fake-crew-state" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "task-b" ]; then
  printf 'state: blocked \xc2\xb7 source: run-step \xb7 test fixture\n'
else
  printf 'state: working \xc2\xb7 source: run-step \xc2\xb7 test fixture\n'
fi
FAKE
chmod +x "$TMP_ROOT/fake-crew-state"

cat > "$TMP_ROOT/broken-preparer" <<'FAKE'
#!/usr/bin/env bash
exit 3
FAKE
chmod +x "$TMP_ROOT/broken-preparer"
cat > "$TMP_ROOT/slow-preparer" <<'FAKE'
#!/usr/bin/env bash
sleep 30
FAKE
chmod +x "$TMP_ROOT/slow-preparer"

TS_PORT_FILE="$TMP_ROOT/ts-port"
TS_LOG="$TMP_ROOT/ts-log"
ANSWERS="$TMP_ROOT/ts-answers.json"
rm -rf "$TS_LOG"; mkdir -p "$TS_LOG"

# answers_map <route-choice> <route-confidence> <intent> <intent-confidence>:
# writes the answers map the fake System One server serves. The map is keyed by
# the question that identifies the caller - the route question for the console's
# route classifier, the intent question for the preparer - and each entry is the
# complete answer set that caller asked for, so one base URL serves both.
answers_map() {
  local route=$1 rconf=$2 intent=$3 iconf=$4
  python3 - "$route" "$rconf" "$intent" "$iconf" <<'PY' > "$ANSWERS"
import json, sys
route, rconf, intent, iconf = sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4])
def choice(name, conf):
    return {"type": "choice", "choice": name, "confidence": conf, "probabilities": {name: conf}}
answers = {
    "route": {"route": choice(route, rconf)},
    "intent": {
        "intent": choice(intent, iconf),
        "project": choice("firstmate", iconf),
        "entity": choice("task-a", iconf),
    },
}
json.dump(answers, sys.stdout)
PY
}

start_typesafe() { # start_typesafe <delay>
  [ -n "${TS_PID:-}" ] && kill "$TS_PID" 2>/dev/null || true
  rm -f "$TS_PORT_FILE"
  # The fake server's output goes to a file: a leaked child must never hold the
  # suite's stdout open, and a pipe-reading runner would then wait forever.
  python3 "$ROOT/tests/assets/jev-classify-fake-typesafe.py" --port-file "$TS_PORT_FILE" \
    --log-dir "$TS_LOG" --answers-map-file "$ANSWERS" --threaded --delay "$1" \
    > "$TS_LOG/fake-server.out" 2>&1 &
  TS_PID=$!
  local i=0
  while [ ! -s "$TS_PORT_FILE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$TS_PORT_FILE" ] || fail "fake typesafe server did not start"
  TYPESAFE_BASE_URL="http://127.0.0.1:$(cat "$TS_PORT_FILE")"
  export TYPESAFE_BASE_URL
  export TYPESAFE_API_KEY="$FAKE_KEY"
}

# make_home <name> <fast on|off> <prepare on|off> <ack on|off> <typing on|off>
#           [prepare-command] [prepare-timeout]
# Sets H to the new home and CHANNEL to its configured #firstmate channel.
make_home() {
  local name=$1 fast=$2 prepare=$3 ack=$4 typing=$5 pcmd=${6:-} ptimeout=${7:-}
  H="$TMP_ROOT/$name"
  mkdir -p "$H/state" "$H/data" "$H/config"
  chmod 700 "$H/state"
  FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
  CHANNEL=$(python3 -c "import sys; print(700000000000000000 + int(sys.argv[1]))" "${CHANNEL_SEQ:-0}")
  CHANNEL_SEQ=$(( ${CHANNEL_SEQ:-0} + 1 ))
  python3 - "$H/config/discord-conversation-console.json" "$fast" "$prepare" "$ack" "$typing" "$GUILD" "$BOT" "$CAPTAIN" "$CHANNEL" "$pcmd" "$ptimeout" <<'PY'
import json, sys
path, fast, prepare, ack, typing, guild, bot, captain, channel, pcmd, ptimeout = sys.argv[1:12]
data = json.load(open(path))
data["bot"]["user_id"] = bot
data["captain_user_ids"] = [captain]
data["channels"] = [{"label": "Internal", "guild_id": guild, "channel_id": channel}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["fast_path"]["enabled"] = fast == "on"
data["fast_path"]["acknowledgement_enabled"] = ack == "on"
data["fast_path"]["typing"] = typing == "on"
data["prepare"]["enabled"] = prepare == "on"
if pcmd:
    data["prepare"]["classifier_command"] = pcmd
if ptimeout:
    data["prepare"]["timeout_seconds"] = float(ptimeout)
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
  printf '# Backlog\n\n## In flight\n- [ ] task-a - A test task for the console (repo: firstmate) (kind: ship)\n- [ ] task-b - A blocked test task (repo: firstmate) (kind: ship)\n' > "$H/data/backlog.md"
  printf -- '- firstmate [no-mistakes-prod-only] - The fleet tooling (added 2026-09-01)\n- folium [no-mistakes-prod-only] - The Folium client product (added 2026-09-04)\n' > "$H/data/projects.md"
  printf 'kind=ship\nworktree=%s\n' "$TMP_ROOT/worktree" > "$H/state/task-a.meta"
  printf 'kind=ship\nworktree=%s\n' "$TMP_ROOT/worktree" > "$H/state/task-b.meta"
  printf 'working: implementing the packet\n' > "$H/state/task-a.status"
}

WORLD="$TMP_ROOT/world.json"
PORT_FILE="$TMP_ROOT/port"
python3 - "$WORLD" <<'PY'
import json, sys
json.dump({"token": None, "counter": 900000000000000000, "threads": {}, "archived": {}, "messages": {}, "posts": {}}, open(sys.argv[1], "w"))
PY
start_server "$WORLD" "$PORT_FILE"
PORT=$(cat "$PORT_FILE")
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0
export FM_CONSOLE_CREW_STATE_CMD="$TMP_ROOT/fake-crew-state"

# --- 1. a prepared packet is attached to the note, with the raw message ------
answers_map full_turn 0.97 state_question 0.96
start_typesafe 0
make_home prepared on on off on
CFG="$H/config/discord-conversation-console.json"
seed_message "$CHANNEL" "$CHANNEL"01 "where does task-a stand? PR https://github.com/kunchenguid/firstmate/pull/4994 on 2026-09-20"
BEFORE_SUM=$(md5sum "$H/data/backlog.md" "$H/state/task-a.meta" "$H/state/task-b.meta" | md5sum)
out=$(dc listen --config "$CFG" 2>&1) || fail "prepared listen failed: $out"
assert_contains "$out" "captured=1" "the prepared message is captured"
assert_equals "1" "$(note_count "$H")" "exactly one durable note is written"
NOTE=$(note_file "$H")
BODY=$(cat "$NOTE")
assert_contains "$BODY" "PREPARED REQUEST (advisory, derived from the raw message below)" "the note carries the packet block"
assert_contains "$BODY" "intent: state_question" "the packet names the intent"
assert_contains "$BODY" "project: firstmate" "the packet names the selected project"
assert_contains "$BODY" "entity: task-a" "the packet names the selected task"
assert_contains "$BODY" "ask: where does task-a stand? PR https://github.com/kunchenguid/firstmate/pull/4994 on 2026-09-20" "the packet carries the normalised ask"
assert_contains "$BODY" "task=task-a" "the packet carries the task identifier"
assert_contains "$BODY" "pr=https://github.com/kunchenguid/firstmate/pull/4994" "the packet carries the pull request identifier"
assert_contains "$BODY" "date=2026-09-20" "the packet carries the date the message names"
assert_contains "$BODY" "received=2026-" "the packet carries the date the message was received"
assert_contains "$BODY" "RAW MESSAGE (authoritative)" "the raw message follows under its own heading"
assert_contains "$BODY" "reconciled state: task-a is in progress" "a fact is read from the reconciled record"
assert_contains "$BODY" "backlog: A test task for the console" "a fact is read from the backlog"
assert_contains "$BODY" "last recorded event: working: implementing the packet" "a fact is read from the task's latest event"
python3 - "$H" "$NOTE" <<'PY' || fail "the packet outcome or the raw-message ordering is wrong"
import json, os, sys
home, note = sys.argv[1], sys.argv[2]
body = open(note, encoding="utf-8").read()
raw = "where does task-a stand? PR https://github.com/kunchenguid/firstmate/pull/4994 on 2026-09-20"
packet_at = body.index("PREPARED REQUEST")
raw_at = body.index("RAW MESSAGE (authoritative)")
assert packet_at < raw_at, "the packet block must come before the raw message"
# The ask line repeats the message here, so the raw block is the LAST place it
# appears: that is where the captain's own words travel.
assert body.rindex(raw) > raw_at, "the raw message must follow the packet"
directory = os.path.join(home, "state", "discord-workspace", "conversation-console", "prepare")
records = [json.load(open(os.path.join(directory, name))) for name in os.listdir(directory)]
assert len(records) == 1, f"exactly one outcome record: {records}"
record = records[0]
assert record["status"] == "prepared", f"the outcome must record the prepared packet: {record}"
assert record["packet"]["raw_message"] == raw, "the packet carries the captain's exact words"
assert record["packet"]["intent"] == "state_question", "the packet outcome carries the intent"
assert record["packet"]["identifiers"]["task"] == "task-a", "the packet outcome carries the task identifier"
assert record["packet"]["identifiers"]["pr"] == ["https://github.com/kunchenguid/firstmate/pull/4994"], "the packet outcome carries the pull request URL"
assert record["packet"]["raw_message_sha256"], "the packet binds the raw message by hash"
assert 3 <= len(record["packet"]["facts"]) <= 5, f"the packet carries three to five facts: {record['packet']['facts']}"
assert isinstance(record.get("duration_ms"), (int, float)), "the outcome records how long preparation took"
PY
assert_equals "" "$(posts "$CHANNEL")" "preparation never posts an answer of its own to the captain"
AFTER_SUM=$(md5sum "$H/data/backlog.md" "$H/state/task-a.meta" "$H/state/task-b.meta" | md5sum)
assert_equals "$BEFORE_SUM" "$AFTER_SUM" "preparation changes no task record"
AUDIT_DIR="$H/$CONSOLE_STATE/fast-path/audits"
assert_equals "full_turn" "$(python3 -c "import json,glob,sys; print(json.load(open(glob.glob(sys.argv[1]+'/*.json')[0]))['path'])" "$AUDIT_DIR")" "the message still takes the full turn"
pass "prepared packet: intent, target, identifiers and facts, with the raw message"

# --- 2. status and latency show the packet was used --------------------------
out=$(dc status --config "$CFG" 2>&1) || fail "status failed: $out"
assert_contains "$out" "request preparation: on" "status reports the preparation switch"
assert_contains "$out" "packets prepared: 1" "status reports the prepared packet"
assert_contains "$out" "packets skipped: 0" "status reports no skip"
assert_contains "$out" "prepare last: prepared" "status names the last outcome"
out=$(dc latency --config "$CFG" --json 2>&1) || fail "latency failed: $out"
python3 - "$out" <<'PY' || fail "the latency report must carry the preparation stage"
import json, sys
report = json.loads(sys.argv[1])
row = report["rows"][0]
assert row["prepare_status"] == "prepared", f"the row records the preparation outcome: {row}"
assert isinstance(row["prepare_ms"], (int, float)), f"the row records the preparation cost: {row}"
assert isinstance(report["medians"]["prepare_ms"], (int, float)), "the medians include the preparation cost"
PY
pass "status and latency show whether a packet was used or skipped"

# --- 3. every fallback keeps the note on the raw message alone ---------------
fallback_case() { # fallback_case <label> <prepare-command override or -> <timeout or -> <intent> <intent-confidence>
  local label=$1 pcmd=$2 ptimeout=$3 intent=$4 iconf=$5
  answers_map full_turn 0.97 "$intent" "$iconf"
  start_typesafe 0
  local pcmd_arg="" timeout_arg=""
  [ "$pcmd" != "-" ] && pcmd_arg="$pcmd"
  [ "$ptimeout" != "-" ] && timeout_arg="$ptimeout"
  make_home "fb-$label" on on off on "$pcmd_arg" "$timeout_arg"
  local cfg="$H/config/discord-conversation-console.json"
  seed_message "$CHANNEL" "$CHANNEL"01 "status of task-a please"
  local out
  out=$(dc listen --config "$cfg" 2>&1) || fail "$label listen failed: $out"
  assert_equals "1" "$(note_count "$H")" "$label still captures exactly one note"
  local body
  body=$(cat "$(note_file "$H")")
  assert_contains "$body" "status of task-a please" "$label keeps the raw message"
  assert_not_contains "$body" "PREPARED REQUEST" "$label attaches no packet"
  python3 - "$H" <<'PY' || fail "$label must record a fallback outcome"
import json, os, sys
directory = os.path.join(sys.argv[1], "state", "discord-workspace", "conversation-console", "prepare")
records = [json.load(open(os.path.join(directory, name))) for name in os.listdir(directory)] if os.path.isdir(directory) else []
assert len(records) == 1, f"exactly one outcome record: {records}"
assert records[0]["status"] == "fallback", f"the outcome must be a fallback: {records[0]}"
assert records[0]["packet"] is None, "a fallback carries no packet"
assert records[0]["reason"], "a fallback names its reason"
PY
  pass "$label: raw message only, durable fallback outcome"
}

fallback_case missing "$TMP_ROOT/no-such-preparer" - state_question 0.96
fallback_case failing "$TMP_ROOT/broken-preparer" - state_question 0.96
fallback_case slow "$TMP_ROOT/slow-preparer" 1.0 state_question 0.96
fallback_case uncertain - - state_question 0.4

# --- 4. a fast answer skips preparation without waiting for it ---------------
answers_map fast_answer 0.97 state_question 0.96
start_typesafe 0
# The preparer is deliberately slower than the whole slow-path bound: a fast
# answer must not wait for a packet it has nowhere to put.
make_home fast-skip on on on on "$TMP_ROOT/slow-preparer" 20
CFG_SKIP="$H/config/discord-conversation-console.json"
seed_message "$CHANNEL" "$CHANNEL"01 "where does task-a stand"
STARTED=$(date +%s.%N)
out=$(dc listen --config "$CFG_SKIP" 2>&1) || fail "fast-skip listen failed: $out"
ELAPSED=$(python3 -c "import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 3))" "$STARTED" "$(date +%s.%N)")
assert_equals "0" "$(note_count "$H")" "a fast answer still writes no note"
assert_contains "$(posts "$CHANNEL")" "task-a is in progress." "the fast answer is still posted"
python3 - "$H" <<'PY' || fail "the fast answer must record a skipped preparation"
import json, os, sys
directory = os.path.join(sys.argv[1], "state", "discord-workspace", "conversation-console", "prepare")
records = [json.load(open(os.path.join(directory, name))) for name in os.listdir(directory)]
assert len(records) == 1, f"exactly one outcome record: {records}"
assert records[0]["status"] == "fallback", f"a skipped preparation is a fallback: {records[0]}"
assert "fast path" in records[0]["reason"], f"the reason names the fast path: {records[0]['reason']}"
PY
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 3.0 else 1)" "$ELAPSED" \
  || fail "the fast answer waited ${ELAPSED}s for a preparation it cannot use"
printf 'info - fast answer with a 30s preparer bound to 20s: %ss wall clock, no wait for the packet\n' "$ELAPSED"
pass "a fast answer skips preparation at once instead of waiting out the bound"

# --- 5. the disabled default writes no preparation state at all --------------
answers_map full_turn 0.97 state_question 0.96
start_typesafe 0
make_home disabled on off off on
CFG_OFF="$H/config/discord-conversation-console.json"
seed_message "$CHANNEL" "$CHANNEL"01 "please add a retry to the console"
out=$(dc listen --config "$CFG_OFF" 2>&1) || fail "disabled listen failed: $out"
assert_equals "1" "$(note_count "$H")" "the disabled preparation still captures the note"
BODY_OFF=$(cat "$(note_file "$H")")
assert_contains "$BODY_OFF" "please add a retry to the console" "the disabled preparation keeps the raw message"
assert_not_contains "$BODY_OFF" "PREPARED REQUEST" "the disabled preparation attaches nothing"
[ ! -d "$H/$CONSOLE_STATE/prepare" ] || fail "the disabled preparation must write no preparation state"
out=$(dc status --config "$CFG_OFF" 2>&1) || fail "status failed: $out"
assert_contains "$out" "request preparation: off" "status reports the disabled default"
assert_not_contains "$out" "packets prepared:" "a disabled preparation reports no packet counts"
pass "the disabled default leaves the capture path and its note unchanged"

# --- 6. measured cost, and the proof that the preparer runs beside the route --
stage2() { # stage2 <home> -> the capture stage in seconds from the durable journal
  python3 - "$1" <<'PY'
import hashlib, json, os, sys
home = sys.argv[1]
directory = os.path.join(home, "state", "discord-workspace", "conversation-console", "latency")
names = os.listdir(directory)
assert len(names) == 1, f"exactly one latency record: {names}"
record = json.load(open(os.path.join(directory, names[0])))
print("%.3f" % (record["captured_at"] - record["ingested_at"]))
PY
}

answers_map full_turn 0.97 state_question 0.96
start_typesafe 0.6
DRIFT=0.6
make_home measure-off on off off on
seed_message "$CHANNEL" "$CHANNEL"01 "status of task-a"
dc listen --config "$H/config/discord-conversation-console.json" >/dev/null 2>&1 || fail "measure-off listen failed"
OFF=$(stage2 "$H")
rm -rf "$TS_LOG"; mkdir -p "$TS_LOG"
answers_map full_turn 0.97 state_question 0.96
start_typesafe 0.6
make_home measure-on on on off on
seed_message "$CHANNEL" "$CHANNEL"01 "status of task-a"
dc listen --config "$H/config/discord-conversation-console.json" >/dev/null 2>&1 || fail "measure-on listen failed"
ON=$(stage2 "$H")
printf 'PREPARE_LATENCY_STAGE2_OFF=%s\n' "$OFF"
printf 'PREPARE_LATENCY_STAGE2_ON=%s\n' "$ON"
python3 - "$OFF" "$ON" "$DRIFT" <<'PY' || fail "preparation must not serialize the two advisory calls"
import sys
off, on, drift = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
# With a 0.6s server delay, a serialized capture would pay 1.2s while a
# concurrent one stays near 0.6s. The bound leaves room for process startup.
assert on < off + drift, f"preparation added {on - off:.3f}s to the capture stage, so it did not overlap"
PY
python3 - "$TS_LOG/times.jsonl" <<'PY' || fail "the two advisory calls must overlap, not queue"
import json, sys
starts, ends = [], []
for line in open(sys.argv[1], encoding="utf-8"):
    row = json.loads(line)
    if "start" in row:
        starts.append(row["start"])
    if "end" in row:
        ends.append(row["end"])
assert len(starts) == 2 and len(ends) == 2, f"expected two advisory calls, saw {len(starts)} starts and {len(ends)} ends"
# The second call must have started before the first answered: that is what
# keeps the packet off the wake path.
assert min(starts[1], starts[0]) < max(ends[0], ends[1]), "the two calls did not overlap"
first_end = min(ends)
second_start = max(starts)
assert second_start < first_end, f"the second call started after the first ended ({second_start} >= {first_end})"
print("PREPARE_CALLS_OVERLAPPED=yes")
PY
pass "the preparation cost is measured and the preparer call overlaps the route call"

# --- 7. exactly-once preparation across a replayed capture -------------------
answers_map full_turn 0.97 state_question 0.96
start_typesafe 0
make_home replay on on off on
CFG_REPLAY="$H/config/discord-conversation-console.json"
seed_message "$CHANNEL" "$CHANNEL"01 "status of task-a"
dc listen --config "$CFG_REPLAY" >/dev/null 2>&1 || fail "first replay listen failed"
NOTE_BEFORE=$(md5sum "$(note_file "$H")")
rm -rf "$H/$CONSOLE_STATE/cursors"
dc listen --config "$CFG_REPLAY" >/dev/null 2>&1 || fail "second replay listen failed"
assert_equals "1" "$(note_count "$H")" "a replayed capture appends no second note"
assert_equals "$NOTE_BEFORE" "$(md5sum "$(note_file "$H")")" "a replayed capture leaves the first note unchanged"
assert_equals "1" "$(prepare_records "$H" | wc -l | tr -d ' ')" "a replayed capture writes no second preparation record"
pass "exactly-once preparation across a replayed capture"

printf '# all fm-discord-console-prepare tests passed\n'
