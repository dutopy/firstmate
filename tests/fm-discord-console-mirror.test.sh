#!/usr/bin/env bash
# Behavior tests for the console's native session-mirror delivery path
# (bin/fm-discord-conversation-console.sh mirror).
#
# Everything runs against a fake local HTTP Discord server, so no real token is
# read and no network call leaves loopback. Covers the bounded post, the durable
# item-key receipt that makes a replay post nothing twice, the two identical
# lines from two positions that still post twice, the settled skips (empty item,
# operational text), the config-driven channel and switch, the dry run, and the
# mirror lines in config-check and status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-console-mirror-tests)

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
CH=666000000000000001
OTHER=666000000000000002
FAKE_TOKEN=faketoken-mirror-abc123

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }

cleanup_mirror() {
  kill %1 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_mirror EXIT

world_set() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world, update = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
world.update(update)
json.dump(world, open(sys.argv[1], "w"))
PY
}

post_count() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
print(len(world.get("posts", {}).get(sys.argv[2], [])))
PY
}

post_bodies() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
for message in world.get("posts", {}).get(sys.argv[2], []):
    print(message.get("content"))
PY
}

# One fingerprint of every durable file under a state directory, so a check can
# prove that a read-only command wrote nothing.
state_signature() {
  find "$1" -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s ' "$file"
    cksum < "$file"
  done | cksum
}

start_server() { # start_server <world-file> <port-file>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" > "$TMP_ROOT/fake-server.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

WORLD, PORT_FILE, TOKEN = sys.argv[1], sys.argv[2], sys.argv[3]
BOT = "333333333333333333"


def load():
    with open(WORLD, encoding="utf-8") as handle:
        return json.load(handle)


def save(world):
    with open(WORLD, "w", encoding="utf-8") as handle:
        json.dump(world, handle)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass

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
        if self.headers.get("Authorization") != f"Bot {world.get('token') or TOKEN}":
            self._send(401, {"message": "Unauthorized", "note": "leak-attempt " + TOKEN})
            return
        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "messages":
            if body.get("allowed_mentions") != {"parse": []}:
                self._send(400, {"message": "allowed_mentions must be empty parse"})
                return
            world["counter"] = int(world.get("counter", 900000000000000000)) + 1
            message = {
                "id": str(world["counter"]),
                "content": body.get("content"),
                "author": {"id": BOT, "bot": True},
                "channel_id": parts[1],
            }
            world.setdefault("posts", {}).setdefault(parts[1], []).append(message)
            save(world)
            self._send(200, message)
            return
        self._send(404, {"message": "not found"})

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        world = load()
        if self.headers.get("Authorization") != f"Bot {world.get('token') or TOKEN}":
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "messages":
            self._send(200, world.get("posts", {}).get(parts[1], []))
            return
        self._send(404, {"message": "not found"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_port))
server.serve_forever()
PY
  for _ in $(seq 1 50); do
    [ -s "$2" ] && break
    sleep 0.1
  done
  [ -s "$2" ] || fail "fake Discord server did not start"
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
data["channels"] = [
    {"label": "Firstmate", "guild_id": "$GUILD", "channel_id": "$CH"},
    {"label": "Other", "guild_id": "$GUILD", "channel_id": "$OTHER"},
]
data["live"]["polling"] = False
data["live"]["posting"] = True
data["mirror"] = {"enabled": True, "channel_id": "$CH", "max_chars": 1800}
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
  CFG="$H/config/discord-conversation-console.json"
}

write_item() { # write_item <name> <text>
  printf '%s' "$2" > "$TMP_ROOT/$1"
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
python3 - "$WORLD" <<'PY'
import json, sys
json.dump({"token": None, "counter": 900000000000000000, "posts": {}}, open(sys.argv[1], "w"))
PY
start_server "$WORLD" "$PORT_FILE"
PORT=$(cat "$PORT_FILE")
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0

# --- 1. one item posts once, bounded, through the console identity ----------
make_home h1
write_item item-a.txt "Terminal line one from the captain."
out=$(dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-a.txt" --item-key "sess1:3" --tag captain 2>&1) \
  || fail "mirror post failed: $out"
assert_contains "$out" "receipt recorded" "the mirror records a receipt"
assert_contains "$out" "mirrored item sess1:3 in conversation $CH as message" "the mirror reports the posted message"
assert_equals "1" "$(post_count "$CH")" "exactly one Discord post for one item"
assert_contains "$(post_bodies "$CH")" "[captain] Terminal line one from the captain." "the posted body carries the attribution and the text"
RECEIPT=$(python3 - "$H" "mirror:$CH:sess1:3" <<'PY'
import hashlib, json, sys
path = f"{sys.argv[1]}/state/discord-workspace/receipts/{hashlib.sha256(sys.argv[2].encode()).hexdigest()}.json"
print(json.dumps(json.load(open(path)), sort_keys=True))
PY
)
assert_contains "$RECEIPT" '"kind": "mirror"' "the durable receipt names the mirror kind"
assert_contains "$RECEIPT" '"discord_message_id"' "the durable receipt records the Discord message id"
assert_contains "$RECEIPT" "\"channel_id\": \"$CH\"" "the durable receipt records the target channel"

# --- 2. the same item replayed posts nothing twice ---------------------------
out=$(dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-a.txt" --item-key "sess1:3" --tag captain 2>&1) \
  || fail "mirror replay failed: $out"
assert_contains "$out" "mirror exists for item sess1:3; no second post" "a replayed item converges on its receipt"
assert_equals "1" "$(post_count "$CH")" "a replayed item posts nothing twice"

# --- 3. two identical lines at two positions still post twice ---------------
write_item item-dup.txt "ok"
dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-dup.txt" --item-key "sess1:10" --tag captain >/dev/null 2>&1 \
  || fail "first duplicate-position post failed"
dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-dup.txt" --item-key "sess1:11" --tag captain >/dev/null 2>&1 \
  || fail "second duplicate-position post failed"
assert_equals "3" "$(post_count "$CH")" "identical text from two positions posts twice"

# --- 4. a long item is one bounded body that states its truncation ----------
python3 -c 'print("m" * 6000)' > "$TMP_ROOT/item-long.txt"
out=$(dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-long.txt" --item-key "sess1:20" --tag main 2>&1) \
  || fail "long item post failed: $out"
BOUNDED=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
body = world["posts"][sys.argv[2]][-1]["content"]
print(f"{len(body)} {'truncated' if '[mirror truncated:' in body else 'untruncated'}")
PY
)
assert_equals "1800 truncated" "$BOUNDED" "a long item posts one body inside the bound and says so"
assert_contains "$(post_bodies "$CH")" "[main]" "a main-attributed item is tagged apart from the captain"

# --- 5. an empty item posts nothing -----------------------------------------
BEFORE=$(post_count "$CH")
: > "$TMP_ROOT/item-empty.txt"
out=$(dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-empty.txt" --item-key "sess1:30" 2>&1) && \
  fail "an empty item must not post: $out"
assert_contains "$out" "text file is empty" "an empty item is refused with its reason"
assert_equals "$BEFORE" "$(post_count "$CH")" "an empty item posts nothing"

# --- 6. operational text is a settled skip, not a retry loop ----------------
BEFORE=$(post_count "$CH")
printf 'FIRSTMATE WATCHER WAKE: queued\n' > "$TMP_ROOT/item-op.txt"
out=$(dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-op.txt" --item-key "sess1:40" 2>&1) \
  || fail "operational text must settle, not fail: $out"
assert_contains "$out" "mirror skipped item sess1:40: operational text is never mirrored" "operational text is skipped explicitly"
assert_equals "$BEFORE" "$(post_count "$CH")" "operational text posts nothing"
python3 - "$H" "$CH" <<'PY' || fail "a skipped item must record no receipt"
import hashlib, sys
from pathlib import Path
nonce = f"mirror:{sys.argv[2]}:sess1:40".encode()
path = Path(sys.argv[1]) / "state/discord-workspace/receipts" / (hashlib.sha256(nonce).hexdigest() + ".json")
raise SystemExit(1 if path.exists() else 0)
PY

# --- 7. the channel and the switch are config, and both are enforced ---------
OTHER_ONLY="$TMP_ROOT/other.json"
python3 - "$CFG" "$OTHER_ONLY" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["mirror"]["channel_id"] = "$OTHER"
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
write_item item-b.txt "Routed to the other channel."
dc mirror --config "$OTHER_ONLY" --text-file "$TMP_ROOT/item-b.txt" --item-key "sess2:1" >/dev/null 2>&1 \
  || fail "the configured channel was not honored"
assert_equals "1" "$(post_count "$OTHER")" "mirror.channel_id decides the destination"
BEFORE=$(post_count "$CH")
out=$(dc mirror --config "$OTHER_ONLY" --text-file "$TMP_ROOT/item-b.txt" --item-key "sess2:2" --channel "$CH" 2>&1) \
  || fail "an explicit configured channel must be accepted: $out"
assert_equals "$((BEFORE + 1))" "$(post_count "$CH")" "an explicit configured channel overrides mirror.channel_id"

out=$(dc mirror --config "$OTHER_ONLY" --text-file "$TMP_ROOT/item-b.txt" --item-key "sess2:3" --channel 999999999999999999 2>&1) && \
  fail "an unconfigured channel must be refused"
assert_contains "$out" "is not a configured #firstmate channel" "an unconfigured channel is refused"

OFF="$TMP_ROOT/off.json"
python3 - "$CFG" "$OFF" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["mirror"]["enabled"] = False
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
BEFORE=$(post_count "$CH")
out=$(dc mirror --config "$OFF" --text-file "$TMP_ROOT/item-b.txt" --item-key "sess3:1" 2>&1) && \
  fail "a disabled mirror must refuse"
assert_contains "$out" "the session mirror is disabled" "mirror.enabled false refuses the post"
assert_equals "$BEFORE" "$(post_count "$CH")" "a disabled mirror posts nothing"

NOPOST="$TMP_ROOT/nopost.json"
python3 - "$CFG" "$NOPOST" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["live"]["posting"] = False
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
out=$(dc mirror --config "$NOPOST" --text-file "$TMP_ROOT/item-b.txt" --item-key "sess4:1" 2>&1) && \
  fail "live.posting false must refuse the post"
assert_contains "$out" "live posting is disabled" "live.posting false refuses the post"

# --- 8. the dry run plans and posts nothing ---------------------------------
BEFORE_CH=$(post_count "$CH")
BEFORE_OTHER=$(post_count "$OTHER")
out=$(dc mirror --config "$CFG" --text-file "$TMP_ROOT/item-b.txt" --item-key "sess5:1" --tag main --dry-run 2>&1) \
  || fail "dry run failed: $out"
assert_contains "$out" "dry-run only; no Discord post was made." "the dry run says it posted nothing"
assert_contains "$out" "[main] Routed to the other channel." "the dry run prints the rendered body"
assert_equals "$BEFORE_CH" "$(post_count "$CH")" "the dry run posts nothing to the channel"
assert_equals "$BEFORE_OTHER" "$(post_count "$OTHER")" "the dry run posts nothing to the other channel"

# --- 9. config-check and status surface the channel, the switch, the cursor --
out=$(dc config-check --config "$CFG" 2>&1) || fail "config-check failed: $out"
assert_contains "$out" "session mirror: on" "config-check reports the mirror switch"
assert_contains "$out" "mirror channel: $CH (Firstmate)" "config-check reports the mirrored channel"
assert_contains "$out" "mirror bound: 1800 chars" "config-check reports the mirror bound"

python3 - "$H" <<PY
import json, os, sys
path = f"{sys.argv[1]}/state/discord-workspace/conversation-console/mirror-cursor.json"
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump({"schema": "fm-discord-conversation-console.mirror-cursor.v1", "file": "/tmp/session.jsonl", "index": 7}, open(path, "w"))
PY
BEFORE_STATE=$(state_signature "$H/state")
out=$(dc status --config "$CFG" 2>&1) || fail "status failed: $out"
assert_contains "$out" "session mirror: on" "status reports the mirror switch"
assert_contains "$out" "mirror channel: $CH (Firstmate)" "status reports the mirrored channel"
assert_contains "$out" "mirror cursor: /tmp/session.jsonl at entry 7" "status reports the durable cursor"
AFTER_STATE=$(state_signature "$H/state")
assert_equals "$BEFORE_STATE" "$AFTER_STATE" "status changes no durable state"

# A config with the mirror on but no channel is refused rather than guessed.
NOCHAN="$TMP_ROOT/nochan.json"
python3 - "$CFG" "$NOCHAN" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["mirror"]["channel_id"] = ""
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
out=$(dc config-check --config "$NOCHAN" 2>&1) && fail "an enabled mirror with no channel must be refused"
assert_contains "$out" "mirror.channel_id must name the #firstmate channel" "an enabled mirror requires its channel"

# A config whose mirror channel is not a configured channel is refused.
FOREIGN="$TMP_ROOT/foreign.json"
python3 - "$CFG" "$FOREIGN" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["mirror"]["channel_id"] = "999999999999999999"
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
out=$(dc config-check --config "$FOREIGN" 2>&1) && fail "a foreign mirror channel must be refused"
assert_contains "$out" "is not one of the configured #firstmate channels" "a foreign mirror channel is refused"

pass "discord console session mirror"
