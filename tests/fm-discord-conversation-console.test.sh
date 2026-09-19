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
  [ -n "${GW_PID:-}" ] && kill "$GW_PID" 2>/dev/null || true
  [ -n "${GW_CLIENT_PID:-}" ] && kill "$GW_CLIENT_PID" 2>/dev/null || true
  local home
  for home in "${H:-}" "${H2:-}" "${H3:-}"; do
    [ -n "$home" ] && FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
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
        if len(parts) >= 2 and parts[0] == "interactions":
            world.setdefault("interaction_callbacks", []).append({"path": url.path, "body": body})
            save(world)
            self._send(200, {})
            return
        if len(parts) >= 2 and parts[0] == "webhooks":
            # A refusal or the free-form option answers as a follow-up message
            # through the interaction webhook, never as a second callback.
            world.setdefault("interaction_followups", []).append({"path": url.path, "body": body})
            save(world)
            self._send(200, {})
            return
        if not self._authorized(world):
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 3 and parts[2] == "messages":
            if body.get("allowed_mentions") != {"parse": []}:
                self._send(400, {"message": "allowed_mentions must be empty parse"})
                return
            world["counter"] = int(world.get("counter", 900000000000000000)) + 1
            message = {"id": str(world["counter"]), "content": body.get("content"),
                       "components": body.get("components"),
                       "author": {"id": BOT, "bot": True}, "channel_id": parts[1]}
            world.setdefault("posts", {}).setdefault(parts[1], []).append(message)
            save(world)
            self._send(200, message)
        else:
            self._send(404, {"message": "not found"})

    def do_PATCH(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            body = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            body = {}
        if len(parts) == 5 and parts[0] == "webhooks" and parts[3] == "messages":
            world = load()
            world.setdefault("interaction_edits", []).append({"path": url.path, "body": body})
            save(world)
            self._send(200, {"id": "0", "content": body.get("content")})
            return
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
assert_contains "$NOTES" "keep the answer short:" "a note asks for a short captain-facing answer"
IGNORED_OK=$(python3 - "$H" <<'PY'
import json, sys
data = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/ignored.json"))
reasons = {r["message_id"]: r["reason"] for r in data["records"]}
print("ok" if reasons.get("666000000000000101") == "unknown-author" and reasons.get("666000000000000102") == "bot-author" else f"bad:{reasons}")
PY
)
assert_equals "ok" "$IGNORED_OK" "non-captain and bot messages are recorded as ignored"
pass "captain messages are captured and non-captain messages ignored"

# --- 1b. the latency journal records every stage it can observe ----------------
LATENCY_JSON=$(dc latency --config "$CFG" --json 2>&1) || fail "latency failed: $LATENCY_JSON"
LATENCY_OK=$(printf '%s' "$LATENCY_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
rows = data["rows"]
ok = (
    len(rows) >= 3
    and all(r["transport"] == "polling" for r in rows)
    and all(r["stage1_discord_to_console"] is not None for r in rows)
    and all(r["stage2_console_handling"] is not None for r in rows)
)
print("ok" if ok else "bad:" + json.dumps(rows))
')
assert_equals "ok" "$LATENCY_OK" "the latency journal records transport and the console stages"
pass "the latency journal records per-stage timings"

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

# --- 4b. the reply path renders the presentation shape and enforces the bound --
cat > "$TMP_ROOT/shape.txt" <<'TXT'
Fix landed
- Merged https://github.com/example/repo/pull/1
- Checks green

Next
Waiting on your review.
TXT
out=$(dc reply --config "$CFG" --channel "$CH" --text-file "$TMP_ROOT/shape.txt" --nonce shape-test 2>&1) \
  || fail "shape reply failed: $out"
SHAPE_OK=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
world, ch = json.load(open(sys.argv[1])), sys.argv[2]
content = world.get("posts", {}).get(ch, [])[-1]["content"]
expected = (
    "**Fix landed**\n- Merged https://github.com/example/repo/pull/1\n- Checks green\n\n"
    "**Next**\nWaiting on your review."
)
print("ok" if content == expected else f"bad:{content!r}")
PY
)
assert_equals "ok" "$SHAPE_OK" "the reply renders a bold label, bullets, a section blank line, and an intact URL"

# A single plain sentence is not bolded, so ordinary answers stay unchanged.
printf 'Answer for the first conversation\n' > "$TMP_ROOT/shape-plain.txt"
out=$(dc reply --config "$CFG" --channel "$CH" --text-file "$TMP_ROOT/shape-plain.txt" --nonce shape-plain 2>&1) \
  || fail "plain shape reply failed: $out"
PLAIN_OK=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
content = json.load(open(sys.argv[1])).get("posts", {}).get(sys.argv[2], [])[-1]["content"]
print("ok" if content == "Answer for the first conversation" else f"bad:{content!r}")
PY
)
assert_equals "ok" "$PLAIN_OK" "a plain one-line answer is not bolded"

# A reply longer than the configured bound is cut to the bound with an ellipsis.
python3 - "$TMP_ROOT/shape-long.txt" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write("Long answer\n")
    for i in range(60):
        f.write(f"- item {i} with a lot of words to push the answer past the bound\n")
PY
out=$(dc reply --config "$CFG" --channel "$CH" --text-file "$TMP_ROOT/shape-long.txt" --nonce shape-long 2>&1) \
  || fail "long shape reply failed: $out"
LONG_OK=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
content = json.load(open(sys.argv[1])).get("posts", {}).get(sys.argv[2], [])[-1]["content"]
ok = len(content) <= 1900 and content.endswith("\u2026")
print("ok" if ok else f"bad:len={len(content)} end={content[-12:]!r}")
PY
)
assert_equals "ok" "$LONG_OK" "a reply past the bound is cut to 1900 characters with an ellipsis"
pass "the reply path renders the presentation shape and enforces the bound"

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

# --- 8. the permanent gateway connection ------------------------------------
# A fake Discord gateway websocket stands in for the real one. It records the
# IDENTIFY payload (so the test can prove an online presence), then forces a
# disconnect and re-delivers the same message on the resumed connection, so the
# test proves both automatic reconnection and exactly-once capture.
GW_PORT_FILE="$TMP_ROOT/gw-port"
cat > "$TMP_ROOT/fake-gateway.py" <<'PY'
import base64, hashlib, json, os, socket, struct, sys, threading, time
WORLD, PORT_FILE, GUILD, BOT, CH = sys.argv[1:6]
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def load():
    with open(WORLD, encoding="utf-8") as f:
        return json.load(f)

def save_atomic(world):
    tmp = WORLD + ".gw.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(world, f)
    os.replace(tmp, WORLD)

def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf

def read_frame(conn):
    b1, b2 = recv_exact(conn, 2)
    opcode = b1 & 0x0F
    masked = b2 & 0x80
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack(">H", recv_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", recv_exact(conn, 8))[0]
    mask = recv_exact(conn, 4) if masked else b""
    payload = recv_exact(conn, length) if length else b""
    if mask:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    return opcode, payload

def send_frame(conn, opcode, payload):
    header = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header += struct.pack(">H", n)
    else:
        header.append(127)
        header += struct.pack(">Q", n)
    conn.sendall(bytes(header) + payload)

def send_json(conn, obj):
    send_frame(conn, 1, json.dumps(obj).encode())

def handshake(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("closed during handshake")
        data += chunk
    head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1")
    headers = {}
    for line in head.split("\r\n")[1:]:
        key, _, value = line.partition(":")
        headers[key.strip().lower()] = value.strip()
    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
    conn.sendall((
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    ).encode())

def record(key, value):
    world = load()
    world[key] = value
    world["connections"] = int(world.get("connections", 0)) + 1
    save_atomic(world)

def handle(conn, port):
    try:
        handshake(conn)
        send_json(conn, {"op": 10, "d": {"heartbeat_interval": 45000}})
        while True:
            opcode, payload = read_frame(conn)
            if opcode == 8:
                return
            if opcode == 9:
                send_frame(conn, 10, payload)
                continue
            if opcode != 1:
                continue
            message = json.loads(payload)
            if message.get("op") == 2:
                record("identify", message)
                send_json(conn, {"op": 0, "t": "READY", "s": 1, "d": {"session_id": "sess1", "resume_gateway_url": f"ws://127.0.0.1:{port}/gateway", "user": {"id": BOT}}})
                break
            if message.get("op") == 6:
                record("resume", message)
                send_json(conn, {"op": 0, "t": "RESUMED", "s": 2, "d": {}})
                break
        for dispatch in load().get("dispatch", []):
            send_json(conn, {"op": 0, "t": "MESSAGE_CREATE", "s": 3, "d": dispatch})
        for interaction in load().get("interactions", []):
            send_json(conn, {"op": 0, "t": "INTERACTION_CREATE", "s": 4, "d": interaction})
        time.sleep(float(load().get("hold_seconds", 0.2)))
        try:
            send_frame(conn, 8, struct.pack(">H", 1000))
        except OSError:
            pass
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        conn.close()

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(8)
    port = server.getsockname()[1]
    with open(PORT_FILE, "w", encoding="utf-8") as f:
        f.write(str(port))
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle, args=(conn, port), daemon=True).start()

main()
PY
setsid python3 "$TMP_ROOT/fake-gateway.py" "$WORLD" "$GW_PORT_FILE" "$GUILD" "$BOT" "$CH" > "$TMP_ROOT/fake-gateway.log" 2>&1 &
GW_PID=$!
for _ in $(seq 1 50); do
  [ -s "$GW_PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$GW_PORT_FILE" ] || fail "fake gateway did not start"
GW_PORT=$(cat "$GW_PORT_FILE")
python3 - "$WORLD" "$GUILD" "$CH" "$T1" "$T2" "$CAPTAIN" "$STRANGER" <<'PY'
import json, sys
world_path, guild, ch, t1, t2, captain, stranger = sys.argv[1:8]
world = json.load(open(world_path))
world["channels"] = {
    ch: {"id": ch, "type": 0, "guild_id": guild},
    t1: {"id": t1, "type": 11, "parent_id": ch, "guild_id": guild},
}
world["dispatch"] = [
    {"id": "666000000000000100", "content": "Hello from the captain", "author": {"id": captain}, "channel_id": ch, "guild_id": guild, "timestamp": "2026-09-18T00:00:00Z"},
    {"id": "666000000000000101", "content": "Not the captain", "author": {"id": stranger}, "channel_id": ch, "guild_id": guild},
    {"id": "666000000000000102", "content": "Guild-shaped captain message", "member": {"user": {"id": captain}}, "channel_id": ch, "guild_id": guild},
    {"id": "666000000000000200", "content": "First conversation", "author": {"id": captain}, "channel_id": t1, "guild_id": guild},
]
world["hold_seconds"] = 0.2
world["connections"] = 0
json.dump(world, open(world_path, "w"))
PY
export FM_DISCORD_LIVE_GATEWAY_URL="ws://127.0.0.1:$GW_PORT/gateway"
H2="$TMP_ROOT/h2"
mkdir -p "$H2/state" "$H2/data" "$H2/config"
chmod 700 "$H2/state"
FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H2/config/discord-conversation-console.json"
python3 - "$H2/config/discord-conversation-console.json" "$GUILD" "$BOT" "$CAPTAIN" "$CH" <<'PY'
import json, sys
path, guild, bot, captain, ch = sys.argv[1:6]
data = json.load(open(path))
data["bot"]["user_id"] = bot
data["captain_user_ids"] = [captain]
data["channels"] = [{"label": "Internal", "guild_id": guild, "channel_id": ch}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["live"]["gateway"] = True
data["gateway"]["fallback_after_attempts"] = 1
data["gateway"]["backoff_base_seconds"] = 0.1
data["gateway"]["backoff_max_seconds"] = 0.2
data["gateway"]["fallback_poll_seconds"] = 0.2
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H2/config/discord-workspace.secrets.sops.yaml"
CFG2="$H2/config/discord-conversation-console.json"
FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" connect --config "$CFG2" --max-seconds 4 > "$TMP_ROOT/h2-connect.log" 2>&1 &
GW_CLIENT_PID=$!
for _ in $(seq 1 150); do
  conns=$(python3 -c "import json;print(json.load(open('$WORLD')).get('connections',0))")
  notes=$(note_count "$H2")
  [ "$conns" -ge 2 ] && [ "$notes" -ge 3 ] && break
  sleep 0.1
done
kill "$GW_CLIENT_PID" 2>/dev/null || true
wait "$GW_CLIENT_PID" 2>/dev/null || true
GW_OK=$(python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
identify = world.get("identify") or {}
params = identify.get("d") or {}
presence = params.get("presence") or {}
resume = world.get("resume") or {}
ok = (
    presence.get("status") == "online"
    and params.get("intents") == 33281
    and isinstance(resume.get("d"), dict)
    and int(world.get("connections", 0)) >= 2
)
print("ok" if ok else f"bad:{json.dumps({'presence': presence.get('status'), 'intents': params.get('intents'), 'resume': bool(resume), 'connections': world.get('connections')})}")
PY
)
assert_equals "ok" "$GW_OK" "the connection identifies with an online presence and resumes after a forced disconnect"
assert_equals "3" "$(note_count "$H2")" "re-delivery after reconnect appends no second note and a guild-shaped message is captured"
GW_IGNORED=$(python3 - "$H2" <<'PY'
import json, sys
data = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/ignored.json"))
records = [r for r in data["records"] if r["message_id"] == "666000000000000101"]
print("ok" if len(records) == 1 and records[0]["reason"] == "unknown-author" else f"bad:{records}")
PY
)
assert_equals "ok" "$GW_IGNORED" "a non-captain message is ignored once in connection mode"
CONN_MODE=$(python3 - "$H2" <<'PY'
import json, sys
record = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/connection.json"))
print(record.get("mode"))
PY
)
assert_equals "gateway" "$CONN_MODE" "status records the settled gateway mode"
GW_LATENCY=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" latency --config "$CFG2" --json 2>&1) \
  || fail "gateway latency failed: $GW_LATENCY"
GW_TRANSPORT_OK=$(printf '%s' "$GW_LATENCY" | python3 -c '
import json, sys
data = json.load(sys.stdin)
rows = data["rows"]
gateway_rows = [r for r in rows if r["transport"] == "gateway"]
ok = len(gateway_rows) >= 2 and all(r["stage1_discord_to_console"] is not None for r in gateway_rows)
print("ok" if ok else "bad:" + json.dumps(rows))
')
assert_equals "ok" "$GW_TRANSPORT_OK" "the journal proves the gateway delivered the captures"
printf 'Answer to the gateway message\n' > "$TMP_ROOT/gw-answer.txt"
out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" reply --config "$CFG2" --request-id "discord:$GUILD:$T1:666000000000000200" --text-file "$TMP_ROOT/gw-answer.txt" 2>&1) \
  || fail "gateway thread reply failed: $out"
assert_contains "$out" "replied in conversation $T1" "a connection-captured thread message is answered in its thread"
GW_STATUS=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" status --config "$CFG2" 2>&1)
assert_contains "$GW_STATUS" "connection mode: gateway" "status reports the permanent connection mode"
assert_contains "$GW_STATUS" "connection state: connected" "status reports the connection as connected"
printf '%s' "$(cat "$TMP_ROOT/h2-connect.log")" | grep -q "$FAKE_TOKEN" && fail "the token leaked into the connection log"
pass "the permanent connection appears online, reconnects, and captures exactly once"

# --- 9. polling is preserved as the fallback ---------------------------------
# The gateway is unreachable here, so the console must keep answering through
# the existing polling pass rather than going silent.
world_set '{"token":null}'
H3="$TMP_ROOT/h3"
mkdir -p "$H3/state" "$H3/data" "$H3/config"
chmod 700 "$H3/state"
FM_HOME="$H3" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H3/config/discord-conversation-console.json"
python3 - "$H3/config/discord-conversation-console.json" "$GUILD" "$BOT" "$CAPTAIN" "$CH" <<'PY'
import json, sys
path, guild, bot, captain, ch = sys.argv[1:6]
data = json.load(open(path))
data["bot"]["user_id"] = bot
data["captain_user_ids"] = [captain]
data["channels"] = [{"label": "Internal", "guild_id": guild, "channel_id": ch}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["live"]["gateway"] = True
data["gateway"]["url"] = "ws://127.0.0.1:1/gateway"
data["gateway"]["fallback_after_attempts"] = 1
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H3/config/discord-workspace.secrets.sops.yaml"
CFG3="$H3/config/discord-conversation-console.json"
out=$(env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-discord-conversation-console.sh" connect --config "$CFG3" --once 2>&1) \
  || fail "gateway fallback failed: $out"
assert_equals "3" "$(note_count "$H3")" "the unreachable connection falls back to polling and captures the captain messages"
FB_MODE=$(python3 - "$H3" <<'PY'
import json, sys
record = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/connection.json"))
print(record.get("mode"))
PY
)
assert_equals "polling-fallback" "$FB_MODE" "the connection record names the polling fallback"
FB_GAPS=$(python3 - "$H3" <<'PY'
import json, sys
record = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/delivery-gaps.json"))
gaps = record.get("gaps", [])
print("ok" if any(g.get("kind") == "gateway-fallback" for g in gaps) else f"bad:{gaps}")
PY
)
assert_equals "ok" "$FB_GAPS" "the fallback to polling is recorded as a visible delivery gap"
FB_STATUS=$(env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-discord-conversation-console.sh" status --config "$CFG3" 2>&1)
assert_contains "$FB_STATUS" "connection mode: polling-fallback" "status says it fell back to polling"
# A subsequent polling pass on the same home must not append a second note for a
# message the fallback already captured.
out=$(FM_HOME="$H3" "$ROOT/bin/fm-discord-conversation-console.sh" listen --config "$CFG3" 2>&1) \
  || fail "fallback polling replay failed: $out"
assert_equals "3" "$(note_count "$H3")" "polling and the connection converge on one capture per message"
pass "an unreachable connection falls back to polling with no duplicate capture"

# --- 10. start and stop select exactly one transport -------------------------
out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" start --config "$CFG2" 2>&1) \
  || fail "gateway start failed: $out"
assert_present "$H2/state/procevent/discord-conversation-console-gateway.source" "start registers the permanent connection source"
assert_absent "$H2/state/procevent/discord-conversation-console.source" "start does not also register the polling source"
out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" status --config "$CFG2" 2>&1)
assert_contains "$out" "health: healthy" "status reports a live registered connection as healthy"
out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" stop --config "$CFG2" 2>&1) \
  || fail "gateway stop failed: $out"
assert_absent "$H2/state/procevent/discord-conversation-console-gateway.source" "stop retires the permanent connection source"
pass "start and stop select one transport through the process-event service pattern"

# --- 11. the service pattern launches and relaunches the connection daemon ----
# The watcher's process-event reconcile owns supervision: it launches the
# registered connection daemon and, after that daemon crashes, launches a fresh
# one rather than leaving the console unmonitored.
out=$(env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-discord-conversation-console.sh" start --config "$CFG3" 2>&1) \
  || fail "service-pattern start failed: $out"
env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
for _ in $(seq 1 100); do
  env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep -q '^discord-conversation-console-gateway .* live' && break
  sleep 0.1
done
LIST_BEFORE=$(env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" list 2>&1)
assert_contains "$LIST_BEFORE" "live" "the registered connection is supervised and live"
GW_DAEMON_PID=''
for _ in $(seq 1 100); do
  GW_DAEMON_PID=$(pgrep -f "fm_discord_conversation_console_lib.py procevent .* gateway --config $CFG3" | head -1)
  [ -n "$GW_DAEMON_PID" ] && break
  sleep 0.1
done
[ -n "$GW_DAEMON_PID" ] || fail "could not find the supervised connection daemon"
kill -9 "$GW_DAEMON_PID" 2>/dev/null || true
for _ in $(seq 1 100); do
  env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep -q '^discord-conversation-console-gateway .* live' || break
  sleep 0.1
done
RECONCILE_OUT=$(env -u FM_DISCORD_LIVE_GATEWAY_URL FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" reconcile 2>&1) \
  || fail "post-crash reconcile failed: $RECONCILE_OUT"
assert_contains "$RECONCILE_OUT" "started=1" "a crashed connection daemon is launched again"
out=$(FM_HOME="$H3" "$ROOT/bin/fm-discord-conversation-console.sh" stop --config "$CFG3" 2>&1) \
  || fail "service-pattern stop failed: $out"
pass "the service pattern launches the connection daemon and relaunches it after a crash"

# --- 12. action cards post buttons and record a press -----------------------
# A card is one message carrying a components array; each press arrives as a
# gateway INTERACTION_CREATE dispatch, is answered through Discord's interaction
# callback, and records the option's exact value through the real keyed-answer
# intake. This drives the whole path against the loopback fakes.
if ! command -v tasks-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skip: tasks-axi and jq are required to exercise the action-card intake"
else
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" start --config "$CFG2" 2>&1) \
    || fail "card gateway start failed: $out"

  # The card's task is a real task held for the captain in this home's backlog.
  cp "$ROOT/.tasks.toml" "$H2/.tasks.toml"
  cat > "$H2/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  CARD_TASK=card-decision-test
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-captain-hold.sh" hold "$CARD_TASK" --title "Discord card test" --reason "Choose the card option" --repo firstmate 2>&1) \
    || fail "holding the card task failed: $out"

  cat > "$TMP_ROOT/card.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "card-decision-test",
  "body": "Le correctif est pret. On merge ?",
  "fallback_hint": "Ou reponds directement dans la conversation.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "Oui, vas-y."},
    {"label": "Non", "action": "answer", "value": "Non, pas encore."},
    {"label": "Plus tard", "action": "later", "until": "2026-10-01"},
    {"label": "En chat", "action": "chat"}
  ]
}
JSON
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" card --config "$CFG2" --channel "$CH" --card-file "$TMP_ROOT/card.json" --nonce card-test 2>&1) \
    || fail "card post failed: $out"
  assert_contains "$out" "card posted in conversation $CH" "the card reports its conversation"
  assert_contains "$out" "card url: https://discord.com/channels/$GUILD/$CH/" "the card reports its real message URL"

  CARD_ID=$(python3 - "$H2" <<'PY'
import glob, json, sys
print(json.load(open(glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")[0]))["card_id"])
PY
)
  CARD_MSG=$(python3 - "$H2" <<'PY'
import glob, json, sys
print(json.load(open(glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")[0]))["message_id"])
PY
)
  POSTED_OK=$(python3 - "$WORLD" "$CH" "$CARD_MSG" <<'PY'
import json, sys
world, ch, message_id = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
posted = [m for m in world.get("posts", {}).get(ch, []) if m["id"] == message_id]
rows = posted[0].get("components") if posted else None
buttons = rows[0].get("components") if rows and rows[0].get("type") == 1 else []
labels = [b.get("label") for b in buttons or []]
custom_ids = [str(b.get("custom_id")) for b in buttons or []]
ok = labels == ["Oui", "Non", "Plus tard", "En chat"] and all(c.startswith("fmcard:") for c in custom_ids)
print("ok" if ok else "bad:" + json.dumps(posted))
PY
)
  assert_equals "ok" "$POSTED_OK" "the card posts one row of labelled option buttons"
  pass "the console posts an action card with labelled option buttons"

  # Six presses plus an unidentified one: the free-form option, one decisive
  # answer, that same press delivered twice, a non-captain, an unknown card, an
  # unknown button, and a payload carrying no identity at all. Every payload is
  # guild-shaped (member.user, no top-level user), which is the real shape that
  # broke the captain's first press.
  python3 - "$WORLD" "$GUILD" "$CH" "$CAPTAIN" "$STRANGER" "$BOT" "$CARD_ID" "$CARD_MSG" <<'PY'
import json, sys
world_path, guild, ch, captain, stranger, bot, card_id, message_id = sys.argv[1:9]

def press(iid, user, custom_id, token):
    payload = {
        "id": iid, "application_id": bot, "type": 3, "token": token,
        "guild_id": guild, "channel_id": ch,
        "data": {"custom_id": custom_id, "component_type": 2},
        "message": {"id": message_id, "channel_id": ch},
    }
    if user is not None:
        payload["member"] = {"user": {"id": user}}
    return payload

world = json.load(open(world_path))
world["dispatch"] = []
world["interactions"] = [
    press("999000000000000005", captain, f"fmcard:{card_id}:3", "tok-chat"),
    press("999000000000000001", captain, f"fmcard:{card_id}:0", "tok-answer"),
    press("999000000000000001", captain, f"fmcard:{card_id}:0", "tok-answer"),
    press("999000000000000002", stranger, f"fmcard:{card_id}:1", "tok-stranger"),
    press("999000000000000003", captain, "fmcard:00000000000000ff:0", "tok-unknown-card"),
    press("999000000000000004", captain, "fmcard:nothex:0", "tok-unknown-custom"),
    press("999000000000000007", None, f"fmcard:{card_id}:1", "tok-unidentified"),
]
json.dump(world, open(world_path, "w"))
PY
  FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" connect --config "$CFG2" --once > "$TMP_ROOT/h2-cards.log" 2>&1 \
    || fail "card interaction run failed: $(cat "$TMP_ROOT/h2-cards.log")"

  assert_grep "Resolution recorded by fm-captain-hold." "$H2/data/backlog.md" "a press records a resolution through the keyed-answer intake"
  assert_grep "Oui, vas-y." "$H2/data/backlog.md" "the recorded answer is the option's exact value"
  RESOLUTIONS=$(grep -cF 'Resolution recorded by fm-captain-hold.' "$H2/data/backlog.md" || true)
  assert_equals "1" "$RESOLUTIONS" "a repeated interaction id records no second answer"
  CARD_STATE=$(python3 - "$H2" <<'PY'
import glob, json, sys
record = json.load(open(glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")[0]))
print(f"{record.get('status')}:{(record.get('answer') or {}).get('label')}")
PY
)
  assert_equals "answered:Oui" "$CARD_STATE" "the card stores the recorded answer"
  pass "a press records the chosen option through the shared keyed-answer intake"

  CALLBACKS_OK=$(python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
callbacks = world.get("interaction_callbacks", [])
per_id = {}
for callback in callbacks:
    interaction_id = callback["path"].split("/")[2]
    per_id[interaction_id] = per_id.get(interaction_id, 0) + 1
deferred = sum(1 for c in callbacks if c["body"].get("type") == 6)
other_callbacks = sum(1 for c in callbacks if c["body"].get("type") != 6)
followups = len(world.get("interaction_followups", []))
disabled = False
for edit in world.get("interaction_edits", []):
    for row in edit["body"].get("components") or []:
        buttons = row.get("components") or []
        if buttons and all(b.get("disabled") for b in buttons):
            disabled = True
ok = (
    deferred == 7 and other_callbacks == 0 and followups == 5
    and per_id.get("999000000000000001") == 2 and disabled
)
print("ok" if ok else "bad:" + json.dumps({"deferred": deferred, "other": other_callbacks, "followups": followups, "per_id": per_id, "disabled": disabled}))
PY
)
  assert_equals "ok" "$CALLBACKS_OK" "every press defers first through the callback, follow-ups answer the rest, and the answered card disables its buttons"
  REFUSED_OK=$(python3 - "$H2" "$WORLD" <<'PY'
import json, sys
base = f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/interactions"
want = {
    "999000000000000002": ("refused", "non-captain"),
    "999000000000000003": ("refused", "unknown-card"),
    "999000000000000004": ("refused", "unknown-custom-id"),
    "999000000000000007": ("unidentified", "missing-user-id"),
}
got = {}
for interaction_id, expected in want.items():
    try:
        record = json.load(open(f"{base}/{interaction_id}.json"))
        got[interaction_id] = (record.get("status"), record.get("reason"))
    except FileNotFoundError:
        got[interaction_id] = None
world = json.load(open(sys.argv[2]))
unidentified_text = [
    (f.get("body") or {}).get("content") or ""
    for f in world.get("interaction_followups", [])
    if f["path"].endswith("/tok-unidentified")
]
refused_status = got.get("999000000000000002")
looks_right = (
    got == want
    and refused_status == ("refused", "non-captain")
    and unidentified_text
    and "Seul le capitaine" not in unidentified_text[0]
)
print("ok" if looks_right else "bad:" + json.dumps({"got": got, "unidentified_text": unidentified_text}))
PY
)
  assert_equals "ok" "$REFUSED_OK" "non-captain and unknown buttons are refused and audited, and a missing identity is distinct"
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" status --config "$CFG2" 2>&1)
  assert_contains "$out" "cards posted: 1" "status reports the posted card"
  assert_contains "$out" "cards open: 0" "status reports the answered card as closed"
  assert_contains "$out" "card interactions recorded: 6" "status reports the recorded interactions"
  pass "every press is answered, deduped, and audited"

  # Focused unit checks over fake interaction payloads: the guild/direct identity
  # fallback, the acknowledgement leaving before any validation, the short
  # non-retried acknowledgement, and the recorded acknowledgement failure.
  # These are the pieces a loopback gateway round trip cannot observe directly.
  python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail "focused interaction checks failed"
import importlib.util, json, os, socket, sys, urllib.request
from pathlib import Path

root, tmp = sys.argv[1], sys.argv[2]
home = Path(tmp) / "focused-home"
(home / "state").mkdir(parents=True, exist_ok=True)
os.environ["FM_HOME"] = str(home)
os.environ["FM_STATE_OVERRIDE"] = str(home / "state")
os.environ["FM_DATA_OVERRIDE"] = str(home / "data")
os.environ["FM_CONFIG_OVERRIDE"] = str(home / "config")

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

fmc = load("fmc_focused", str(Path(root) / "bin" / "fm_discord_conversation_console_lib.py"))
fwl = fmc.fwl

CAPTAIN = "444444444444444444"
BOT = "333333333333333333"
CARD = "a" * 16
GUILD = "111111111111111111"
CH = "666000000000000001"
MSG = "777000000000000001"

class FakeClient:
    def __init__(self, order, fail_ack=False):
        self.order = order
        self.fail_ack = fail_ack
        self.cfg = type("Cfg", (), {"bot_user_id": BOT})()
    def redact(self, text):
        return text
    def interaction_ack(self, interaction_id, token):
        self.order.append("ack")
        if self.fail_ack:
            raise fwl.FMError("ack transport timed out")
    def interaction_followup(self, token, payload):
        self.order.append("followup")
    def interaction_edit_original(self, token, payload):
        self.order.append("edit")

def cfg():
    return type("Cfg", (), {"captain_user_ids": [CAPTAIN], "bot_user_id": BOT})()

env = fwl.Env(str(Path(root) / "bin"))

# 1. Identity fallback: guild payload, direct payload, and none.
assert fmc.payload_user_id({"member": {"user": {"id": CAPTAIN}}}) == CAPTAIN
assert fmc.payload_user_id({"user": {"id": CAPTAIN}}) == CAPTAIN
assert fmc.payload_user_id({"guild_id": GUILD}) == ""

# 2. A guild-shaped MESSAGE_CREATE resolves member.user instead of ignoring it.
channel = fmc.ConsoleChannel({"label": "x", "guild_id": GUILD, "channel_id": CH}, 0)
event = fmc.normalize_message(
    cfg(), channel, CH, "",
    {"id": MSG, "content": "hi", "member": {"user": {"id": CAPTAIN}}}, "gateway",
)
assert event["kind"] == "text" and event["author_id"] == CAPTAIN, event

interactions_dir = home / "state" / "discord-workspace" / "conversation-console" / "cards" / "interactions"
def record_for(interaction_id):
    return json.loads((interactions_dir / f"{interaction_id}.json").read_text())

real_load_card = fmc.load_card
real_store_card = fmc.store_card
real_run_option = fmc.run_card_option

try:
    # 3. The acknowledgement leaves before any validation, file read, or intake.
    order = []
    fmc.load_card = lambda env, card_id: (order.append("load") or {
        "schema": fmc.CARD_SCHEMA, "card_id": card_id, "task_id": "focused-task",
        "guild_id": GUILD, "channel_id": CH, "message_id": MSG, "body": "b",
        "options": [{"label": "Oui", "action": "answer", "value": "v", "style": 1}],
        "status": "open",
    })
    fmc.store_card = lambda env, card: order.append("store")
    fmc.run_card_option = lambda env, task_id, option: (order.append("run"), (0, ""))[1]
    fmc.handle_card_interaction(
        env, cfg(), FakeClient(order), "999000000000000012", "tok", CAPTAIN,
        f"fmcard:{CARD}:0", GUILD, CH, MSG,
    )
    assert order[0] == "ack", order
    assert order.index("load") > 0 and order.index("run") > order.index("load"), order

    # 4. An unidentified press is distinct and never gets the captain-only line.
    order = []
    client = FakeClient(order)
    fmc.handle_card_interaction(
        env, cfg(), client, "999000000000000011", "tok", "",
        f"fmcard:{CARD}:0", GUILD, CH, MSG,
    )
    assert record_for("999000000000000011")["status"] == "unidentified"
    assert record_for("999000000000000011")["reason"] == "missing-user-id"
    assert order[0] == "ack" and "followup" in order, order

    # 5. A failed acknowledgement is recorded with its reason.
    order = []
    fmc.handle_card_interaction(
        env, cfg(), FakeClient(order, fail_ack=True), "999000000000000014", "tok",
        CAPTAIN, "fmcard:nothex:0", GUILD, CH, MSG,
    )
    failed = record_for("999000000000000014")
    assert failed["status"] == "refused" and failed["reason"] == "unknown-custom-id", failed
    assert "ack_error" in failed and failed["ack_error"], failed
finally:
    fmc.load_card = real_load_card
    fmc.store_card = real_store_card
    fmc.run_card_option = real_run_option

# 6. A timed-out interaction request is never retried, and the acknowledgement
#    uses the short acknowledgement bound.
attempts = []
real_urlopen = urllib.request.urlopen
def fake_urlopen(request, timeout=None):
    attempts.append(timeout)
    raise socket.timeout("handshake timed out")
client = object.__new__(fmc.ConsoleClient)
client.token = "tok"
client.cfg = type("Cfg", (), {"bot_user_id": BOT})()
client.client = type("Client", (), {"base": "http://127.0.0.1:1"})()
urllib.request.urlopen = fake_urlopen
try:
    try:
        client.interaction_ack("999000000000000015", "tok")
        raise AssertionError("a timed-out acknowledgement must fail")
    except fwl.FMError:
        pass
    assert len(attempts) == 1, attempts
    assert attempts[0] is not None and attempts[0] <= fmc.CARD_ACK_TIMEOUT_SECONDS, attempts
    attempts.clear()
    try:
        client._interaction_request("PATCH", "/x", {}, timeout=0.5, retry=True)
        raise AssertionError("a timed-out request must fail")
    except fwl.FMError:
        pass
    assert len(attempts) == 1, attempts
finally:
    urllib.request.urlopen = real_urlopen

print("ok - focused interaction checks pass")
PY
  pass "a guild payload and the acknowledgement ordering are covered by focused checks"

  # The "later" option records a dated deferral through the same intake.
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-captain-hold.sh" hold card-later-test --title "Discord later test" --reason "Pick later" --repo firstmate 2>&1) \
    || fail "holding the later card task failed: $out"
  cat > "$TMP_ROOT/card-later.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "card-later-test",
  "body": "On en reparle plus tard ?",
  "options": [
    {"label": "Plus tard", "action": "later", "until": "2026-10-01"}
  ]
}
JSON
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" card --config "$CFG2" --channel "$CH" --card-file "$TMP_ROOT/card-later.json" --nonce card-later 2>&1) \
    || fail "later card post failed: $out"
  python3 - "$WORLD" "$H2" "$GUILD" "$CH" "$CAPTAIN" "$BOT" card-later-test <<'PY'
import glob, json, sys
world_path, home, guild, ch, captain, bot, task_id = sys.argv[1:8]
records = [json.load(open(p)) for p in glob.glob(f"{home}/state/discord-workspace/conversation-console/cards/*.json")]
card = [record for record in records if record["task_id"] == task_id][0]
world = json.load(open(world_path))
world["dispatch"] = []
world["interactions"] = [{
    "id": "999000000000000009", "application_id": bot, "type": 3, "token": "tok-later",
    "guild_id": guild, "channel_id": ch, "user": {"id": captain},
    "data": {"custom_id": f"fmcard:{card['card_id']}:0", "component_type": 2},
    "message": {"id": card["message_id"], "channel_id": ch},
}]
json.dump(world, open(world_path, "w"))
PY
  FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" connect --config "$CFG2" --once > "$TMP_ROOT/h2-later.log" 2>&1 \
    || fail "later card interaction run failed: $(cat "$TMP_ROOT/h2-later.log")"
  assert_grep "hold-until: 2026-10-01" "$H2/data/backlog.md" "the later option records a dated captain deferral"
  pass "a later option defers the task through the shared intake"

  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" card --config "$CFG2" --channel "$CH" --card-file "$TMP_ROOT/card.json" --nonce card-test 2>&1) \
    || fail "card replay failed: $out"
  assert_contains "$out" "no second delivery" "a card replay with the same nonce posts nothing"
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" stop --config "$CFG2" 2>&1) \
    || fail "card gateway stop failed: $out"
  printf '%s\n' '{"schema":"fm-discord-conversation-console.card.v1","task_id":"card-decision-test","body":"Again?","options":[{"label":"Oui","action":"answer","value":"oui"}]}' > "$TMP_ROOT/card2.json"
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" card --config "$CFG2" --channel "$CH" --card-file "$TMP_ROOT/card2.json" --nonce card-test-2 2>&1) \
    && fail "the console posted a card with no registered interaction path" || true
  assert_contains "$out" "permanent connection is not registered" "a card needs the permanent connection registered"
  out=$(FM_HOME="$H2" "$ROOT/bin/fm-discord-conversation-console.sh" card --config "$CFG2" --channel "$CH" --card-file "$TMP_ROOT/card2.json" --nonce card-test-3 --dry-run 2>&1) \
    || fail "the card dry run failed: $out"
  assert_contains "$out" "dry-run only" "the card dry run makes no network call"
  pass "a card is refused on any path that cannot receive an interaction"
fi
