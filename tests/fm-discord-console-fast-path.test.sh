#!/usr/bin/env bash
# Behavior tests for the #firstmate console fast path.
#
# Everything runs against a fake local HTTP Discord server and a fake local
# typesafe.ai System One server, so no real token is read and no network call
# leaves loopback. Covers the instant deterministic acknowledgement, the
# Jev-gated record-backed fast answer, the fail-closed fallback to the full
# firstmate turn for an uncertain or failing classification, exactly-once
# acknowledgement across a replayed capture, same-thread delivery, the disabled
# default that leaves the existing capture path unchanged, and measured
# acknowledgement and fast-answer latency.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-console-fast-path-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
STRANGER=555555555555555555
CH=666000000000000001
CH2=666000000000000002
T1=666000000000000011
FAKE_TOKEN=faketoken-abc123
FAKE_KEY=typesafe-test-key
SHARED_CORE=${FM_JV_CONSOLE_ROUTE_CORE:-/home/dutopy/atelier/data/jev_decide.py}
[ -r "$SHARED_CORE" ] || {
  echo "skip: the shared jev_decide core is not readable at $SHARED_CORE (set FM_JV_CONSOLE_ROUTE_CORE to run this suite)"
  exit 0
}
export FM_JV_CONSOLE_ROUTE_CORE="$SHARED_CORE"

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }

cleanup_fast_path() {
  kill %1 2>/dev/null || true
  [ -n "${TS_PID:-}" ] && kill "$TS_PID" 2>/dev/null || true
  pkill -f "typing --config $TMP_ROOT" 2>/dev/null || true
  local home
  for home in "${H:-}" "${H2:-}" "${H3:-}"; do
    [ -n "$home" ] && FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap cleanup_fast_path EXIT

note_count() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
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
  for _ in $(seq 1 50); do
    [ -s "$2" ] && break
    sleep 0.1
  done
  [ -s "$2" ] || fail "fake Discord server did not start"
}

make_home() { # make_home <name> <fast-path-enabled>
  local name=$1 enabled=$2
  H="$TMP_ROOT/$name"
  mkdir -p "$H/state" "$H/data" "$H/config"
  chmod 700 "$H/state"
  FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
  python3 - "$H/config/discord-conversation-console.json" "$enabled" "$GUILD" "$BOT" "$CAPTAIN" "$CH" <<'PY'
import json, sys
path, enabled, guild, bot, captain, channel = sys.argv[1:7]
data = json.load(open(path))
data["bot"]["user_id"] = bot
data["captain_user_ids"] = [captain]
data["channels"] = [{"label": "Internal", "guild_id": guild, "channel_id": channel}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["fast_path"]["enabled"] = enabled == "on"
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
  printf '# Backlog\n\n## In flight\n- [ ] task-a - A test task for the fast path (repo: firstmate) (kind: ship)\n- [ ] task-b - A blocked test task (repo: firstmate) (kind: ship)\n' > "$H/data/backlog.md"
  mkdir -p "$H/state" "$H/data"
  printf 'kind=ship\nworktree=%s\n' "$TMP_ROOT/worktree" > "$H/state/task-a.meta"
  printf 'kind=ship\nworktree=%s\n' "$TMP_ROOT/worktree" > "$H/state/task-b.meta"
}

# --- fake sops + fake crew state + fake typesafe -----------------------------
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
  printf 'state: blocked \xc2\xb7 source: run-step \xc2\xb7 test fixture\n'
else
  printf 'state: working \xc2\xb7 source: run-step \xc2\xb7 test fixture\n'
fi
FAKE
chmod +x "$TMP_ROOT/fake-crew-state"

cat > "$TMP_ROOT/broken-classifier" <<'FAKE'
#!/usr/bin/env bash
exit 3
FAKE
chmod +x "$TMP_ROOT/broken-classifier"

TS_PORT_FILE="$TMP_ROOT/ts-port"
TS_LOG="$TMP_ROOT/ts-log"
rm -rf "$TS_LOG"; mkdir -p "$TS_LOG"
start_typesafe() { # start_typesafe <choice> <confidence>
  [ -n "${TS_PID:-}" ] && kill "$TS_PID" 2>/dev/null || true
  rm -f "$TS_PORT_FILE"
  python3 "$ROOT/tests/assets/jev-classify-fake-typesafe.py" --port-file "$TS_PORT_FILE" --log-dir "$TS_LOG" --choice "$1" --confidence "$2" &
  TS_PID=$!
  local i=0
  while [ ! -s "$TS_PORT_FILE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$TS_PORT_FILE" ] || fail "fake typesafe server did not start"
  TYPESAFE_BASE_URL="http://127.0.0.1:$(cat "$TS_PORT_FILE")"
  export TYPESAFE_BASE_URL
  export TYPESAFE_API_KEY="$FAKE_KEY"
}

WORLD="$TMP_ROOT/world.json"
PORT_FILE="$TMP_ROOT/port"
python3 - "$WORLD" "$GUILD" "$CH" "$CH2" "$T1" "$CAPTAIN" "$STRANGER" "$BOT" <<'PY'
import json, sys
world_path, guild, ch, ch2, t1, captain, stranger, bot = sys.argv[1:9]
world = {
    "token": None,
    "counter": 900000000000000000,
    "threads": {guild: [{"id": t1, "parent_id": ch}]},
    "archived": {},
    "messages": {
        ch: [
            {"id": "666000000000000100", "content": "where does task-a stand", "author": {"id": captain}, "channel_id": ch},
        ],
        ch2: [
            {"id": "666000000000000400", "content": "Not the captain", "author": {"id": stranger}, "channel_id": ch2},
        ],
        t1: [
            {"id": "666000000000000200", "content": "status of task-a please", "author": {"id": captain}, "channel_id": t1},
        ],
    },
    "posts": {},
}
json.dump(world, open(world_path, "w"))
PY
start_server "$WORLD" "$PORT_FILE"
PORT=$(cat "$PORT_FILE")
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0
export FM_CONSOLE_CREW_STATE_CMD="$TMP_ROOT/fake-crew-state"

# --- 1. fast answer: ack + record answer, no full-turn capture ---------------
start_typesafe fast_answer 0.97
make_home h1 on
CFG="$H/config/discord-conversation-console.json"
STARTED=$(python3 -c 'import time; print(time.time())')
out=$(dc listen --config "$CFG" 2>&1) || fail "fast-path listen failed: $out"
assert_contains "$out" "captured=2" "listen captures both captain messages"
python3 - "$WORLD" "$H" "$CH" "$T1" "$STARTED" <<'PY' || fail "fast-path delivery check failed"
import json, os, sys
world, home, ch, t1, started = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
assert not world.get("typing"), f"the immediate fast path emits no typing indicator: {world.get('typing')}"
ack = "On it - checking the records."
posts = world.get("posts", {})
root = [m for m in posts.get(ch, [])]
thread = [m for m in posts.get(t1, [])]
assert len(root) == 2, f"expected ack+answer in the channel, saw {root}"
assert len(thread) == 2, f"expected ack+answer in the thread, saw {thread}"
assert root[0]["content"] == ack, f"first post must be the ack, saw {root[0]}"
assert thread[0]["content"] == ack, f"first thread post must be the ack, saw {thread[0]}"
assert "task-a is in progress." in root[1]["content"], f"answer must state the reconciled state, saw {root[1]}"
assert "A test task for the fast path" in root[1]["content"], f"answer must carry the backlog title, saw {root[1]}"
latencies = [m["at"] - started for m in (root[0], thread[0], root[1], thread[1])]
assert min(latencies) >= 0, "post timestamp precedes capture"
assert max(latencies) < 5.0, f"fast-path posts took too long: {latencies}"
print("FAST_LATENCY_ACK=%.3f" % max(root[0]["at"] - started, thread[0]["at"] - started))
print("FAST_LATENCY_ANSWER=%.3f" % max(root[1]["at"] - started, thread[1]["at"] - started))
notes = 0
if os.path.isdir(os.path.join(home, "state", "inbox")):
    notes = len([n for n in os.listdir(os.path.join(home, "state", "inbox")) if n.endswith(".note")])
assert notes == 0, f"a fast answer must not capture a full-turn note, saw {notes}"
audits = os.path.join(home, "state", "discord-workspace", "conversation-console", "fast-path", "audits")
records = [json.load(open(os.path.join(audits, f))) for f in os.listdir(audits)]
assert all(r["path"] == "fast_answer" for r in records), f"audits must record the fast path: {records}"
assert all(r["answer_message_id"] for r in records), "audits must record the answer message id"
PY
assert_equals "0" "$(note_count "$H")" "the fast path captures no full-turn note"
pass "fast answer: instant ack plus a record-backed answer, no full turn"

# --- 2. an uncertain classification falls back and still captures ------------
start_typesafe fast_answer 0.4
python3 - "$WORLD" "$CH" "$CAPTAIN" <<'PY'
import json, sys
world, ch, captain = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
world["messages"][ch].append({"id": "666000000000000101", "content": "where does task-a stand", "author": {"id": captain}, "channel_id": ch})
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(dc listen --config "$CFG" 2>&1) || fail "low-confidence listen failed: $out"
assert_equals "1" "$(note_count "$H")" "an uncertain classification still captures exactly one durable note"
python3 - "$WORLD" "$CH" "$H" <<'PY' || fail "low-confidence fallback check failed"
import json, os, sys
world, ch, home = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
posts = [m["content"] for m in world.get("posts", {}).get(ch, [])]
assert posts.count("On it - checking the records.") == 2, f"every captured channel message gets one ack, saw {posts}"
assert sum(1 for p in posts if "task-a is in progress." in p) == 1, f"only the confident message is fast-answered: {posts}"
audits = os.path.join(home, "state", "discord-workspace", "conversation-console", "fast-path", "audits")
paths = sorted(json.load(open(os.path.join(audits, f)))["path"] for f in os.listdir(audits))
assert paths.count("full_turn") == 1, f"one audit must record the full turn, saw {paths}"
PY
pass "uncertain classification: ack, durable capture, no fast answer, audit records full_turn"

# --- 3. a replayed capture posts no second acknowledgement -------------------
BEFORE_ACKS=$(python3 -c "import json;w=json.load(open('$WORLD'));print(len(w['posts'].get('$CH',[])))")
rm -rf "$H/state/discord-workspace/conversation-console/cursors"
out=$(dc listen --config "$CFG" 2>&1) || fail "replay listen failed: $out"
AFTER_ACKS=$(python3 -c "import json;w=json.load(open('$WORLD'));print(len(w['posts'].get('$CH',[])))")
assert_equals "$BEFORE_ACKS" "$AFTER_ACKS" "a replayed capture posts no second acknowledgement"
assert_equals "1" "$(note_count "$H")" "a replayed full-turn capture appends no second note"
pass "a replayed capture posts no second acknowledgement and no second capture"

# --- 4. a failing classifier falls back to the full turn ---------------------
make_home h3 on
CFG3="$H/config/discord-conversation-console.json"
python3 - "$CFG3" "$TMP_ROOT/broken-classifier" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["fast_path"]["classifier_command"] = sys.argv[2]
json.dump(cfg, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
out=$(dc listen --config "$CFG3" 2>&1) || fail "broken-classifier listen failed: $out"
assert_contains "$out" "captured=3" "every message falls back to the full turn"
assert_equals "3" "$(note_count "$H")" "every message still captures a durable note when the classifier fails"
python3 - "$WORLD" "$CH" "$H" <<'PY' || fail "broken-classifier fallback check failed"
import json, os, sys
world, ch, home = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
posts = [m["content"] for m in world.get("posts", {}).get(ch, [])]
assert posts.count("On it - checking the records.") >= 1, "the ack is still posted when the classifier fails"
audits = os.path.join(home, "state", "discord-workspace", "conversation-console", "fast-path", "audits")
paths = [json.load(open(os.path.join(audits, f)))["path"] for f in os.listdir(audits)]
assert set(paths) == {"full_turn"}, f"a failing classifier must record the full turn, saw {paths}"
assert len(paths) == 3, f"every captured message must be audited, saw {len(paths)}"
PY
pass "a failing classifier falls back to the full turn and still acks"

# --- 5. the disabled default leaves the existing capture path unchanged ------
make_home h2 off
CFG2="$H/config/discord-conversation-console.json"
out=$(dc listen --config "$CFG2" 2>&1) || fail "disabled fast-path listen failed: $out"
assert_contains "$out" "captured=3" "the disabled fast path still captures every message"
assert_equals "3" "$(note_count "$H")" "the disabled fast path captures exactly one note per message"
python3 - "$WORLD" "$H" <<'PY' || fail "disabled fast path must post nothing"
import json, os, sys
world, home = json.load(open(sys.argv[1])), sys.argv[2]
fast = os.path.join(home, "state", "discord-workspace", "conversation-console", "fast-path")
assert not os.path.isdir(fast) or not any(os.scandir(fast)), "the disabled fast path writes no fast-path records"
PY
pass "the disabled default leaves the existing capture path unchanged"

# --- 6. status reports the fast path and the last route ----------------------
out=$(dc status --config "$CFG" 2>&1) || fail "status failed: $out"
assert_contains "$out" "fast path: on" "status reports the fast path switch"
assert_contains "$out" "fast-path audited messages:" "status reports the audited message count"
assert_not_contains "$out" "$FAKE_TOKEN" "status never prints the token"
pass "status reports the fast path and its audit"

# --- 7. the typing indicator follows the full turn, never the fast path ------
# A fresh home sees every message as a full turn (the classifier fails), so the
# keeper must be alive for both the channel and the thread, stop when the answer
# is posted, and never appear for the immediate fast path proven in case 1.
start_typesafe fast_answer 0.4
make_home h4 on
CFG4="$H/config/discord-conversation-console.json"
TYPING_FROM=$(python3 -c "import json;print(len(json.load(open('$WORLD')).get('typing', [])))")
out=$(dc listen --config "$CFG4" 2>&1) || fail "typing listen failed: $out"
for _ in $(seq 1 100); do
  TYPING_OK=$(python3 - "$WORLD" "$TYPING_FROM" "$CH" "$T1" <<'PY'
import json, sys
world, before, ch, t1 = json.load(open(sys.argv[1])), int(sys.argv[2]), sys.argv[3], sys.argv[4]
channels = {entry["channel_id"] for entry in world.get("typing", [])[before:]}
print("ok" if {ch, t1} <= channels else "wait")
PY
)
  [ "$TYPING_OK" = "ok" ] && break
  sleep 0.1
done
assert_equals "ok" "$TYPING_OK" "a full-turn message starts typing in its channel and its thread"
assert_present "$H/state/discord-workspace/conversation-console/typing/$CH.json" "the channel has a live typing marker"
assert_present "$H/state/discord-workspace/conversation-console/typing/$T1.json" "the thread has a live typing marker"

# The answer stops the keeper: the marker goes and the loop ends.
printf 'The answer that ends the turn\n' > "$TMP_ROOT/typing-answer.txt"
out=$(dc reply --config "$CFG4" --request-id "discord:$GUILD:$CH:666000000000000100" --text-file "$TMP_ROOT/typing-answer.txt" 2>&1) \
  || fail "typing-stop reply failed: $out"
assert_absent "$H/state/discord-workspace/conversation-console/typing/$CH.json" "the reply removes the channel typing marker"
for _ in $(seq 1 100); do
  pgrep -f "typing --config $CFG4 --channel $CH" >/dev/null 2>&1 || break
  sleep 0.1
done
if pgrep -f "typing --config $CFG4 --channel $CH" >/dev/null 2>&1; then
  fail "the channel typing keeper did not stop after the reply"
fi
out=$(dc typing --config "$CFG4" --channel "$T1" --stop 2>&1) || fail "typing --stop failed: $out"
assert_absent "$H/state/discord-workspace/conversation-console/typing/$T1.json" "typing --stop removes the thread marker"
assert_contains "$(dc status --config "$CFG4" 2>&1)" "typing keepers active: 0" "status reports no active typing keeper once stopped"
pass "the typing indicator is bounded to a full turn and stops with the answer"

# --- 8. a blocked-specific question answers from the reconciled per-task state -
start_typesafe fast_answer 0.97
python3 - "$WORLD" "$CH" "$CAPTAIN" <<'PY'
import json, sys
world, ch, captain = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
world["messages"][ch].append({"id": "666000000000000102", "content": "which tasks are blocked", "author": {"id": captain}, "channel_id": ch})
json.dump(world, open(sys.argv[1], "w"))
PY
make_home h5 on
CFG5="$H/config/discord-conversation-console.json"
out=$(dc listen --config "$CFG5" 2>&1) || fail "blocked-question listen failed: $out"
BLOCKED_OK=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
world, ch = json.load(open(sys.argv[1])), sys.argv[2]
answers = [m["content"] for m in world.get("posts", {}).get(ch, []) if "Blocked" in m["content"] or "In flight" in m["content"]]
ok = any("Blocked right now:" in a and "task-b" in a and "task-a" not in a for a in answers)
print("ok" if ok else f"bad:{answers}")
PY
)
assert_equals "ok" "$BLOCKED_OK" "a blocked question lists the blocked task, not the in-flight list"
pass "a blocked question is answered from the reconciled per-task state"

# --- 9. an ignored message starts no keeper and posts nothing ----------------
# A fresh home that watches only a channel the captain does not own: the only
# message is ignored, so no acknowledgement, no answer, and no typing at all.
H="$TMP_ROOT/h6"
mkdir -p "$H/state" "$H/data" "$H/config"
chmod 700 "$H/state"
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
python3 - "$H/config/discord-conversation-console.json" "$GUILD" "$BOT" "$CAPTAIN" "$CH2" <<'PY'
import json, sys
path, guild, bot, captain, channel = sys.argv[1:6]
data = json.load(open(path))
data["bot"]["user_id"] = bot
data["captain_user_ids"] = [captain]
data["channels"] = [{"label": "Internal", "guild_id": guild, "channel_id": channel}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["fast_path"]["enabled"] = True
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
printf '# Backlog\n\n## In flight\n' > "$H/data/backlog.md"
CFG6="$H/config/discord-conversation-console.json"
TYPING_BEFORE=$(python3 -c "import json;print(len(json.load(open('$WORLD')).get('typing', [])))")
out=$(dc listen --config "$CFG6" 2>&1) || fail "ignored-message listen failed: $out"
assert_equals "0" "$(note_count "$H")" "an ignored message captures no note"
assert_equals "$TYPING_BEFORE" "$(python3 -c "import json;print(len(json.load(open('$WORLD')).get('typing', [])))")" "an ignored message starts no typing keeper"
assert_absent "$H/state/discord-workspace/conversation-console/typing/$CH2.json" "an ignored message writes no typing marker"
assert_absent "$H/state/discord-workspace/conversation-console/fast-path/decisions" "an ignored message writes no fast-path decision"
pass "an ignored message starts no keeper and posts nothing"

# --- 10. the acknowledgement switch off posts no ack but keeps typing --------
# A fresh home turns the acknowledgement off while leaving typing on. Every
# message is a full turn (the classifier is uncertain), so the typing keeper
# must still start while no acknowledgement message is posted.
ACK_TEXT="On it - checking the records."
start_typesafe fast_answer 0.4
make_home h7 on
CFG7="$H/config/discord-conversation-console.json"
python3 - "$CFG7" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["fast_path"]["acknowledgement_enabled"] = False
json.dump(cfg, open(path, "w"), indent=2, sort_keys=True)
PY
ACKS_BEFORE=$(python3 - "$WORLD" "$CH" "$ACK_TEXT" <<'PY'
import json, sys
world, ch, ack = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
print(sum(1 for m in world.get("posts", {}).get(ch, []) if m["content"] == ack))
PY
)
TYPING_BEFORE=$(python3 -c "import json;print(len(json.load(open('$WORLD')).get('typing', [])))")
out=$(dc listen --config "$CFG7" 2>&1) || fail "ack-off listen failed: $out"
for _ in $(seq 1 100); do
  TYPING_OFF_OK=$(python3 - "$WORLD" "$TYPING_BEFORE" "$CH" "$T1" <<'PY'
import json, sys
world, before, ch, t1 = json.load(open(sys.argv[1])), int(sys.argv[2]), sys.argv[3], sys.argv[4]
channels = {entry["channel_id"] for entry in world.get("typing", [])[before:]}
print("ok" if {ch, t1} <= channels else "wait")
PY
)
  [ "$TYPING_OFF_OK" = "ok" ] && break
  sleep 0.1
done
assert_equals "ok" "$TYPING_OFF_OK" "typing still appears when the acknowledgement is off"
ACKS_AFTER=$(python3 - "$WORLD" "$CH" "$ACK_TEXT" <<'PY'
import json, sys
world, ch, ack = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
print(sum(1 for m in world.get("posts", {}).get(ch, []) if m["content"] == ack))
PY
)
assert_equals "$ACKS_BEFORE" "$ACKS_AFTER" "the acknowledgement switch off posts no acknowledgement"
assert_contains "$(dc status --config "$CFG7" 2>&1)" "fast-path acknowledgement: off" "status reports the acknowledgement switch off"
pass "the acknowledgement switch off posts no acknowledgement and keeps typing"

# --- 11. the acknowledgement defaults on when the switch is absent -----------
# h1's config never names the switch, so the default must be the old behaviour.
out=$(dc config-check --config "$CFG" 2>&1) || fail "default config-check failed: $out"
assert_contains "$out" "fast-path acknowledgement: on" "the acknowledgement defaults on when the switch is absent"
assert_contains "$out" "fast-path typing: on" "typing defaults on when the switch is absent"
pass "the acknowledgement defaults on when the switch is absent"

# --- 12. disabling both visible activity signs is refused --------------------
make_home h8 on
CFG8="$H/config/discord-conversation-console.json"
python3 - "$CFG8" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["fast_path"]["acknowledgement_enabled"] = False
cfg["fast_path"]["typing"] = False
json.dump(cfg, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(dc config-check --config "$CFG8" 2>&1)
rc=$?
[ "$rc" -ne 0 ] || fail "a config disabling both the acknowledgement and typing must be refused"
assert_contains "$out" "at least one visible sign" "the refusal names the missing visible activity"
pass "disabling both the acknowledgement and typing is refused"

printf '# all fm-discord-console-fast-path tests passed\n'
