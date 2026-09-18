#!/usr/bin/env bash
# Behavior tests for the Discord conversation console.
#
# Everything runs against a fake local HTTP Discord server, so no real token is
# read and no network call leaves loopback. Covers exactly-once captain message
# capture across a restart, ignored non-captain messages, thread-scoped replies
# that keep two conversations separate, the side-effect-free status report, and
# the start/stop registration through the repository's process-event pattern.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-conversation-console-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
STRANGER=555555555555555555
CH=666000000000000001
T1=666000000000000011
T2=666000000000000012
FAKE_TOKEN=faketoken-abc123

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }

cleanup_console() {
  kill %1 2>/dev/null || true
  [ -n "${H:-}" ] && FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_console EXIT

start_server() { # start_server <world-file> <port-file>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" "$GUILD" > "$TMP_ROOT/fake-server.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORLD, PORT_FILE, TOKEN, GUILD = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BOT = "333333333333333333"

def load():
    with open(WORLD, encoding="utf-8") as f:
        return json.load(f)

def save(world):
    with open(WORLD, "w", encoding="utf-8") as f:
        json.dump(world, f)

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
            self._send(401, {"message": "Unauthorized", "note": "leak-attempt " + TOKEN})
            return
        if len(parts) == 4 and parts[0] == "guilds" and parts[2] == "threads" and parts[3] == "active":
            self._send(200, {"threads": world.get("threads", {}).get(parts[1], [])})
        elif len(parts) == 5 and parts[0] == "channels" and parts[2:4] == ["threads", "archived"] and parts[4] == "public":
            self._send(200, {"threads": world.get("archived", {}).get(parts[1], [])})
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
        if len(parts) == 3 and parts[2] == "messages":
            if body.get("allowed_mentions") != {"parse": []}:
                self._send(400, {"message": "allowed_mentions must be empty parse"})
                return
            world["counter"] = int(world.get("counter", 900000000000000000)) + 1
            message = {"id": str(world["counter"]), "content": body.get("content"),
                       "author": {"id": BOT, "bot": True}, "channel_id": parts[1]}
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

world_set() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world, update = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
world.update(update)
json.dump(world, open(sys.argv[1], "w"))
PY
}

note_count() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

make_home() { # make_home <name>
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/data" "$H/config"
  chmod 700 "$H/state"
  FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
  python3 - "$H/config/discord-conversation-console.json" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["bot"]["user_id"] = "$BOT"
data["captain_user_ids"] = ["$CAPTAIN"]
data["channels"] = [{"label": "Internal", "guild_id": "$GUILD", "channel_id": "$CH"}]
data["live"]["polling"] = True
data["live"]["posting"] = True
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
}

# --- fake sops + fake server -------------------------------------------------
cat > "$TMP_ROOT/fake-sops" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "-d" ] || exit 64
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: $FAKE_TOKEN\n'
FAKE
chmod +x "$TMP_ROOT/fake-sops"

WORLD="$TMP_ROOT/world.json"
PORT_FILE="$TMP_ROOT/port"
python3 - "$WORLD" "$GUILD" "$CH" "$T1" "$T2" "$CAPTAIN" "$STRANGER" "$BOT" <<'PY'
import json, sys
world_path, guild, ch, t1, t2, captain, stranger, bot = sys.argv[1:9]
world = {
    "token": None,
    "counter": 900000000000000000,
    "threads": {guild: [{"id": t1, "parent_id": ch}, {"id": t2, "parent_id": ch}]},
    "archived": {},
    "messages": {
        ch: [
            {"id": "666000000000000100", "content": "Hello from the captain", "author": {"id": captain}, "channel_id": ch},
            {"id": "666000000000000101", "content": "Not the captain", "author": {"id": stranger}, "channel_id": ch},
            {"id": "666000000000000102", "content": "A bot reply", "author": {"id": bot, "bot": True}, "channel_id": ch},
        ],
        t1: [
            {"id": "666000000000000200", "content": "First conversation", "author": {"id": captain}, "channel_id": t1},
        ],
        t2: [
            {"id": "666000000000000300", "content": "Second conversation", "author": {"id": captain}, "channel_id": t2},
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

make_home h1
CFG="$H/config/discord-conversation-console.json"

# --- 1. captain messages are captured once and non-captains ignored ----------
out=$(dc listen --config "$CFG" 2>&1) || fail "listen failed: $out"
assert_contains "$out" "captured=3" "listen captures the three captain messages"
assert_equals "3" "$(note_count "$H")" "one durable note per accepted captain message"
NOTES=$(cat "$H"/state/inbox/*.note)
assert_contains "$NOTES" "Hello from the captain" "a note preserves the captain message"
assert_contains "$NOTES" "answer with: bin/fm-discord-conversation-console.sh reply --request-id discord:$GUILD:" "a note names the exact reply command"
IGNORED_OK=$(python3 - "$H" <<'PY'
import json, sys
data = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/ignored.json"))
reasons = {r["message_id"]: r["reason"] for r in data["records"]}
print("ok" if reasons.get("666000000000000101") == "unknown-author" and reasons.get("666000000000000102") == "bot-author" else f"bad:{reasons}")
PY
)
assert_equals "ok" "$IGNORED_OK" "non-captain and bot messages are recorded as ignored"
pass "captain messages are captured and non-captain messages ignored"

# --- 2. exactly once across a restart, even with lost cursors ----------------
NOTES_BEFORE=$(note_count "$H")
rm -rf "$H/state/discord-workspace/conversation-console/cursors"
out=$(dc listen --config "$CFG" 2>&1) || fail "second listen failed: $out"
assert_equals "$NOTES_BEFORE" "$(note_count "$H")" "a replay after restart appends no second note for the same message id"
IGNORED_UNIQUE=$(python3 - "$H" <<'PY'
import json, sys
data = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/ignored.json"))
keys = [f'{r["channel_id"]}:{r["message_id"]}' for r in data["records"]]
print("ok" if len(keys) == len(set(keys)) else f"dup:{keys}")
PY
)
assert_equals "ok" "$IGNORED_UNIQUE" "ignored records are not duplicated across a restart"
pass "capture is exactly once across a restart"

# --- 3. replies land in the originating thread and threads stay separate -----
printf 'Answer for the first conversation\n' > "$TMP_ROOT/a1.txt"
printf 'Answer for the second conversation\n' > "$TMP_ROOT/a2.txt"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$T1:666000000000000200" --text-file "$TMP_ROOT/a1.txt" 2>&1) \
  || fail "thread 1 reply failed: $out"
assert_contains "$out" "replied in conversation $T1" "the reply reports its thread"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$T2:666000000000000300" --text-file "$TMP_ROOT/a2.txt" 2>&1) \
  || fail "thread 2 reply failed: $out"
POSTS_OK=$(python3 - "$WORLD" "$T1" "$T2" "$CH" <<'PY'
import json, sys
world, t1, t2, ch = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
posts = world.get("posts", {})
one = [m["content"] for m in posts.get(t1, [])]
two = [m["content"] for m in posts.get(t2, [])]
root = posts.get(ch, [])
ok = one == ["Answer for the first conversation"] and two == ["Answer for the second conversation"] and root == []
print("ok" if ok else f"bad:{posts}")
PY
)
assert_equals "ok" "$POSTS_OK" "each answer lands only in its originating thread"
pass "answers land in the originating thread and two threads stay separate"

# --- 4. a reply to a top-level message goes back to the channel -------------
printf 'Answer in the channel\n' > "$TMP_ROOT/a3.txt"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:666000000000000100" --text-file "$TMP_ROOT/a3.txt" 2>&1) \
  || fail "channel reply failed: $out"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:666000000000000100" --text-file "$TMP_ROOT/a3.txt" 2>&1) \
  || fail "channel replay failed: $out"
assert_contains "$out" "no second delivery" "a replayed reply reads the existing receipt"
printf 'Second channel answer\n' > "$TMP_ROOT/a4.txt"
out=$(dc reply --config "$CFG" --channel "$CH" --text-file "$TMP_ROOT/a4.txt" --nonce channel-a4 2>&1) \
  || fail "explicit channel reply failed: $out"
ROOT_POST_OK=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
world, ch = json.load(open(sys.argv[1])), sys.argv[2]
contents = [m["content"] for m in world.get("posts", {}).get(ch, [])]
print("ok" if contents == ["Answer in the channel", "Second channel answer"] else f"bad:{contents}")
PY
)
assert_equals "ok" "$ROOT_POST_OK" "a message without a thread is answered in its channel, a replay posts nothing"
pass "a channel conversation is answered in its channel"

# --- 5. status is side-effect-free and reports health ------------------------
out=$(dc status --config "$CFG" 2>&1) || fail "status failed: $out"
assert_contains "$out" "health: stopped" "status reports an unregistered listener"
assert_not_contains "$out" "$FAKE_TOKEN" "status never prints the token"
STATUS_BEFORE=$(cat "$H/state/discord-workspace/conversation-console/last-pass.json")
out=$(dc status --config "$CFG" 2>&1)
STATUS_AFTER=$(cat "$H/state/discord-workspace/conversation-console/last-pass.json")
assert_equals "$STATUS_BEFORE" "$STATUS_AFTER" "status changes no durable state"
pass "status is side-effect-free and reports health"

# --- 6. start registers and stop retires the bounded listener ---------------
out=$(dc start --config "$CFG" 2>&1) || fail "start failed: $out"
assert_present "$H/state/procevent/discord-conversation-console.source" "start registers the process-event source"
out=$(dc status --config "$CFG" 2>&1)
assert_contains "$out" "health: healthy" "status reports a registered, enabled listener as healthy"
out=$(dc stop --config "$CFG" 2>&1) || fail "stop failed: $out"
assert_absent "$H/state/procevent/discord-conversation-console.source" "stop retires the process-event source"
SRC_OUT=$(FM_HOME="$H" "$ROOT/bin/fm-procevent-discord-conversation-console.sh" source --config "$CFG" 2>&1)
SRC_RC=$?
expect_code 75 "$SRC_RC" "the adapter source"
assert_equals "" "$SRC_OUT" "a successful source pass is silent so the runner records no-result"
pass "the listener starts and stops through the process-event service pattern"

# --- 7. the token is redacted from a failure path ---------------------------
world_set '{"token":"wrong"}'
out=$(dc listen --config "$CFG" 2>&1) && fail "listen accepted a rejected token" || true
printf '%s' "$out" | grep -q "$FAKE_TOKEN" && fail "the token leaked into failure output: $out"
world_set '{"token":null}'
pass "the bot token is redacted from listener failure output"
