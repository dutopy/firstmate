#!/usr/bin/env bash
# Behavior tests for Discord conversation-console audio transcription.
#
# Everything runs against a fake local HTTP server that stands in for both the
# Discord REST API and the Groq transcription API, so no real token, key, or
# network call leaves loopback. Covers a captain voice message becoming the
# message text and being answered in its thread, the transcript shown in the
# thread, exactly-once transcription across a replay, the temporary audio being
# deleted, the API key and bot token never reaching a durable record, a corrupt
# and an oversized audio producing an honest reply instead of a crash, and an
# explicitly disabled transcription leaving audio ignored as before.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-conversation-console-audio-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
CH=666000000000000001
T1=666000000000000011
FAKE_TOKEN=faketoken-abc123
GROQ_KEY=groq-test-key

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }

cleanup_audio() {
  kill %1 2>/dev/null || true
  [ -n "${H:-}" ] && FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_audio EXIT

note_count() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

world_get() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
print(json.dumps(eval(sys.argv[2], {}, {"world": world})))
PY
}

world_set() { python3 - "$WORLD" "$1" <<'PY'
import json, sys
world, update = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
world.update(update)
json.dump(world, open(sys.argv[1], "w"))
PY
}

start_server() { # start_server <world-file> <port-file>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" "$GROQ_KEY" > "$TMP_ROOT/fake-server.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

WORLD, PORT_FILE, TOKEN, KEY = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
BOT = "333333333333333333"
AUDIO = b"OggS" + b"\x00" * 200


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

    def _send_bytes(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _discord_authorized(self, world):
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
        if parts and parts[0] == "cdn":
            size = int((world.get("cdn_sizes") or {}).get(parts[-1], world.get("cdn_size") or len(AUDIO)))
            self._send_bytes(200, AUDIO + b"\x00" * max(0, size - len(AUDIO)), "audio/ogg")
            return
        if not self._discord_authorized(world):
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
        raw = self.rfile.read(length) if length else b""
        world = load()
        if parts[:3] == ["openai", "v1", "audio"] and parts[3:] == ["transcriptions"]:
            if self.headers.get("Authorization") != f"Bearer {KEY}":
                self._send(401, {"error": {"message": "bad key " + KEY}})
                return
            world["groq_calls"] = int(world.get("groq_calls", 0)) + 1
            save(world)
            if int(world.get("groq_status", 200)) != 200:
                self._send(int(world["groq_status"]), {"error": {"message": "bad audio"}})
            else:
                self._send(200, {"text": world.get("transcript", "Bonjour, ceci est un test.")})
            return
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            body = {}
        if not self._discord_authorized(world):
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 3 and parts[2] == "typing":
            self._send(200, {})
        elif len(parts) == 3 and parts[2] == "messages":
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
  [ -s "$2" ] || fail "fake server did not start"
}

make_home() { # make_home <name>
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state" "$H/data" "$H/config"
  chmod 700 "$H/state"
  FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
  python3 - "$H/config/discord-conversation-console.json" "$PORT" <<PY
import json, sys
path, port = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["bot"]["user_id"] = "$BOT"
data["captain_user_ids"] = ["$CAPTAIN"]
data["channels"] = [{"label": "Internal", "guild_id": "$GUILD", "channel_id": "$CH"}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["fast_path"]["enabled"] = True
data["fast_path"]["typing"] = False
data["fast_path"]["classifier_command"] = "$TMP_ROOT/no-such-classifier"
data["audio"]["max_bytes"] = 1000
data["audio"]["allowed_cdn_hosts"] = ["127.0.0.1"]
data["transcription"]["enabled"] = True
data["transcription"]["api_key"] = "GROQ_API_KEY"
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
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
CDN_ID=777000000000000001
AUDIO_ID=777000000000000002
OVERSIZE_ID=777000000000000003
OVERFLOW_ID=777000000000000004
python3 - "$WORLD" "$GUILD" "$CH" "$T1" "$CAPTAIN" "$BOT" "$CDN_ID" "$AUDIO_ID" "$OVERSIZE_ID" "$OVERFLOW_ID" <<'PY'
import json, sys
(world_path, guild, ch, t1, captain, bot, cdn_id, audio_id, oversize_id, overflow_id) = sys.argv[1:11]
world = {
    "token": None,
    "counter": 900000000000000000,
    "groq_calls": 0,
    "cdn_sizes": {"overflow.ogg": 2048},
    "transcript": "Quel est l'etat de la flotte ?",
    "threads": {guild: [{"id": t1, "parent_id": ch}]},
    "archived": {},
    "channels": {ch: {"id": ch, "type": 0, "guild_id": guild},
                 t1: {"id": t1, "type": 11, "parent_id": ch, "guild_id": guild}},
    "messages": {
        ch: [
            {"id": "666000000000000100", "content": "", "author": {"id": captain}, "channel_id": ch,
             "flags": 8192, "attachments": [{"id": audio_id, "filename": "voice-message.ogg", "size": 204,
                                             "url": f"http://127.0.0.1:CDN_PORT/cdn/voice.ogg", "content_type": "audio/ogg",
                                             "duration_secs": 3.5}]},
            {"id": "666000000000000102", "content": "", "author": {"id": captain}, "channel_id": ch,
             "flags": 8192, "attachments": [{"id": oversize_id, "filename": "big.ogg", "size": 99999,
                                             "url": f"http://127.0.0.1:CDN_PORT/cdn/big.ogg", "content_type": "audio/ogg",
                                             "duration_secs": 3.5}]},
            {"id": "666000000000000103", "content": "", "author": {"id": captain}, "channel_id": ch,
             "flags": 8192, "attachments": [{"id": overflow_id, "filename": "overflow.ogg", "size": 100,
                                             "url": f"http://127.0.0.1:CDN_PORT/cdn/overflow.ogg", "content_type": "audio/ogg",
                                             "duration_secs": 3.5}]},
        ],
        t1: [
            {"id": "666000000000000200", "content": "", "author": {"id": captain}, "channel_id": t1,
             "flags": 8192, "attachments": [{"id": cdn_id, "filename": "thread-voice.ogg", "size": 204,
                                             "url": f"http://127.0.0.1:CDN_PORT/cdn/thread.ogg", "content_type": "audio/ogg",
                                             "duration_secs": 2.0}]},
        ],
    },
    "posts": {},
}
json.dump(world, open(world_path, "w"))
PY
start_server "$WORLD" "$PORT_FILE"
PORT=$(cat "$PORT_FILE")
python3 - "$WORLD" "$PORT" <<'PY'
import json, sys
path, port = sys.argv[1], sys.argv[2]
world = json.load(open(path))
for group in world["messages"].values():
    for message in group:
        for attachment in message.get("attachments", []):
            attachment["url"] = attachment["url"].replace("CDN_PORT", port)
json.dump(world, open(path, "w"))
PY
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0
export FM_GROQ_API_BASE="http://127.0.0.1:$PORT/openai/v1"
export FM_DISCORD_ALLOW_INSECURE_CDN=127.0.0.1
export GROQ_API_KEY="$GROQ_KEY"

make_home h1
CFG="$H/config/discord-conversation-console.json"

# --- 1. a voice message becomes the message and is transcribed once ----------
LOG="$TMP_ROOT/h1-listen.log"
out=$(dc listen --config "$CFG" 2>&1) || fail "listen failed: $out"
printf '%s\n' "$out" > "$LOG"
# The overflow attachment streams more bytes than the cap, so that message is a
# bounded failure; the good channel and thread voice messages are transcribed.
assert_contains "$out" "captured=2" "two voice messages are transcribed and captured"
assert_contains "$out" "ignored=2" "the oversized and overflow attachments are handled without a crash"
assert_equals "2" "$(note_count "$H")" "one durable note per successfully transcribed voice message"
NOTES=$(cat "$H"/state/inbox/*.note)
assert_contains "$NOTES" "Quel est l'etat de la flotte ?" "the note carries the transcript as its content"
assert_contains "$NOTES" "Groq Whisper large-v3" "the note records that it came from a transcription"
assert_contains "$NOTES" "answer with: bin/fm-discord-conversation-console.sh reply --request-id discord:$GUILD:" "the transcribed note keeps the reply command"

POSTS_OK=$(python3 - "$WORLD" "$CH" "$T1" <<'PY'
import json, sys
world, ch, t1 = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
root = [m["content"] for m in world.get("posts", {}).get(ch, [])]
thread = [m["content"] for m in world.get("posts", {}).get(t1, [])]
ok = (
    "Transcription : Quel est l'etat de la flotte ?" in root
    and "On it - checking the records." in root
    and "Transcription : Quel est l'etat de la flotte ?" in thread
)
print("ok" if ok else f"bad:root={root!r} thread={thread!r}")
PY
)
assert_equals "ok" "$POSTS_OK" "the transcript and acknowledgement are shown in the channel and the thread"
printf 'Reponse a la question vocale\n' > "$TMP_ROOT/audio-answer.txt"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$T1:666000000000000200" --text-file "$TMP_ROOT/audio-answer.txt" 2>&1) \
  || fail "thread reply to a voice message failed: $out"
assert_contains "$out" "replied in conversation $T1" "the answer to a voice message returns to its thread"
REPLY_OK=$(python3 - "$WORLD" "$CH" "$T1" <<'PY'
import json, sys
world, ch, t1 = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
root = [m["content"] for m in world.get("posts", {}).get(ch, [])]
thread = [m["content"] for m in world.get("posts", {}).get(t1, [])]
print("ok" if "Reponse a la question vocale" in thread and "Reponse a la question vocale" not in root else f"bad:root={root!r} thread={thread!r}")
PY
)
assert_equals "ok" "$REPLY_OK" "a transcribed thread message keeps its thread identity for the answer"

AUDIO_GONE=$(python3 - "$H" <<'PY'
import sys
from pathlib import Path
tmp = Path(sys.argv[1]) / "state/discord-workspace/conversation-console/audio-tmp"
left = [p.name for p in tmp.glob("*")] if tmp.is_dir() else []
print("ok" if not left else f"left:{left}")
PY
)
assert_equals "ok" "$AUDIO_GONE" "the temporary audio file is deleted after transcription"

LEAK=$(grep -r "$FAKE_TOKEN\|$GROQ_KEY" "$H/state" 2>/dev/null | head -1 || true)
assert_equals "" "$LEAK" "neither the bot token nor the transcription key reaches durable state"
printf '%s' "$(cat "$LOG")" | grep -q "$GROQ_KEY" && fail "the transcription key leaked into the listener output"
printf '%s' "$(cat "$LOG")" | grep -q "$FAKE_TOKEN" && fail "the bot token leaked into the listener output"
pass "a voice message is transcribed, shown, and captured without leaking a secret"

# --- 2. a replay never re-transcribes or re-posts ---------------------------
CALLS_BEFORE=$(world_get 'world["groq_calls"]')
POSTS_BEFORE=$(world_get 'sum(len(v) for v in world.get("posts", {}).values())')
rm -rf "$H/state/discord-workspace/conversation-console/cursors"
out=$(dc listen --config "$CFG" 2>&1) || fail "replay listen failed: $out"
assert_equals "2" "$(note_count "$H")" "a replay appends no second note"
assert_equals "$CALLS_BEFORE" "$(world_get 'world["groq_calls"]')" "a replay makes no second Groq transcription call"
assert_equals "$POSTS_BEFORE" "$(world_get 'sum(len(v) for v in world.get("posts", {}).values())')" "a replay posts no second transcript"
pass "transcription is exactly once across a replay"

# --- 3. a failing transcription is an honest reply, not a crash -------------
world_set '{"groq_status": 500}'
python3 - "$WORLD" "$CH" "$CAPTAIN" "$BOT" <<'PY'
import json, sys
path, ch, captain, bot = sys.argv[1:5]
world = json.load(open(path))
world["messages"][ch].append({
    "id": "666000000000000104", "content": "", "author": {"id": captain}, "channel_id": ch,
    "flags": 8192, "attachments": [{"id": "777000000000000005", "filename": "corrupt.ogg", "size": 204,
                                     "url": world["messages"][ch][0]["attachments"][0]["url"].replace("voice.ogg", "corrupt.ogg"),
                                     "content_type": "audio/ogg", "duration_secs": 1.0}],
})
json.dump(world, open(path, "w"))
PY
H="$TMP_ROOT/h3"
mkdir -p "$H/state" "$H/data" "$H/config"
chmod 700 "$H/state"
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
python3 - "$H/config/discord-conversation-console.json" <<PY
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["bot"]["user_id"] = "$BOT"
data["captain_user_ids"] = ["$CAPTAIN"]
data["channels"] = [{"label": "Internal", "guild_id": "$GUILD", "channel_id": "$CH"}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["audio"]["max_bytes"] = 1000
data["audio"]["allowed_cdn_hosts"] = ["127.0.0.1"]
data["transcription"]["enabled"] = True
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
CFG3="$H/config/discord-conversation-console.json"
out=$(dc listen --config "$CFG3" 2>&1) || fail "a failing transcription crashed the listener: $out"
FAIL_POSTS=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
world, ch = json.load(open(sys.argv[1])), sys.argv[2]
root = [m["content"] for m in world.get("posts", {}).get(ch, [])]
hits = [c for c in root if "Je n'ai pas pu transcrire" in c]
print("ok" if len(hits) >= 1 else f"bad:{root!r}")
PY
)
assert_equals "ok" "$FAIL_POSTS" "a failed transcription posts one honest French line in the thread"
assume_ok=$(python3 - "$H" <<'PY'
import json, sys
from pathlib import Path
failed = [p for p in (Path(sys.argv[1]) / "state/discord-workspace/conversation-console/transcripts").glob("*.json")
          if json.loads(p.read_text()).get("status") == "failed"]
print("ok" if failed else "missing")
PY
)
assert_equals "ok" "$assume_ok" "the failed transcription is recorded durably"
AUDIO_GONE=$(python3 - "$H" <<'PY'
import sys
from pathlib import Path
tmp = Path(sys.argv[1]) / "state/discord-workspace/conversation-console/audio-tmp"
left = [p.name for p in tmp.glob("*")] if tmp.is_dir() else []
print("ok" if not left else f"left:{left}")
PY
)
assert_equals "ok" "$AUDIO_GONE" "the temporary audio is deleted after a failed transcription too"
pass "a corrupt or oversized audio produces a clear message, not a crash"

# --- 5. the model is pinned away from turbo and a missing key is honest -----
H="$TMP_ROOT/h5"
mkdir -p "$H/state" "$H/data" "$H/config"
chmod 700 "$H/state"
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
python3 - "$H/config/discord-conversation-console.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["transcription"]["enabled"] = True
data["transcription"]["model"] = "whisper-large-v3-turbo"
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(dc config-check --config "$H/config/discord-conversation-console.json" 2>&1) && fail "a turbo model was accepted" || true
assert_contains "$out" "whisper-large-v3" "the model guard refuses anything but the authorized model"

H="$TMP_ROOT/h6"
mkdir -p "$H/state" "$H/data" "$H/config"
chmod 700 "$H/state"
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
python3 - "$H/config/discord-conversation-console.json" <<PY
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["bot"]["user_id"] = "$BOT"
data["captain_user_ids"] = ["$CAPTAIN"]
data["channels"] = [{"label": "Internal", "guild_id": "$GUILD", "channel_id": "$CH"}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["audio"]["allowed_cdn_hosts"] = ["127.0.0.1"]
data["transcription"]["enabled"] = True
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
CFG6="$H/config/discord-conversation-console.json"
out=$(env -u GROQ_API_KEY FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" listen --config "$CFG6" 2>&1) \
  || fail "a missing transcription key crashed the listener: $out"
MISSING=$(python3 - "$WORLD" "$CH" <<'PY'
import json, sys
world, ch = json.load(open(sys.argv[1])), sys.argv[2]
root = [m["content"] for m in world.get("posts", {}).get(ch, [])]
print("ok" if any("Je n'ai pas pu transcrire" in c for c in root) else "missing")
PY
)
assert_equals "ok" "$MISSING" "a missing key is an honest failure, not silence or a crash"
printf '%s' "$out" | grep -q "$FAKE_TOKEN" && fail "the bot token leaked while reporting a missing key"
pass "the model is pinned to large-v3 and a missing key fails honestly"

# --- 4. an explicitly disabled transcription leaves audio ignored -----------
H="$TMP_ROOT/h4"
mkdir -p "$H/state" "$H/data" "$H/config"
chmod 700 "$H/state"
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
python3 - "$H/config/discord-conversation-console.json" <<PY
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["bot"]["user_id"] = "$BOT"
data["captain_user_ids"] = ["$CAPTAIN"]
data["channels"] = [{"label": "Internal", "guild_id": "$GUILD", "channel_id": "$CH"}]
data["live"]["polling"] = True
data["live"]["posting"] = True
data["transcription"]["enabled"] = False
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
CFG4="$H/config/discord-conversation-console.json"
out=$(dc listen --config "$CFG4" 2>&1) || fail "disabled audio listen failed: $out"
assert_equals "0" "$(note_count "$H")" "audio is not captured while transcription is disabled"
DISABLED=$(python3 - "$H" <<'PY'
import json, sys
data = json.load(open(f"{sys.argv[1]}/state/discord-workspace/conversation-console/ignored.json"))
reasons = {r["message_id"]: r["reason"] for r in data["records"]}
hits = [r for r in reasons.values() if r == "audio-transcription-disabled"]
print("ok" if hits else f"bad:{reasons}")
PY
)
assert_equals "ok" "$DISABLED" "a disabled transcription records the audio as ignored"
pass "an explicitly disabled transcription leaves audio on the existing ignored path"

echo "# all fm-discord-conversation-console-audio tests passed"
