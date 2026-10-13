#!/usr/bin/env bash
# Behavior tests for the Firstmate-side Discord session mirror.
#
# Every Discord interaction is served by a fake loopback HTTP server: no real
# token is read, nothing leaves 127.0.0.1, and no live guild is contacted. The
# suite proves the four captain-required behaviors - exact-once posting across a
# simulated restart, a state change that moves the thread's tags without
# creating a second thread, in-thread refusal of an unrecognized or ambiguous
# session request, and a bounded side-effect-free state report - plus the
# project-to-forum mapping, artifact linking, and publication safety guards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-discord-mirror.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

GUILD=111111111111111111
OTHER_GUILD=111111111111111119
BOT=333333333333333333
CAPTAIN=444444444444444444
FORUM_A=777777777777777701
FORUM_A_ART=777777777777777702
FORUM_B=777777777777777703
STRAY_FORUM=777777777777777799
FAKE_TOKEN=faketoken-mirror-abc
TAG_SESSION=900000000000000001
TAG_WORKTREE=900000000000000002
TAG_ACTIF=900000000000000003
TAG_ATTENTE=900000000000000004
TAG_BLOQUE=900000000000000005
TAG_TERMINE=900000000000000006
TAG_ART_REPORT=910000000000000001

mirror() { FM_HOME="$H" "$ROOT/bin/fm-discord-session-mirror.sh" "$@"; }

# --- shared-loopback fake Discord server ------------------------------------
start_server() { # start_server <world-file> <port-file>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" > "$TMP_ROOT/server.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORLD, PORT_FILE, TOKEN = sys.argv[1], sys.argv[2], sys.argv[3]
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

    def _authorized(self):
        return self.headers.get("Authorization") == f"Bot {TOKEN}"

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        world = load()
        if not self._authorized():
            self._send(401, {"message": "Unauthorized", "note": "leak " + TOKEN})
            return
        world["gets"] = int(world.get("gets", 0)) + 1
        save(world)
        if parts == ["users", "@me"]:
            self._send(200, {"id": world.get("bot_id", BOT), "username": "fake-bot"})
        elif world.get("deny"):
            self._send(403, {"message": "Missing Access", "code": 50001})
        elif len(parts) == 4 and parts[0] == "guilds" and parts[2:] == ["threads", "active"]:
            guild = parts[1]
            self._send(200, {"threads": [t for t in world.get("threads", []) if t.get("guild_id") == guild]})
        elif len(parts) == 3 and parts[0] == "guilds" and parts[2] == "webhooks":
            self._send(200, [h for h in world.get("webhooks", []) if h.get("guild_id") == parts[1]])
        elif len(parts) == 2 and parts[0] == "guilds":
            self._send(200, {"id": parts[1], "name": world.get("guild_names", {}).get(parts[1], "Guild")})
        elif len(parts) == 5 and parts[2] == "threads" and parts[3] == "archived" and parts[4] == "public":
            self._send(200, {"threads": [t for t in world.get("threads", []) if t.get("parent_id") == parts[1] and t.get("archived")]})
        elif len(parts) == 2 and parts[0] == "channels":
            channel = next((c for c in world.get("channels", []) if c["id"] == parts[1]), None)
            if channel is None:
                self._send(404, {"message": "Unknown Channel"})
            else:
                self._send(200, channel)
        elif len(parts) == 4 and parts[0] == "channels" and parts[2] == "messages":
            message = next((m for m in world.get("messages", {}).get(parts[1], []) if m["id"] == parts[3]), None)
            if message is None:
                self._send(404, {"message": "Unknown Message"})
            else:
                self._send(200, message)
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
        if not self._authorized():
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "webhooks":
            channel = next((c for c in world.get("channels", []) if c["id"] == parts[1]), None)
            if channel is None:
                self._send(404, {"message": "Unknown Channel"})
                return
            if not body.get("name"):
                self._send(400, {"message": "name is required"})
                return
            world["counter"] = int(world.get("counter", 930000000000000000)) + 1
            webhook = {
                "id": str(world["counter"]),
                "guild_id": channel.get("guild_id"),
                "channel_id": parts[1],
                "name": body["name"],
                "token": "faketoken-created-%s" % world["counter"],
                "type": 1,
            }
            world.setdefault("webhooks", []).append(webhook)
            world["webhook_creates"] = int(world.get("webhook_creates", 0)) + 1
            save(world)
            self._send(200, webhook)
        elif len(parts) == 3 and parts[0] == "channels" and parts[2] == "threads":
            forum = next((c for c in world.get("channels", []) if c["id"] == parts[1]), None)
            if forum is None:
                self._send(404, {"message": "Unknown Channel"})
                return
            if len("" if (body.get("message") or {}).get("content") is None else str(body["message"]["content"])) > 2000:
                self._send(400, {"message": "Invalid Form Body", "code": 50035,
                                 "errors": {"content": {"_errors": [{"code": "BASE_TYPE_MAX_LENGTH",
                                                                        "message": "Must be 2000 or fewer in length."}]}}})
                return
            name = body.get("name") or ""
            if not name or len(name) > 100:
                self._send(400, {"message": "invalid thread name"})
                return
            allowed = {t["id"] for t in forum.get("available_tags", [])}
            for tag in body.get("applied_tags") or []:
                if tag not in allowed:
                    self._send(400, {"message": "invalid tag"})
                    return
            world["counter"] = int(world.get("counter", 930000000000000000)) + 1
            thread_id = str(world["counter"])
            thread = {
                "id": thread_id,
                "guild_id": forum.get("guild_id"),
                "parent_id": forum["id"],
                "name": name,
                "type": 11,
                "applied_tags": list(body.get("applied_tags") or []),
            }
            world.setdefault("threads", []).append(thread)
            world["thread_creates"] = int(world.get("thread_creates", 0)) + 1
            message = {
                "id": thread_id,
                "content": (body.get("message") or {}).get("content"),
                "author": {"id": BOT, "bot": True},
                "channel_id": thread_id,
            }
            world.setdefault("messages", {}).setdefault(thread_id, []).append(message)
            world["posts"] = int(world.get("posts", 0)) + 1
            save(world)
            self._send(201, thread)
        elif len(parts) == 3 and parts[0] == "channels" and parts[2] == "messages":
            if body.get("allowed_mentions") != {"parse": []}:
                self._send(400, {"message": "allowed_mentions must be empty parse"})
                return
            if len("" if body.get("content") is None else str(body["content"])) > 2000:
                self._send(400, {"message": "Invalid Form Body", "code": 50035,
                                 "errors": {"content": {"_errors": [{"code": "BASE_TYPE_MAX_LENGTH",
                                                                        "message": "Must be 2000 or fewer in length."}]}}})
                return
            world["counter"] = int(world.get("counter", 930000000000000000)) + 1
            message = {"id": str(world["counter"]), "content": body.get("content"),
                       "author": {"id": BOT, "bot": True}, "channel_id": parts[1]}
            world.setdefault("messages", {}).setdefault(parts[1], []).append(message)
            world["posts"] = int(world.get("posts", 0)) + 1
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
        world = load()
        if not self._authorized():
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 2 and parts[0] == "channels":
            # A thread is also listed as a channel, so the thread lookup wins:
            # applied_tags belongs to the thread, available_tags to the forum.
            thread = next((t for t in world.get("threads", []) if t["id"] == parts[1]), None)
            if thread is not None:
                if "applied_tags" in body:
                    thread["applied_tags"] = list(body["applied_tags"] or [])
                    world["tag_patches"] = int(world.get("tag_patches", 0)) + 1
                save(world)
                self._send(200, thread)
                return
            channel = next((c for c in world.get("channels", []) if c["id"] == parts[1]), None)
            if channel is None:
                self._send(404, {"message": "Unknown Channel"})
                return
            if "available_tags" in body:
                merged = []
                for item in body["available_tags"] or []:
                    if not isinstance(item, dict) or not item.get("name"):
                        continue
                    if item.get("id"):
                        merged.append({"id": str(item["id"]), "name": str(item["name"])})
                    else:
                        world["counter"] = int(world.get("counter", 930000000000000000)) + 1
                        merged.append({"id": str(world["counter"]), "name": str(item["name"])})
                channel["available_tags"] = merged
                world["channel_tag_patches"] = int(world.get("channel_tag_patches", 0)) + 1
            save(world)
            self._send(200, channel)
        elif len(parts) == 4 and parts[0] == "channels" and parts[2] == "messages":
            message = next((m for m in world.get("messages", {}).get(parts[1], []) if m["id"] == parts[3]), None)
            if message is None:
                self._send(404, {"message": "Unknown Message"})
                return
            message["content"] = body.get("content")
            world["edits"] = int(world.get("edits", 0)) + 1
            save(world)
            self._send(200, message)
        else:
            self._send(404, {"message": "not found"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  for _ in $(seq 1 60); do
    [ -s "$2" ] && break
    sleep 0.1
  done
  [ -s "$2" ] || fail "fake Discord server did not start"
}

world_get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],0))" "$WORLD" "$1"; }

# --- loopback fake Discord webhook endpoint ---------------------------------
WEBHOOK_TOKEN=faketoken-webhook-mirror
WEBHOOK_ID=1550452099039633499

start_webhook_server() {
  WEBHOOK_WORLD="$TMP_ROOT/webhook-world.json"
  WEBHOOK_PORT_FILE="$TMP_ROOT/webhook-port"
  printf '{"posts":[],"edits":[],"thread_posts":[],"counter":940000000000000000}\n' > "$WEBHOOK_WORLD"
  setsid python3 - "$WEBHOOK_WORLD" "$WEBHOOK_PORT_FILE" "$WEBHOOK_ID" "$WEBHOOK_TOKEN" > "$TMP_ROOT/webhook-server.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORLD, PORT_FILE, WEBHOOK_ID, WEBHOOK_TOKEN = sys.argv[1:5]


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

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _split(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)
        return parts, query

    def _authorized(self, parts):
        return len(parts) >= 2 and parts[0] == "webhooks" and parts[1] == WEBHOOK_ID and parts[2] == WEBHOOK_TOKEN

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {}

    def do_POST(self):
        parts, query = self._split()
        world = load()
        if not self._authorized(parts):
            self._send(401, {"message": "Unauthorized", "note": "leak " + WEBHOOK_TOKEN})
            return
        body = self._body()
        if body.get("allowed_mentions") != {"parse": []}:
            self._send(400, {"message": "allowed_mentions must be empty parse"})
            return
        # Discord's own webhook field rules, which the live API enforces: a
        # username may not contain "discord" or "clyde", and message content
        # may not exceed 2000 characters. Live runs returned both as HTTP 400.
        username = "" if body.get("username") is None else str(body.get("username"))
        if any(word in username.lower() for word in ("discord", "clyde")):
            self._send(400, {"message": "Invalid Form Body", "code": 50035,
                             "errors": {"username": {"_errors": [{"code": "USERNAME_INVALID_CONTAINS",
                                                                      "message": 'Username cannot contain "discord"'}]}}})
            return
        if len("" if body.get("content") is None else str(body["content"])) > 2000:
            self._send(400, {"message": "Invalid Form Body", "code": 50035,
                             "errors": {"content": {"_errors": [{"code": "BASE_TYPE_MAX_LENGTH",
                                                                     "message": "Must be 2000 or fewer in length."}]}}})
            return
        world["counter"] = int(world["counter"]) + 1
        message = {"id": str(world["counter"]), "channel_id": str(world["counter"]), "content": body.get("content")}
        if "thread_id" in query:
            world["thread_posts"].append({"thread_id": query["thread_id"][0], "content": body.get("content")})
        elif body.get("thread_name"):
            world["posts"].append({
                "thread_name": body["thread_name"],
                "username": body.get("username"),
                "applied_tags": list(body.get("applied_tags") or []),
                "content": body.get("content"),
                "id": message["id"],
            })
        else:
            self._send(400, {"message": "thread_name or thread_id is required"})
            return
        save(world)
        self._send(200, message)

    def do_PATCH(self):
        parts, query = self._split()
        world = load()
        if not self._authorized(parts) or len(parts) != 5 or parts[3] != "messages":
            self._send(401, {"message": "Unauthorized"})
            return
        body = self._body()
        world["edits"].append({"message_id": parts[4], "thread_id": query.get("thread_id", [""])[0], "content": body.get("content")})
        save(world)
        self._send(200, {"id": parts[4], "content": body.get("content")})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
  for _ in $(seq 1 60); do
    [ -s "$WEBHOOK_PORT_FILE" ] && break
    sleep 0.1
  done
  [ -s "$WEBHOOK_PORT_FILE" ] || fail "fake Discord webhook server did not start"
  local webhook_port
  webhook_port=$(cat "$WEBHOOK_PORT_FILE")
  export FM_DISCORD_MIRROR_WEBHOOK_API_BASE="http://127.0.0.1:$webhook_port"
}

write_webhook_file() { # write_webhook_file <project-key>
  cat > "$H/config/discord-webhooks.json" <<JSON
{"webhooks": [
  {"guild": "Hermes", "guild_slug": "hermes", "project": "Firstmate & Supervision", "kind": "sessions",
   "channel_id": "$FORUM_A", "webhook_id": "$WEBHOOK_ID",
   "url": "https://discord.com/api/webhooks/$WEBHOOK_ID/$WEBHOOK_TOKEN"}
]}
JSON
  python3 - "$H/config/discord-session-mirror.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
project = data["projects"]["atelier"]
project["tag_ids"] = {
    "session": "900000000000000001",
    "worktree": "900000000000000002",
    "actif": "900000000000000003",
    "en-attente": "900000000000000004",
    "bloque": "900000000000000005",
    "termine": "900000000000000006",
}
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
}

new_world() {
  cat > "$WORLD" <<JSON
{
  "bot_id": "$BOT",
  "channels": [
    {"id": "$FORUM_A", "guild_id": "$GUILD", "name": "sessions", "type": 15,
     "available_tags": [
       {"id": "$TAG_SESSION", "name": "session"},
       {"id": "$TAG_WORKTREE", "name": "worktree"},
       {"id": "$TAG_ACTIF", "name": "actif"},
       {"id": "$TAG_ATTENTE", "name": "en-attente"},
       {"id": "$TAG_BLOQUE", "name": "bloque"},
       {"id": "$TAG_TERMINE", "name": "termine"}
     ]},
    {"id": "$FORUM_A_ART", "guild_id": "$GUILD", "name": "artefacts", "type": 15,
     "available_tags": [{"id": "$TAG_ART_REPORT", "name": "rapport"}]},
    {"id": "$FORUM_B", "guild_id": "$OTHER_GUILD", "name": "sessions", "type": 15,
     "available_tags": [{"id": "$TAG_SESSION", "name": "session"}]},
    {"id": "$STRAY_FORUM", "guild_id": "$GUILD", "name": "sessions", "type": 15,
     "available_tags": [{"id": "$TAG_ACTIF", "name": "actif"}]}
  ],
  "threads": [],
  "messages": {},
  "webhooks": [],
  "guild_names": {"$GUILD": "Hermes", "$OTHER_GUILD": "Other Guild"},
  "thread_creates": 0,
  "webhook_creates": 0,
  "channel_tag_patches": 0,
  "tag_patches": 0,
  "edits": 0,
  "posts": 0,
  "gets": 0,
  "counter": 930000000000000000
}
JSON
}

new_home() { # new_home <name>  -> sets H, WORKTREE
  H="$TMP_ROOT/$1"
  WORKTREE="$TMP_ROOT/treehouse/atelier-7bab20/24/atelier"
  mkdir -p "$H/state" "$H/data" "$H/config" "$WORKTREE"
  cat > "$H/config/discord-session-mirror.json" <<JSON
{
  "schema": "fm-discord-session-mirror.config.v1",
  "secret_file": "config/discord-workspace.secrets.sops.yaml",
  "discord_bot_token_key": "FIRSTMATE_DISCORD_BOT_TOKEN",
  "captain_user_ids": ["$CAPTAIN"],
  "live": {"posting": true},
  "bounds": {"max_tasks_per_pass": 25, "max_thread_listing": 100},
  "projects": {
    "atelier": {
      "label": "Firstmate & supervision",
      "guild_id": "$GUILD",
      "sessions_forum_id": "$FORUM_A",
      "artifact_forum_id": "$FORUM_A_ART",
      "artifact_tags": {"report": "rapport"},
      "paths": ["$TMP_ROOT/project"]
    },
    "other": {
      "label": "Other project",
      "guild_id": "$OTHER_GUILD",
      "sessions_forum_id": "$FORUM_B",
      "paths": ["$TMP_ROOT/other-project"]
    }
  }
}
JSON
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
  mkdir -p "$TMP_ROOT/project" "$TMP_ROOT/other-project"
  # Reconciled-state seam: fm-crew-state.sh's contract without a live backend.
  cat > "$H/fake-crew-state.sh" <<'FAKE'
#!/usr/bin/env bash
set -eu
key=${1//\//_}
file="${FM_DISCORD_MIRROR_STATE_DIR:?}/$key"
[ -f "$file" ] || { echo "state: unknown · source: none · no fixture"; exit 0; }
printf 'state: %s · source: fake · fixture\n' "$(cat "$file")"
FAKE
  chmod +x "$H/fake-crew-state.sh"
  export FM_DISCORD_MIRROR_STATE_CMD="$H/fake-crew-state.sh"
  export FM_DISCORD_MIRROR_STATE_DIR="$H/states"
  mkdir -p "$FM_DISCORD_MIRROR_STATE_DIR"
}

add_task() { # add_task <id> <project-path>
  cat > "$H/state/$1.meta" <<META
endpoint_task_id=$1
worktree=$WORKTREE
project=$2
harness=pi
kind=ship
mode=local-only
backend=herdr
META
}

set_state() { printf '%s\n' "$2" > "$FM_DISCORD_MIRROR_STATE_DIR/$1"; }

# --- fake sops + server -----------------------------------------------------
cat > "$TMP_ROOT/fake-sops" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "-d" ] || exit 64
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: $FAKE_TOKEN\n'
FAKE
chmod +x "$TMP_ROOT/fake-sops"

WORLD="$TMP_ROOT/world.json"
PORT_FILE="$TMP_ROOT/port"
new_world
start_server "$WORLD" "$PORT_FILE"
PORT=$(cat "$PORT_FILE")
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0
export FM_DISCORD_MIRROR_TREEHOUSE_ROOT="$TMP_ROOT/treehouse"

# --- 1. config validation ----------------------------------------------------
new_home c1
out=$(mirror config-check --config "$H/config/discord-session-mirror.json" 2>&1) || fail "config-check failed: $out"
assert_contains "$out" "project atelier: label=Firstmate & supervision" "config-check renders the project mapping"
assert_contains "$out" "state tags: working=actif" "config-check renders the reconciled-state table"
assert_contains "$out" "artifacts=777777777777777702" "config-check renders the artifact forum"

python3 - "$H/config/discord-session-mirror.json" "$TMP_ROOT/bad-dup.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["projects"]["other"]["sessions_forum_id"] = data["projects"]["atelier"]["sessions_forum_id"]
json.dump(data, open(sys.argv[2], "w"))
PY
out=$(mirror config-check --config "$TMP_ROOT/bad-dup.json" 2>&1) && fail "duplicate forum id accepted" || true
assert_contains "$out" "duplicate Discord forum id" "a duplicate project-to-forum mapping is refused"

python3 - "$H/config/discord-session-mirror.json" "$TMP_ROOT/bad-tags.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
del data["projects"]["atelier"]
data["state_tags"] = {"working": "actif"}
json.dump(data, open(sys.argv[2], "w"))
PY
out=$(mirror config-check --config "$TMP_ROOT/bad-tags.json" 2>&1) && fail "incomplete state tag map accepted" || true
assert_contains "$out" "missing parked" "an incomplete reconciled-state table is refused"

python3 - "$H/config/discord-session-mirror.json" "$TMP_ROOT/bad-secret.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["discord_bot_token_key"] = "not-a-ref"
json.dump(data, open(sys.argv[2], "w"))
PY
out=$(mirror config-check --config "$TMP_ROOT/bad-secret.json" 2>&1) && fail "inline secret reference accepted" || true
assert_contains "$out" "uppercase secret reference name" "a non-reference token key is refused"
pass "config validation owns the project mapping, tag table, and secret references"

# --- 2. report is bounded and side-effect-free ------------------------------
new_home c2
add_task m-one "$TMP_ROOT/project"
set_state m-one working
BEFORE=$(world_get gets)
out=$(mirror report --config "$H/config/discord-session-mirror.json" 2>&1) || fail "report failed: $out"
assert_contains "$out" "m-one: project=atelier worktree=atelier-24 state=working tag=actif thread=none" "report renders the reconciled state and tag"
assert_contains "$out" "no network call" "report declares that it is offline"
AFTER=$(world_get gets)
[ "$BEFORE" = "$AFTER" ] || fail "report contacted Discord ($BEFORE -> $AFTER)"
pass "report is a bounded, side-effect-free view of the mirror state"

# --- 3. sync mirrors a live session into the right forum with the right tags -
new_home c3
add_task m-one "$TMP_ROOT/project"
set_state m-one working
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "sync failed: $out"
assert_contains "$out" "created thread" "sync creates the session thread"
[ "$(world_get thread_creates)" = "1" ] || fail "sync created $(world_get thread_creates) threads instead of 1"
THREAD=$(python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
thread = world["threads"][0]
print(thread["id"])
assert thread["parent_id"] == "777777777777777701", thread
assert thread["name"] == "Firstmate & supervision - m-one - atelier-24", thread["name"]
assert sorted(thread["applied_tags"]) == sorted(["900000000000000001", "900000000000000002", "900000000000000003"]), thread
PY
)
[ -n "$THREAD" ] || fail "sync did not create the expected thread"
CARD=$(python3 - "$WORLD" "$THREAD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
card = world["messages"][sys.argv[2]][0]["content"]
for field in ("**Projet :** Firstmate & supervision", "**Session :** m-one", "**Worktree :** atelier-24", "**Etat :** working"):
    assert field in card, (field, card)
print("ok")
PY
)
[ "$CARD" = "ok" ] || fail "session card is missing a labelled identity field"
pass "sync mirrors one live session into its project sessions forum with session, worktree, and state tags"

# --- 4. restart safety: no duplicate thread, no replay, crash recovery -------
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "second sync failed: $out"
[ "$(world_get thread_creates)" = "1" ] || fail "a restart created a duplicate thread"
[ "$(world_get posts)" = "1" ] || fail "a restart replayed the session card"
# Simulate a crash between Discord creating the thread and the record landing.
rm -f "$H/state/discord-workspace/session-mirror/sessions/m-one.json"
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "recovery sync failed: $out"
assert_contains "$out" "adopted existing thread" "a lost record is recovered by the deterministic thread name"
[ "$(world_get thread_creates)" = "1" ] || fail "crash recovery created a duplicate thread"
[ "$(world_get posts)" = "1" ] || fail "crash recovery replayed the session card"
pass "exact-once posting survives a restart and a lost session record"

# --- 5. a state change moves the tags without a second thread ---------------
set_state m-one blocked
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "state-change sync failed: $out"
assert_contains "$out" "tags now session, worktree, bloque" "the state tag follows reconciliation"
[ "$(world_get thread_creates)" = "1" ] || fail "the state change created a second thread"
[ "$(world_get tag_patches)" = "1" ] || fail "the state change did not patch the thread tags exactly once"
python3 - "$WORLD" "$THREAD" <<'PY' || fail "the thread does not carry exactly the expected tags"
import json, sys
world = json.load(open(sys.argv[1]))
thread = next(t for t in world["threads"] if t["id"] == sys.argv[2])
assert sorted(thread["applied_tags"]) == sorted(["900000000000000001", "900000000000000002", "900000000000000005"]), thread
PY
[ "$(world_get posts)" = "1" ] || fail "the state change posted a second message instead of editing the card"
[ "$(world_get edits)" = "1" ] || fail "the state change did not edit the card in place"
python3 - "$WORLD" "$THREAD" <<'PY' || fail "the card does not carry the reconciled state"
import json, sys
world = json.load(open(sys.argv[1]))
card = world["messages"][sys.argv[2]][0]["content"]
assert "**Etat :** blocked" in card, card
PY
pass "a reconciled state change moves the thread's tags and edits one card in place"

# --- 6. an unmapped project is skipped, never invented ----------------------
new_home c6
add_task m-orphan "$TMP_ROOT/unknown-project"
set_state m-orphan working
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "unmapped sync failed: $out"
assert_contains "$out" "skipped, no configured project mapping" "an unmapped project is reported, not guessed"
[ "$(world_get thread_creates)" = "1" ] || fail "an unmapped project created a thread"
pass "an unmapped project is skipped with a clear reason"

# --- 7. an unrecognized thread request is refused in-thread -----------------
new_home c7
THREAD_REQ=$((930000000000001000))
python3 - "$WORLD" "$THREAD_REQ" "$STRAY_FORUM" "$CAPTAIN" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
thread_id, forum, captain = sys.argv[2], sys.argv[3], sys.argv[4]
world["channels"].append({"id": thread_id, "guild_id": "111111111111111111", "parent_id": forum,
                          "name": "une demande du capitaine", "type": 11, "applied_tags": []})
world["threads"].append({"id": thread_id, "guild_id": "111111111111111111", "parent_id": forum,
                         "name": "une demande du capitaine", "type": 11, "applied_tags": []})
world["messages"][thread_id] = [{"id": thread_id, "content": "ouvre une session pour ceci",
                                 "author": {"id": captain, "bot": False}, "channel_id": thread_id}]
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(mirror request --config "$H/config/discord-session-mirror.json" --thread "$THREAD_REQ" 2>&1) || fail "request failed: $out"
assert_contains "$out" "refused" "an unrecognized thread is refused"
python3 - "$WORLD" "$THREAD_REQ" <<'PY' || fail "the refusal was not posted in the same thread"
import json, sys
world = json.load(open(sys.argv[1]))
messages = world["messages"][sys.argv[2]]
assert len(messages) == 2, messages
assert "Demande de session refusee" in messages[-1]["content"], messages[-1]
PY
python3 - "$H" <<'PY' || fail "the refusal was not recorded durably"
import json, sys
from pathlib import Path
records = list((Path(sys.argv[1]) / "state/discord-workspace/session-mirror/requests").glob("*.json"))
assert records, "no request record"
data = json.loads(records[0].read_text())
assert data["outcome"] == "refused", data
assert data["reason"], data
PY
pass "an unrecognized thread request is refused in-thread and recorded, never silently dropped"

# --- 8. an ambiguous or non-captain request is refused in-thread ------------
new_home c8
THREAD_AMB=$((930000000000002000))
python3 - "$WORLD" "$THREAD_AMB" "$FORUM_A" "$BOT" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
thread_id, forum, bot = sys.argv[2], sys.argv[3], sys.argv[4]
world["channels"].append({"id": thread_id, "guild_id": "111111111111111111", "parent_id": forum,
                          "name": "bot starter", "type": 11, "applied_tags": []})
world["threads"].append({"id": thread_id, "guild_id": "111111111111111111", "parent_id": forum,
                         "name": "bot starter", "type": 11, "applied_tags": []})
world["messages"][thread_id] = [{"id": thread_id, "content": "machine text",
                                 "author": {"id": bot, "bot": True}, "channel_id": thread_id}]
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(mirror request --config "$H/config/discord-session-mirror.json" --thread "$THREAD_AMB" 2>&1) || fail "ambiguous request failed: $out"
assert_contains "$out" "refused" "a non-captain thread is refused"
python3 - "$WORLD" "$THREAD_AMB" <<'PY' || fail "the ambiguity was not explained in the thread"
import json, sys
world = json.load(open(sys.argv[1]))
messages = world["messages"][sys.argv[2]]
assert len(messages) == 2, messages
assert "not started by the captain" in messages[-1]["content"], messages[-1]
PY
pass "a non-captain thread is refused in-thread with the exact reason"

# --- 9. an explicit request is accepted, binds, and then stays in that thread -
new_home c9
THREAD_OK=$((930000000000003000))
python3 - "$WORLD" "$THREAD_OK" "$FORUM_A" "$CAPTAIN" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
thread_id, forum, captain = sys.argv[2], sys.argv[3], sys.argv[4]
world["channels"].append({"id": thread_id, "guild_id": "111111111111111111", "parent_id": forum,
                          "name": "nouvelle session", "type": 11, "applied_tags": []})
world["threads"].append({"id": thread_id, "guild_id": "111111111111111111", "parent_id": forum,
                         "name": "nouvelle session", "type": 11, "applied_tags": []})
world["messages"][thread_id] = [{"id": thread_id, "content": "ouvre une session pour le miroir Discord",
                                 "author": {"id": captain, "bot": False}, "channel_id": thread_id}]
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(mirror request --config "$H/config/discord-session-mirror.json" --thread "$THREAD_OK" 2>&1) || fail "accepted request failed: $out"
assert_contains "$out" "accepted for project atelier" "a captain thread in a configured forum is accepted"
[ -n "$(ls "$H/state/inbox"/*.note 2>/dev/null)" ] || fail "the accepted request did not wake firstmate through the inbox seam"
python3 - "$H" <<'PY' || fail "the accepted request did not record its inbox wake"
import json, sys
from pathlib import Path
records = list((Path(sys.argv[1]) / "state/discord-workspace/session-mirror/requests").glob("*.json"))
assert records, "no request record"
data = json.loads(records[0].read_text())
assert data["outcome"] == "accepted", data
assert data["note_id"], data
assert data["project"] == "atelier", data
PY
add_task m-bound "$TMP_ROOT/project"
set_state m-bound working
out=$(mirror bind --config "$H/config/discord-session-mirror.json" --thread "$THREAD_OK" --task m-bound 2>&1) || fail "bind failed: $out"
assert_contains "$out" "now bound to thread" "bind records the session-to-thread binding"
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "post-bind sync failed: $out"
python3 - "$WORLD" "$THREAD_OK" <<'PY' || fail "the bound session did not stay in the captain's thread"
import json, sys
world = json.load(open(sys.argv[1]))
thread = next(t for t in world["threads"] if t["id"] == sys.argv[2])
assert sorted(thread["applied_tags"]) == sorted(["900000000000000001", "900000000000000002", "900000000000000003"]), thread
assert any("**Session :** m-bound" in m["content"] for m in world["messages"][sys.argv[2]]), world["messages"][sys.argv[2]]
PY
assert_contains "$(mirror report --config "$H/config/discord-session-mirror.json" 2>&1)" "m-bound: project=atelier worktree=atelier-24 state=working tag=actif thread=$THREAD_OK" "the binding is visible in the state report"
pass "a captain-created thread becomes a session bound to that thread and later traffic stays in it"

# --- 10. artifacts get their own tagged thread and a link --------------------
new_world
new_home c10
add_task m-art "$TMP_ROOT/project"
set_state m-art working
mirror sync --config "$H/config/discord-session-mirror.json" >/dev/null 2>&1 || fail "artifact sync failed"
printf 'Un rapport court et publiable.\n' > "$TMP_ROOT/report.md"
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-art --kind report --title "Rapport de session" --body-file "$TMP_ROOT/report.md" 2>&1) || fail "artifact failed: $out"
assert_contains "$out" "artifact thread" "the artifact thread is recorded"
python3 - "$WORLD" "$FORUM_A_ART" "$TAG_ART_REPORT" <<'PY' || fail "the artifact did not land in the configured artifact forum with its tag"
import json, sys
world = json.load(open(sys.argv[1]))
artifact = next(t for t in world["threads"] if t["parent_id"] == sys.argv[2])
assert artifact["applied_tags"] == [sys.argv[3]], artifact
assert "Rapport de session" in world["messages"][artifact["id"]][0]["content"]
PY
python3 - "$WORLD" "$FORUM_A" <<'PY' || fail "the session thread does not link the artifact"
import json, sys
world = json.load(open(sys.argv[1]))
session = next(t for t in world["threads"] if t["parent_id"] == sys.argv[2])
linked = [m for m in world["messages"][session["id"]] if "Artefact (report)" in (m["content"] or "")]
assert len(linked) == 1, world["messages"][session["id"]]
PY
CREATES_BEFORE=$(world_get thread_creates)
POSTS_BEFORE=$(world_get posts)
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-art --kind report --title "Rapport de session" --body-file "$TMP_ROOT/report.md" 2>&1) || fail "artifact replay failed: $out"
[ "$(world_get thread_creates)" = "$CREATES_BEFORE" ] || fail "an artifact replay created a second thread"
[ "$(world_get posts)" = "$POSTS_BEFORE" ] || fail "an artifact replay posted a duplicate link"
pass "an artifact lands in its own tagged thread and is linked once from the session thread"

# --- 11. publication safety guards ------------------------------------------
new_home c11
add_task m-art "$TMP_ROOT/project"
set_state m-art working
printf 'FIRSTMATE_OP: v1 internal directive text\n' > "$TMP_ROOT/private.md"
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-art --kind report --title "ok" --body-file "$TMP_ROOT/private.md" 2>&1) && fail "operational text was published" || true
assert_contains "$out" "operational supervision text" "operational supervision text is refused"
printf 'token AAAAAAAAAAAAAAAAAAAAAAAA.BBBBBB.CCCCCCCCCCCCCCCCCCCCCCCC\n' > "$TMP_ROOT/secret.md"
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-art --kind report --title "ok" --body-file "$TMP_ROOT/secret.md" 2>&1) && fail "token-like text was published" || true
assert_contains "$out" "token or key" "token-like text is refused"
pass "the mirror refuses operational and secret-looking publication"

# --- 12. a missing mirror tag vocabulary is reported, not guessed ------------
new_world
new_home c12
add_task m-tag "$TMP_ROOT/project"
set_state m-tag working
python3 - "$H/config/discord-session-mirror.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["projects"] = {"other": data["projects"]["other"]}
data["projects"]["other"]["paths"] = [data["projects"]["other"]["paths"][0]]
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
add_task m-tag2 "$TMP_ROOT/other-project"
set_state m-tag2 working
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "tag-gap sync failed: $out"
assert_contains "$out" "lacks tag(s): worktree, actif" "a missing forum tag is reported with its exact names"
pass "a missing forum tag vocabulary is reported instead of guessed"

# --- 13. a live refusal is one bounded line, never a traceback ---------------
new_world
new_home c13
add_task m-denied "$TMP_ROOT/project"
set_state m-denied working
python3 - "$WORLD" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
world["deny"] = True
json.dump(world, open(sys.argv[1], "w"))
PY
DENIED=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) && DENIED_RC=0 || DENIED_RC=$?
[ "$DENIED_RC" = "1" ] || fail "a refused live pass did not exit nonzero"
assert_contains "$DENIED" "error: Discord API GET" "a refused live pass names the failing call"
printf '%s' "$DENIED" | grep -q "Traceback" && fail "a live refusal printed a traceback: $DENIED"
printf '%s' "$DENIED" | grep -q "$FAKE_TOKEN" && fail "the token leaked into failure output"
pass "a refused live pass reports one bounded, redacted error line"

# --- 14. the webhook transport posts without any bot membership ---------------
new_world
new_home c14
start_webhook_server
add_task m-hook "$TMP_ROOT/project"
set_state m-hook working
write_webhook_file
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "webhook sync failed: $out"
assert_contains "$out" "via the webhook transport" "sync uses the configured webhook transport"
assert_contains "$out" "transports=webhook" "the pass reports the webhook transport"
python3 - "$WEBHOOK_WORLD" <<'PY' || fail "the webhook post is not the expected forum thread"
import json, sys
world = json.load(open(sys.argv[1]))
posts = world["posts"]
assert len(posts) == 1, posts
post = posts[0]
assert post["thread_name"] == "Firstmate & supervision - m-hook - atelier-24", post["thread_name"]
assert post["username"] == "Firstmate & supervision - atelier-24", post["username"]
assert sorted(post["applied_tags"]) == sorted(["900000000000000001", "900000000000000002", "900000000000000003"]), post
assert "**Worktree :** atelier-24" in post["content"] and "**Session :** m-hook" in post["content"], post
PY
BOT_GETS=$(world_get gets)
[ "$BOT_GETS" = "0" ] || fail "the webhook transport still called the bot API ($BOT_GETS gets)"
pass "a configured webhook creates one correctly titled, tagged, per-session-identity forum post without any bot membership"

# --- 15. the webhook transport edits the same card and never re-posts --------
set_state m-hook blocked
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "webhook state change failed: $out"
assert_contains "$out" "session card updated in place" "a state change edits the card in place"
assert_contains "$out" "a webhook cannot re-tag an existing thread" "the re-tag limit is reported, not hidden"
python3 - "$WEBHOOK_WORLD" <<'PY' || fail "the webhook transport re-posted or missed the edit"
import json, sys
world = json.load(open(sys.argv[1]))
assert len(world["posts"]) == 1, world["posts"]
assert len(world["edits"]) == 1, world["edits"]
assert "**Etat :** blocked" in world["edits"][0]["content"], world["edits"][0]
PY
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "webhook repeat sync failed: $out"
python3 - "$WEBHOOK_WORLD" <<'PY' || fail "a repeated webhook pass was not a no-op"
import json, sys
world = json.load(open(sys.argv[1]))
assert len(world["posts"]) == 1 and len(world["edits"]) == 1, (world["posts"], world["edits"])
PY
pass "a webhook state change edits one live card and a repeated pass is a no-op"

# --- 16. the webhook transport reports missing tag ids instead of guessing ---
new_home c16
start_webhook_server
write_webhook_file
python3 - "$H/config/discord-session-mirror.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
del data["projects"]["atelier"]["tag_ids"]
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
add_task m-notags "$TMP_ROOT/project"
set_state m-notags working
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "missing-tag-id sync failed: $out"
assert_contains "$out" "has no configured tag id for session, worktree, actif" "unconfigured tag ids are reported exactly"
assert_contains "$out" "skipped" "an unconfigured tag vocabulary blocks the post instead of guessing"
python3 - "$H/config/discord-session-mirror.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["allow_untagged"] = True
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "opt-in untagged sync failed: $out"
assert_contains "$out" "posting without tags; no configured tag id for" "the opt-in reports the untagged post"
python3 - "$WEBHOOK_WORLD" <<'PY' || fail "the opt-in untagged post did not land"
import json, sys
world = json.load(open(sys.argv[1]))
assert len(world["posts"]) == 1, world["posts"]
assert world["posts"][0]["applied_tags"] == [], world["posts"][0]
PY
pass "a missing tag id is reported exactly, blocks the post, and only an explicit opt-in publishes untagged"

# --- 17. the transport can be forced, so an existing thread can be re-tagged ---
new_world
new_home c17
start_webhook_server
write_webhook_file
add_task m-force "$TMP_ROOT/project"
set_state m-force working
out=$(mirror sync --config "$H/config/discord-session-mirror.json" --transport bot 2>&1) || fail "forced bot sync failed: $out"
assert_contains "$out" "via the bot transport" "--transport bot forces the member-bot transport"
[ "$(world_get thread_creates)" = "1" ] || fail "the forced bot transport did not use the bot path"
python3 - "$WEBHOOK_WORLD" <<'PY' || fail "the forced bot transport still used the webhook"
import json, sys
assert json.load(open(sys.argv[1]))["posts"] == [], "webhook was used under --transport bot"
PY
out=$(mirror sync --config "$H/config/discord-session-mirror.json" --transport webhook 2>&1) || fail "forced webhook sync failed: $out"
[ "$(world_get thread_creates)" = "1" ] || fail "the forced webhook pass created a second thread"
python3 - "$WEBHOOK_WORLD" <<'PY' || fail "the forced webhook pass re-posted the session"
import json, sys
assert json.load(open(sys.argv[1]))["posts"] == [], "webhook re-posted an already mirrored session"
PY
python3 - "$H/state/discord-workspace/session-mirror/sessions/m-force.json" <<'PY' || fail "the card owner moved to a transport that cannot edit it"
import json, sys
record = json.load(open(sys.argv[1]))
assert record["transport"] == "bot", record
PY
python3 - "$H/config/discord-session-mirror.json" "$TMP_ROOT/no-webhook-bot.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["transport"] = "webhook"
data["webhook_file"] = "config/discord-no-webhooks.json"
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
json.dump({"webhooks": []}, open(sys.argv[1].rsplit("/", 1)[0] + "/discord-no-webhooks.json", "w"))
PY
add_task m-force2 "$TMP_ROOT/project"
set_state m-force2 working
out=$(mirror sync --config "$TMP_ROOT/no-webhook-bot.json" --task m-force2 2>&1) && fail "a required webhook was silently replaced by the bot" || true
assert_contains "$out" "the webhook file has no matching entry" "transport=webhook refuses without a matching webhook"
pass "the transport can be forced per pass, a recorded creator keeps the card, and a required webhook is never silently substituted"

# --- 18. the captain's French artifact vocabulary validates and is used ------
# The live config names artifact kinds livrable / rapport / lien / test with
# their Discord tag ids directly; the code now accepts that vocabulary and a
# configured id, while an unknown kind still fails loudly.
new_world
new_home c18
add_task m-fr "$TMP_ROOT/project"
set_state m-fr working
# The artifact forum advertises the captain's numeric tag ids, exactly as the
# live Discord forum does for the configured vocabulary.
python3 - "$WORLD" "$FORUM_A_ART" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
for channel in world["channels"]:
    if channel["id"] == sys.argv[2]:
        channel["available_tags"] = [
            {"id": "1550444494925860868", "name": "livrable"},
            {"id": "1550444494925860869", "name": "rapport"},
            {"id": "1550444494925860870", "name": "lien"},
            {"id": "1550444494925860871", "name": "test"},
        ]
json.dump(world, open(sys.argv[1], "w"))
PY
python3 - "$H/config/discord-session-mirror.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["projects"]["atelier"]["artifact_tags"] = {
    "livrable": "1550444494925860868",
    "rapport": "1550444494925860869",
    "lien": "1550444494925860870",
    "test": "1550444494925860871",
}
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
out=$(mirror config-check --config "$H/config/discord-session-mirror.json" 2>&1) \
  || fail "the captain's artifact vocabulary was rejected: $out"
pass "the captain's French artifact vocabulary validates"

mirror sync --config "$H/config/discord-session-mirror.json" >/dev/null 2>&1 || fail "French-vocabulary sync failed"
printf 'Un livrable publiable.\n' > "$TMP_ROOT/livrable.md"
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-fr --kind livrable \
  --title "Livrable" --body-file "$TMP_ROOT/livrable.md" 2>&1) || fail "livrable artifact failed: $out"
python3 - "$WORLD" "$FORUM_A_ART" <<'PY' || fail "the configured numeric tag id was not applied"
import json, sys
world = json.load(open(sys.argv[1]))
artifact = next(t for t in world["threads"] if t["parent_id"] == sys.argv[2])
assert artifact["applied_tags"] == ["1550444494925860868"], artifact
PY
pass "a configured numeric artifact tag id is applied directly"

python3 - "$H/config/discord-session-mirror.json" "$TMP_ROOT/bad-fr.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["projects"]["atelier"]["artifact_tags"]["bogus"] = "1550444494925860868"
json.dump(data, open(sys.argv[2], "w"))
PY
out=$(mirror config-check --config "$TMP_ROOT/bad-fr.json" 2>&1) && fail "an unknown artifact kind was accepted" || true
assert_contains "$out" "unsupported kind: bogus" "an unknown artifact kind still fails"
assert_contains "$out" "allowed: report, patch, pr, livrable, rapport, lien, test" "the allowed vocabulary is named"
pass "an unknown artifact kind still fails loudly with the allowed vocabulary"

# --- 19. a missing decryption tool is one bounded line, never a traceback ---
new_world
new_home c19
add_task m-sops "$TMP_ROOT/project"
set_state m-sops working
SOPS_RC=0
SOPS_OUT=$(FM_DISCORD_LIVE_SOPS=/nonexistent-sops mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || SOPS_RC=$?
[ "$SOPS_RC" = "1" ] || fail "a missing decryption tool did not exit 1 (rc=$SOPS_RC)"
assert_contains "$SOPS_OUT" "cannot run the secret decryption tool" "the missing tool is named"
assert_contains "$SOPS_OUT" "FM_DISCORD_LIVE_SOPS" "the next step is named"
printf '%s' "$SOPS_OUT" | grep -q 'Traceback' && fail "a missing decryption tool printed a traceback: $SOPS_OUT"
pass "a missing decryption tool is one bounded, actionable line"

echo "fm-discord-session-mirror tests passed"
# --- 20. ensure reconciles the live preconditions a webhook cannot create -----
new_world
new_home c20
add_task m-one "$TMP_ROOT/project"
set_state m-one working
CFG="$H/config/discord-session-mirror.json"

out=$(mirror ensure --config "$CFG" --dry-run 2>&1) || fail "ensure dry-run failed: $out"
assert_contains "$out" "webhook=missing" "the dry-run plan names the missing webhook"
assert_contains "$out" "dry-run: no tag, webhook, config, or Discord write was made" "the dry-run declares its bound"
[ "$(world_get webhook_creates)" = "0" ] || fail "a dry-run created a webhook"
[ "$(world_get channel_tag_patches)" = "0" ] || fail "a dry-run patched a channel"
python3 - "$CFG" <<'PY' || fail "a dry-run rewrote the config"
import json, sys
data = json.load(open(sys.argv[1]))
assert "tag_ids" not in data["projects"]["atelier"], data["projects"]["atelier"]
PY
pass "ensure --dry-run prints the plan and writes nothing"

out=$(mirror ensure --config "$CFG" 2>&1) || fail "ensure failed: $out"
assert_contains "$out" "created tag(s)" "ensure reports the created tags"
assert_contains "$out" "webhook" "ensure reports the webhooks"
assert_contains "$out" "undo: Discord REST DELETE /webhooks/" "the undo names the webhook deletion"
assert_contains "$out" "undo: cp " "the undo names the config restore"
[ "$(world_get webhook_creates)" = "3" ] || fail "ensure created $(world_get webhook_creates) webhooks instead of 3"
[ "$(world_get channel_tag_patches)" = "1" ] || fail "ensure patched $(world_get channel_tag_patches) channels instead of 1"
python3 - "$CFG" "$H/config/discord-webhooks.json" "$WORLD" "$TAG_SESSION" "$TAG_TERMINE" "$TAG_ART_REPORT" "$FORUM_B" <<'PY' || fail "ensure did not reconcile the tags, the ids, and the webhook file"
import json, sys
cfg = json.load(open(sys.argv[1]))
hooks = json.load(open(sys.argv[2]))["webhooks"]
world = json.load(open(sys.argv[3]))
expected = ["actif", "bloque", "en-attente", "session", "termine", "worktree"]
atelier = cfg["projects"]["atelier"]
assert sorted(atelier["tag_ids"]) == expected, atelier["tag_ids"]
assert atelier["tag_ids"]["session"] == sys.argv[4], atelier["tag_ids"]
assert atelier["tag_ids"]["termine"] == sys.argv[5], atelier["tag_ids"]
assert atelier["artifact_tags"]["report"] == sys.argv[6], atelier["artifact_tags"]
assert sorted(cfg["projects"]["other"]["tag_ids"]) == expected, cfg["projects"]["other"]
forum_b = next(c for c in world["channels"] if c["id"] == sys.argv[7])
assert sorted(t["name"] for t in forum_b["available_tags"]) == expected, forum_b["available_tags"]
assert len(hooks) == 3, hooks
assert len({(h["kind"], h["channel_id"]) for h in hooks}) == 3, hooks
assert all(h["url"].startswith("https://discord.com/api/v10/webhooks/") for h in hooks), hooks
assert all(h["webhook_id"] == h["url"].split("/")[6] for h in hooks), hooks
PY
ls "$H"/state/discord-workspace/session-mirror/ensure/*.json >/dev/null 2>&1 || fail "ensure wrote no undo journal"
ls "$H"/config/discord-session-mirror.json.pre-ensure-* >/dev/null 2>&1 || fail "ensure wrote no config backup"
pass "ensure creates the declared tags, writes the ids back, and files one webhook per forum"

out=$(mirror ensure --config "$CFG" 2>&1) || fail "second ensure failed: $out"
assert_contains "$out" "already satisfies the mirror contract; nothing to do" "a second ensure is a no-op"
[ "$(world_get webhook_creates)" = "3" ] || fail "a second ensure created another webhook"
[ "$(world_get channel_tag_patches)" = "1" ] || fail "a second ensure patched another channel"
pass "ensure is idempotent across passes"

# --- 21. a refused guild cannot be reached by any command --------------------
new_world
new_home c21
python3 - "$H/config/discord-session-mirror.json" "$OTHER_GUILD" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["refused_guild_ids"] = {sys.argv[2]: "client guild - never touch"}
json.dump(data, open(sys.argv[1], "w"))
PY
out=$(mirror config-check --config "$H/config/discord-session-mirror.json" 2>&1) && fail "a refused guild was accepted" || true
assert_contains "$out" "is a refused guild" "the refusal is enforced at config load"
assert_contains "$out" "client guild - never touch" "the recorded reason is printed"
out=$(mirror ensure --config "$H/config/discord-session-mirror.json" 2>&1) && fail "ensure ran against a refused guild" || true
assert_contains "$out" "is a refused guild" "every command refuses a refused guild"
[ "$(world_get webhook_creates)" = "0" ] || fail "a refused guild was contacted"
pass "a refused guild is refused at config load, so no command can reach it"

# --- 22. ensure refuses a forum that would pass Discord's tag cap ------------
new_world
new_home c22
python3 - "$WORLD" "$FORUM_B" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
forum = next(c for c in world["channels"] if c["id"] == sys.argv[2])
forum["available_tags"] = [{"id": str(920000000000000000 + i), "name": "tag%d" % i} for i in range(20)]
json.dump(world, open(sys.argv[1], "w"))
PY
out=$(mirror ensure --config "$H/config/discord-session-mirror.json" 2>&1) && fail "an over-cap forum was patched" || true
assert_contains "$out" "20-tag cap" "the tag cap is named"
[ "$(world_get channel_tag_patches)" = "0" ] || fail "an over-cap forum was patched"
[ "$(world_get webhook_creates)" = "0" ] || fail "an over-cap forum left a partial reconciliation"
pass "ensure refuses the whole pass when one forum cannot satisfy the contract"

# --- 23. a configured tag id the forum does not carry is refused -------------
new_world
new_home c23
python3 - "$H/config/discord-session-mirror.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["projects"]["atelier"]["artifact_tags"] = {"report": "919999999999999999"}
json.dump(data, open(sys.argv[1], "w"))
PY
out=$(mirror ensure --config "$H/config/discord-session-mirror.json" 2>&1) && fail "an unknown configured tag id was accepted" || true
assert_contains "$out" "does not carry the configured tag id(s) 919999999999999999" "the unknown tag id is named"
[ "$(world_get channel_tag_patches)" = "0" ] || fail "an unknown tag id still patched a channel"
[ "$(world_get webhook_creates)" = "0" ] || fail "an unknown tag id still created a webhook"
pass "ensure refuses a configured tag id the target forum does not carry"

# --- 24. Discord's own webhook field rules are cleared before the call -----
# Two live HTTP 400s drove this: Discord refuses a webhook username containing
# "discord", which a task id commonly does, and refuses message content over
# 2000 characters, which a body at its own limit plus its title reaches. Both
# are refused locally with the real budget instead of surfacing the form error.
new_world
new_home c24
start_webhook_server
write_webhook_file atelier
add_task m-discord-artifact "$TMP_ROOT/project"
set_state m-discord-artifact working
python3 - "$H/config/discord-session-mirror.json" "$TAG_ART_REPORT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
# A webhook cannot read a forum's tag vocabulary, so the artifact tag has to be
# the numeric id the forum advertises.
data["projects"]["atelier"]["artifact_tags"] = {"report": sys.argv[2]}
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
python3 - "$H/config/discord-webhooks.json" "$FORUM_A_ART" "$WEBHOOK_ID" "$WEBHOOK_TOKEN" <<'PY'
import json, sys
path, forum, webhook_id, token = sys.argv[1:5]
data = json.load(open(path))
data["webhooks"].append({
    "guild": "Hermes", "guild_slug": "hermes", "project": "Firstmate & supervision", "kind": "artifacts",
    "channel_id": forum, "webhook_id": webhook_id,
    "url": f"https://discord.com/api/webhooks/{webhook_id}/{token}",
})
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(mirror sync --config "$H/config/discord-session-mirror.json" 2>&1) || fail "discord-named task sync failed: $out"
printf 'Un rapport court et publiable.\n' > "$TMP_ROOT/short.md"
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-discord-artifact --kind report \
  --title "Rapport" --body-file "$TMP_ROOT/short.md" 2>&1) || fail "an artifact for a task whose id contains 'discord' failed: $out"
assert_contains "$out" "artifact thread" "the artifact is recorded for a discord-named task"
USERNAMES=$(python3 - "$WEBHOOK_WORLD" "$FORUM_A_ART" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
posts = [p for p in world.get("posts", []) if p.get("applied_tags")]
bad = [p["username"] for p in posts if any(w in str(p.get("username") or "").lower() for w in ("discord", "clyde"))]
print("ok" if posts and not bad else f"bad:{bad} posts={posts}")
PY
)
assert_equals "ok" "$USERNAMES" "every published webhook username is free of the forbidden words"
CREATES_BEFORE=$(world_get thread_creates)
POSTS_BEFORE=$(world_get posts)
python3 - "$TMP_ROOT/oversized.md" <<'PY'
import sys
open(sys.argv[1], "w").write("x" * 1995 + "\n")
PY
out=$(mirror artifact --config "$H/config/discord-session-mirror.json" --task m-discord-artifact --kind report \
  --title "Rapport" --body-file "$TMP_ROOT/oversized.md" 2>&1) && fail "an artifact whose title and body exceed Discord's content limit was sent" || true
assert_contains "$out" "Discord accepts at most 2000" "an over-long artifact is refused with Discord's real budget"
[ "$(world_get thread_creates)" = "$CREATES_BEFORE" ] || fail "the refused artifact still created a thread"
[ "$(world_get posts)" = "$POSTS_BEFORE" ] || fail "the refused artifact still posted"
pass "the artifact path clears Discord's username and content-length rules before the call"
