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
import json, re, sys
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
            body_text = raw.decode("utf-8", "replace")
            fields = dict(re.findall(r'name="([A-Za-z_]+)"\r\n\r\n([^\r]*)\r\n', body_text))
            filename = (re.search(r'filename="([^"]*)"', body_text) or [None, ""])[1]
            world["groq_calls"] = int(world.get("groq_calls", 0)) + 1
            per_file = world.setdefault("groq_calls_by_filename", {})
            per_file[filename] = int(per_file.get(filename, 0)) + 1
            call_index = per_file[filename]
            requests = world.setdefault("groq_requests", [])
            requests.append({"filename": filename, "call": call_index,
                             "model": fields.get("model"), "language": fields.get("language"),
                             "prompt": fields.get("prompt"), "response_format": fields.get("response_format"),
                             "temperature": fields.get("temperature")})
            del requests[:-50]
            save(world)
            if int(world.get("groq_status", 200)) != 200:
                self._send(int(world["groq_status"]), {"error": {"message": "bad audio " + KEY}})
                return
            fail_at = (world.get("groq_fail_at_call") or {}).get(filename)
            if fail_at is not None and call_index >= int(fail_at):
                self._send(500, {"error": {"message": "reading refused " + KEY}})
                return
            sequence = (world.get("groq_transcripts_by_filename") or {}).get(filename)
            if isinstance(sequence, list) and sequence:
                text = sequence[min(call_index - 1, len(sequence) - 1)]
            else:
                text = world.get("transcript", "Bonjour, ceci est un test.")
            self._send(200, {"text": text})
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
                       "components": body.get("components"),
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

# --- 1b. the configured language, model, and vocabulary prompt are sent -------
readings=$(python3 - "$WORLD" <<'PY'
import json, sys
requests = [r for r in (json.load(open(sys.argv[1])).get("groq_requests") or [])
            if r["filename"] == "voice-message.ogg"]
if len(requests) != 2:
    print(f"expected two readings of the channel voice message, saw {requests}")
else:
    first, second = requests
    ok = (
        first["model"] == "whisper-large-v3"
        and first["language"] == "fr"
        and first["response_format"] == "json"
        and first["prompt"].startswith("Hermes, Firstmate, ProApplis")
        and first["prompt"] == second["prompt"]
        and second["language"] == "fr"
        and first["temperature"] == "0"
        and second["temperature"] != "0"
    )
    print("ok" if ok else f"bad:{first} {second}")
PY
)
assert_equals "ok" "$readings" "the pinned model, French, and the vocabulary prompt reach every reading, and the second reading differs only in temperature"

# --- 1c. agreement leaves the transcript unmarked ----------------------------
AGREED=$(python3 - "$WORLD" "$H" "$CH" <<'PY'
import json, os, sys
world, home, ch = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
posts = [m["content"] for m in world.get("posts", {}).get(ch, [])]
directory = f"{home}/state/discord-workspace/conversation-console/transcripts"
records = [json.load(open(os.path.join(directory, name))) for name in os.listdir(directory)]
ok_records = [r for r in records if r.get("status") == "ok"]
assert len(ok_records) == 2, records
assert all(r.get("confidence", {}).get("status") == "agree" for r in ok_records), ok_records
assert "Transcription : Quel est l'etat de la flotte ?" in posts, posts
assert not [p for p in posts if "incertaine" in p], posts
print("ok")
PY
)
assert_equals "ok" "$AGREED" "two readings that agree are delivered unmarked and recorded as agreement"

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

# --- 6. an uncertain transcription is marked, never silently trusted --------
# One fresh home on its own channel, so each case is one attachment with its own
# scripted readings: agreement is delivered unmarked, a disagreement and a failed
# second reading are marked for the captain to confirm, and a long audio is read
# once only, so the extra call stays bounded to short phrases.
CH2=666000000000000002
CONF_OK=777000000000000011
CONF_BAD=777000000000000012
CONF_FAIL=777000000000000013
CONF_LONG=777000000000000014
python3 - "$WORLD" "$GUILD" "$CH2" "$CAPTAIN" "$CONF_OK" "$CONF_BAD" "$CONF_FAIL" "$CONF_LONG" <<'PY'
import json, sys
world_path, guild, ch2, captain = sys.argv[1:5]
ok_id, bad_id, fail_id, long_id = sys.argv[5:9]
world = json.load(open(world_path))
existing = next(iter(world["messages"]))
cdn = world["messages"][existing][0]["attachments"][0]["url"].rsplit("/cdn/", 1)[0]

def audio(message_id, attachment_id, name, secs):
    return {"id": message_id, "content": "", "author": {"id": captain}, "channel_id": ch2, "flags": 8192,
            "attachments": [{"id": attachment_id, "filename": name, "size": 204,
                             "url": f"{cdn}/cdn/{name}", "content_type": "audio/ogg", "duration_secs": secs}]}

world["groq_status"] = 200
world["channels"][ch2] = {"id": ch2, "type": 0, "guild_id": guild}
world["messages"][ch2] = [
    audio("666000000000000900", ok_id, "confidence-ok.ogg", 3.0),
    audio("666000000000000901", bad_id, "confidence-bad.ogg", 3.0),
    audio("666000000000000902", fail_id, "confidence-fail.ogg", 3.0),
    audio("666000000000000903", long_id, "confidence-long.ogg", 45.0),
]
world["groq_transcripts_by_filename"] = {
    # A second reading that hears the same sentence with one word more still
    # agrees, so an ordinary decode difference is not marked as doubt.
    "confidence-ok.ogg": ["confidence-task ou en es tu maintenant ?", "Confidence-task, ou en es tu ?"],
    "confidence-bad.ogg": ["confidence-task, tu es a l'arret la ?", "Salut a tous !"],
    "confidence-fail.ogg": ["confidence-task, tu es a l'ecoute ?", "confidence-task, tu es a l'ecoute ?"],
    "confidence-long.ogg": ["confidence-task, message long", "confidence-task, message long"],
}
world["groq_fail_at_call"] = {"confidence-fail.ogg": 2}
json.dump(world, open(world_path, "w"))
PY

cat > "$TMP_ROOT/fast-classifier" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null
printf '{"verdict": "fast_answer", "flag": "answer_from_records", "confidence": 0.97, "reason": "test fixture"}\n'
FAKE
chmod +x "$TMP_ROOT/fast-classifier"
cat > "$TMP_ROOT/fake-crew-state" <<'FAKE'
#!/usr/bin/env bash
printf 'state: working \xc2\xb7 source: run-step \xc2\xb7 test fixture\n'
FAKE
chmod +x "$TMP_ROOT/fake-crew-state"
export FM_CONSOLE_CREW_STATE_CMD="$TMP_ROOT/fake-crew-state"

make_home h7
CONF_CFG="$H/config/discord-conversation-console.json"
python3 - "$CONF_CFG" "$CH2" "$TMP_ROOT/fast-classifier" <<PY
import json, sys
path, ch2, classifier = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
data["channels"] = [{"label": "Confidence", "guild_id": "$GUILD", "channel_id": ch2}]
data["fast_path"]["classifier_command"] = classifier
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
touch "$H/state/confidence-task.meta"
out=$(dc listen --config "$CONF_CFG" 2>&1) || fail "confidence listen failed: $out"
assert_contains "$out" "captured=4" "all four confidence-case audio messages are captured"
CONFIDENCE_OK=$(python3 - "$WORLD" "$H" "$CH2" "$GROQ_KEY" <<'PY'
import json, os, sys
world, home, ch2, key = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
requests = world.get("groq_requests") or []
by_name = {}
for request in requests:
    by_name.setdefault(request["filename"], []).append(request)
# the two readings differ only in temperature, and never leave the French route
temperatures = [r["temperature"] for r in by_name.get("confidence-ok.ogg", [])]
assert temperatures == ["0", "0.6"], temperatures
assert all(r["language"] == "fr" for r in requests), requests
assert all(r["model"] == "whisper-large-v3" for r in requests), requests
assert len(by_name.get("confidence-long.ogg", [])) == 1, "a long audio is read once and never checked"
posts = [m["content"] for m in world.get("posts", {}).get(ch2, [])]
marked = [p for p in posts if p.startswith("Transcription incertaine")]
assert "Transcription : confidence-task ou en es tu maintenant ?" in posts, posts
assert any("confidence-task, tu es a l'arret la ?" in p for p in marked), posts
assert any("confidence-task, tu es a l'ecoute ?" in p for p in marked), posts
# the fast path still answers the two settled readings, and only those
assert posts.count("On it - checking the records.") == 2, posts
assert len([p for p in posts if "confidence-task is in progress." in p]) == 2, posts
notes_dir = os.path.join(home, "state", "inbox")
notes = [open(os.path.join(notes_dir, n), encoding="utf-8").read()
         for n in sorted(os.listdir(notes_dir)) if n.endswith(".note")]
assert len(notes) == 2, f"exactly the two uncertain readings take the full turn, saw {len(notes)}"
for note in notes:
    assert "transcription-uncertain:" in note, note
    assert "ask the captain to confirm the spoken words" in note, note
assert len([n for n in notes if "transcription-second-reading: Salut a tous !" in n]) == 1, notes
assert len([n for n in notes if "the second reading of the same audio failed" in n]) == 1, notes
directory = f"{home}/state/discord-workspace/conversation-console/transcripts"
records = [json.load(open(os.path.join(directory, name))) for name in os.listdir(directory)]
assert sorted(r["confidence"]["status"] for r in records) == ["agree", "disagree", "skipped", "unavailable"], records
by_status = {r["confidence"]["status"]: r["confidence"] for r in records}
assert by_status["agree"]["uncertain"] is False and by_status["skipped"]["checked"] is False, by_status
assert by_status["disagree"]["uncertain"] is True and by_status["unavailable"]["uncertain"] is True, by_status
assert by_status["disagree"]["alternate"] == "Salut a tous !", by_status
for text in notes + posts:
    assert key not in text, "the transcription key must never reach a note or a post"
print("ok")
PY
)
assert_equals "ok" "$CONFIDENCE_OK" "agreement stays unmarked, disagreement and a failed check are marked, and a long audio is read once"

# --- 6b. the comparison rule itself, at the module boundary ------------------
RULE=$(python3 - "$ROOT" <<'PY'
import importlib.util as util, sys
spec = util.spec_from_file_location("whisper", f"{sys.argv[1]}/bin/fm_groq_whisper.py")
whisper = util.module_from_spec(spec)
spec.loader.exec_module(whisper)
cases = [
    # the reported mishearing, and second readings of the same sentence
    ("Tu es a l'arret la ?", "Salut a tous !", False),
    ("Tu es a l'arret la ?", "Tu es a l arret la", True),
    ("Quel est l'etat de la flotte ?", "Quel etat de la flotte", True),
    ("Vous etes arrete maintenant ?", "Vous etes arrete ?", True),
    ("Tu es a l'arret la ?", "Tu es", False),
    ("", "Salut", False),
]
bad = [case for case in cases if whisper.transcripts_agree(case[0], case[1])[0] is not case[2]]
print("ok" if not bad else f"bad:{bad}")
PY
)
assert_equals "ok" "$RULE" "the reading comparison keeps the same words together and separates a different sentence"
CONF_LEAK=$(grep -r "$GROQ_KEY" "$H/state" 2>/dev/null | head -1 || true)
assert_equals "" "$CONF_LEAK" "the transcription key never reaches an uncertainty record"
CONF_STATUS=$(dc status --config "$CONF_CFG" 2>&1) || fail "confidence status failed: $CONF_STATUS"
assert_contains "$CONF_STATUS" "transcription confidence check: on" "status reports the confidence check"
pass "an uncertain transcription carries a visible marker into the note and the thread"

# --- 6c. an uncertain reading carries a confirmation card the captain presses --
# The card is the affordance the captain asked for, and it rides the existing
# card machinery: it is posted only where a press could arrive, it carries the
# three existing card actions, one card follows one reading, and a replay posts
# no second card and no second transcript.
CH4=666000000000000004
CARD_BAD=777000000000000041
CARD_GOOD=777000000000000042
python3 - "$WORLD" "$GUILD" "$CH4" "$CAPTAIN" "$CARD_BAD" "$CARD_GOOD" <<'PY'
import json, sys
world_path, guild, ch4, captain = sys.argv[1:5]
bad_id, good_id = sys.argv[5:7]
world = json.load(open(world_path))
existing = next(iter(world["messages"]))
cdn = world["messages"][existing][0]["attachments"][0]["url"].rsplit("/cdn/", 1)[0]

def audio(message_id, attachment_id, name, secs):
    return {"id": message_id, "content": "", "author": {"id": captain}, "channel_id": ch4, "flags": 8192,
            "attachments": [{"id": attachment_id, "filename": name, "size": 204,
                             "url": f"{cdn}/cdn/{name}", "content_type": "audio/ogg", "duration_secs": secs}]}

world["channels"][ch4] = {"id": ch4, "type": 0, "guild_id": guild}
world["messages"][ch4] = [
    audio("666000000000001100", bad_id, "card-bad.ogg", 3.0),
    audio("666000000000001101", good_id, "card-good.ogg", 3.0),
]
world.setdefault("groq_transcripts_by_filename", {})["card-bad.ogg"] = ["confidence-task, tu es a l'arret la ?", "Salut a tous !"]
world["groq_transcripts_by_filename"]["card-good.ogg"] = ["confidence-task ou en es tu maintenant ?", "Confidence-task, ou en es tu ?"]
json.dump(world, open(world_path, "w"))
PY
make_home h9
CARD_CFG="$H/config/discord-conversation-console.json"
python3 - "$CARD_CFG" "$CH4" <<PY
import json, sys
path, ch4 = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["channels"] = [{"label": "Cards", "guild_id": "$GUILD", "channel_id": ch4}]
data["live"]["gateway"] = True
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
mkdir -p "$H/state/procevent"
touch "$H/state/procevent/discord-conversation-console-gateway.source"
out=$(dc listen --config "$CARD_CFG" 2>&1) || fail "confirmation-card listen failed: $out"
assert_contains "$out" "captured=2" "both confirmation-card audio messages are captured"
CARD_POST=$(python3 - "$WORLD" "$H" "$CH4" "$GUILD" <<'PY'
import glob, json, os, sys
world, home, ch4, guild = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
posts = world.get("posts", {}).get(ch4, [])
cards = [m for m in posts if m.get("components")]
assert len(cards) == 1, f"exactly one card, for the uncertain reading only: {posts}"
card = cards[0]
assert card["content"].startswith("Transcription incertaine - \u00e0 confirmer : "), card["content"]
assert "confidence-task, tu es a l'arret la ?" in card["content"], card["content"]
row = card["components"]
assert len(row) == 1 and row[0]["type"] == 1, row
buttons = row[0]["components"]
assert [b["label"] for b in buttons] == ["C'est bien \u00e7a", "Je corrige", "\u00c0 jeter"], buttons
assert [b["style"] for b in buttons] == [3, 2, 4], buttons
assert [b["type"] for b in buttons] == [2, 2, 2], buttons
records = [json.load(open(p)) for p in glob.glob(f"{home}/state/discord-workspace/conversation-console/cards/*.json")]
assert len(records) == 1, records
record = records[0]
assert record["kind"] == "transcript" and record["task_id"] == "", record
assert record["status"] == "open" and record["request_id"] == f"discord:{guild}:{ch4}:666000000000001100", record
assert record["message_id"] == card["id"], (record, card)
assert [b["custom_id"] for b in buttons] == [f"fmcard:{record['card_id']}:{index}" for index in range(3)], (buttons, record)
assert [option["action"] for option in record["options"]] == ["answer", "chat", "release"], record
transcripts = [json.load(open(p)) for p in glob.glob(f"{home}/state/discord-workspace/conversation-console/transcripts/*.json")]
uncertain = [r for r in transcripts if (r.get("confidence") or {}).get("uncertain")]
assert len(uncertain) == 1, transcripts
assert uncertain[0]["confirm_card"] == {"status": "posted", "card_id": record["card_id"]}, uncertain[0]
settled = [r for r in transcripts if r.get("status") == "ok" and not (r.get("confidence") or {}).get("uncertain")]
assert len(settled) == 1 and "confirm_card" not in settled[0], settled
notes = [open(os.path.join(home, "state", "inbox", n), encoding="utf-8").read()
         for n in sorted(os.listdir(os.path.join(home, "state", "inbox"))) if n.endswith(".note")]
assert len(notes) == 2, notes
with_card = [n for n in notes if "transcription-confirmation-card:" in n]
assert len(with_card) == 1, notes
assert f"transcription-confirmation-card: the conversation carries a card for this reading (card {record['card_id']})" in with_card[0], with_card[0]
assert "transcription-uncertain:" in with_card[0] and "ask the captain to confirm the spoken words" in with_card[0], with_card[0]
print("ok")
PY
)
assert_equals "ok" "$CARD_POST" "the uncertain reading carries one confirmation card with the three existing card actions"
CARD_STATUS=$(dc status --config "$CARD_CFG" 2>&1) || fail "confirmation-card status failed: $CARD_STATUS"
assert_contains "$CARD_STATUS" "transcription confirmation card: on" "status reports the confirmation card switch"
assert_contains "$CARD_STATUS" "transcript confirmation cards: 1 posted, 1 open" "status reports the posted confirmation card"
POSTS_BEFORE_CARD_REPLAY=$(world_get 'len(world.get("posts", {}).get("666000000000000004", []))')
rm -rf "$H/state/discord-workspace/conversation-console/cursors"
out=$(dc listen --config "$CARD_CFG" 2>&1) || fail "confirmation-card replay failed: $out"
assert_equals "$POSTS_BEFORE_CARD_REPLAY" "$(world_get 'len(world.get("posts", {}).get("666000000000000004", []))')" \
  "a replay posts no second card and no second transcript"
CARD_REPLAY=$(python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
records = [json.load(open(p)) for p in cards]
print("ok" if len(records) == 1 and records[0]["status"] == "open" else f"bad:{records}")
PY
)
assert_equals "ok" "$CARD_REPLAY" "a replayed reading keeps its one open confirmation card"
pass "an uncertain reading carries a confirmation card the captain can press, once"

# --- 7. an uploaded audio file takes the voice message's transcription path --
# The captain can send an audio file rather than a Discord voice message: the
# message carries no voice flag, only one supported audio attachment and no
# caption. It must be downloaded, transcribed, shown, and captured on the same
# path, and the durable record must name which of the two kinds it was.
CH3=666000000000000003
UPLOAD_ID=777000000000000021
MULTI_A=777000000000000022
MULTI_B=777000000000000023
python3 - "$WORLD" "$GUILD" "$CH3" "$CAPTAIN" "$UPLOAD_ID" "$MULTI_A" "$MULTI_B" <<'PY'
import json, sys
(world_path, guild, ch3, captain, upload_id, multi_a, multi_b) = sys.argv[1:8]
world = json.load(open(world_path))
existing = next(iter(world["messages"]))
cdn = world["messages"][existing][0]["attachments"][0]["url"].rsplit("/cdn/", 1)[0]

def upload_attachment(att_id, name):
    return {"id": att_id, "filename": name, "size": 204, "url": f"{cdn}/cdn/{name}",
            "content_type": "audio/ogg", "duration_secs": 4.0}

world["groq_status"] = 200
world["channels"][ch3] = {"id": ch3, "type": 0, "guild_id": guild}
world["messages"][ch3] = [
    {"id": "666000000000001000", "content": "", "author": {"id": captain}, "channel_id": ch3,
     "flags": 0, "attachments": [upload_attachment(upload_id, "note-vocale.ogg")]},
    {"id": "666000000000001001", "content": "", "author": {"id": captain}, "channel_id": ch3,
     "flags": 0, "attachments": [upload_attachment(multi_a, "a.ogg"), upload_attachment(multi_b, "b.ogg")]},
]
world.setdefault("groq_transcripts_by_filename", {})["note-vocale.ogg"] = ["fichier audio importe"]
json.dump(world, open(world_path, "w"))
PY
make_home h8
UPLOAD_CFG="$H/config/discord-conversation-console.json"
python3 - "$UPLOAD_CFG" "$CH3" <<PY
import json, sys
path, ch3 = sys.argv[1], sys.argv[2]
data = json.load(open(path))
data["channels"] = [{"label": "Uploads", "guild_id": "$GUILD", "channel_id": ch3}]
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(dc listen --config "$UPLOAD_CFG" 2>&1) || fail "uploaded-audio listen failed: $out"
assert_contains "$out" "captured=1" "an uploaded audio file is transcribed and captured"
assert_contains "$out" "ignored=1" "a caption-less message with two audio files is refused, not crashed"
UPLOAD_OK=$(python3 - "$WORLD" "$H" "$CH3" <<'PY'
import json, os, sys
world, home, ch3 = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
posts = [m["content"] for m in world.get("posts", {}).get(ch3, [])]
assert "Transcription : fichier audio importe" in posts, posts
directory = f"{home}/state/discord-workspace/conversation-console/transcripts"
records = [json.load(open(os.path.join(directory, n))) for n in os.listdir(directory)]
ok = [r for r in records if r.get("status") == "ok"]
assert len(ok) == 1, records
assert ok[0]["audio_kind"] == "audio-upload", ok
assert ok[0]["text"] == "fichier audio importe", ok
failed = [r for r in records if r.get("status") == "failed"]
assert len(failed) == 1, records
assert "exactly one supported audio attachment" in failed[0]["reason"], failed
assert any("Je n'ai pas pu transcrire" in p for p in posts), posts
notes_dir = os.path.join(home, "state", "inbox")
notes = [open(os.path.join(notes_dir, n), encoding="utf-8").read()
         for n in sorted(os.listdir(notes_dir)) if n.endswith(".note")]
assert len(notes) == 1 and "fichier audio importe" in notes[0], notes
print("ok")
PY
)
assert_equals "ok" "$UPLOAD_OK" "the uploaded audio is transcribed once and recorded as an upload, and a two-file message fails honestly"
UPLOAD_LEAK=$(grep -r "$FAKE_TOKEN\|$GROQ_KEY" "$H/state" 2>/dev/null | head -1 || true)
assert_equals "" "$UPLOAD_LEAK" "the uploaded-audio path leaks no token and no transcription key"
pass "an uploaded audio file takes the same transcription path as a voice message"

echo "# all fm-discord-conversation-console-audio tests passed"
