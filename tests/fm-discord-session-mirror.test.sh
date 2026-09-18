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
        elif len(parts) == 4 and parts[0] == "guilds" and parts[2:] == ["threads", "active"]:
            guild = parts[1]
            self._send(200, {"threads": [t for t in world.get("threads", []) if t.get("guild_id") == guild]})
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
        if len(parts) == 3 and parts[0] == "channels" and parts[2] == "threads":
            forum = next((c for c in world.get("channels", []) if c["id"] == parts[1]), None)
            if forum is None:
                self._send(404, {"message": "Unknown Channel"})
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
            thread = next((t for t in world.get("threads", []) if t["id"] == parts[1]), None)
            if thread is None:
                self._send(404, {"message": "Unknown Channel"})
                return
            if "applied_tags" in body:
                thread["applied_tags"] = list(body["applied_tags"] or [])
                world["tag_patches"] = int(world.get("tag_patches", 0)) + 1
            save(world)
            self._send(200, thread)
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
  "thread_creates": 0,
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

echo "fm-discord-session-mirror tests passed"
