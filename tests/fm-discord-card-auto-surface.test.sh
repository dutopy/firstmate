#!/usr/bin/env bash
# Behavior tests for automatic decision-card surfacing.
#
# Covers the hold -> card linkage (one held call, at most one active card, no
# replay after an answer, honest fallback when publication fails), the
# release-versus-answer button semantics, and the bounded escalation that
# mirrors an unanswered card into the dedicated #blocages channel with the same
# durable card identity, resolvable from either surface. Everything runs against
# a fake local HTTP Discord server, so no real token is read and no real Discord
# message is sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-card-auto-surface-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# The escalation delay is read at config load; zero makes every posted card
# immediately eligible unless a test overrides it for a single command.
export FM_CONSOLE_CARD_ESCALATION_DELAY=0

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
CH=666000000000000001
BLOCAGES=666000000000000009
FAKE_TOKEN=faketoken-abc123

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }
hold() { FM_HOME="$H" "$ROOT/bin/fm-captain-hold.sh" "$@"; }

cleanup_console() {
  if [ -n "${H:-}" ]; then
    FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup_console EXIT

start_server() { # start_server <world-file> <port-file>
  setsid python3 - "$1" "$2" "$FAKE_TOKEN" "$GUILD" > "$TMP_ROOT/fake-server.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

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

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {}

    def do_POST(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        body = self._read_body()
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
        body = self._read_body()
        world = load()
        if not self._authorized(world):
            self._send(401, {"message": "Unauthorized"})
            return
        if len(parts) == 4 and parts[2] == "messages":
            channel_id, message_id = parts[1], parts[3]
            for message in world.get("posts", {}).get(channel_id, []):
                if message.get("id") == message_id:
                    message["content"] = body.get("content")
                    message["components"] = body.get("components")
                    message["edited"] = True
                    save(world)
                    self._send(200, message)
                    return
            self._send(404, {"message": "unknown message"})
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
data["cards"]["escalation_channel_id"] = "$BLOCAGES"
data["live"]["polling"] = True
data["live"]["posting"] = True
data["live"]["gateway"] = True
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"
}

WORLD="$TMP_ROOT/world.json"
PORT_FILE="$TMP_ROOT/port"
python3 - "$WORLD" <<'PY'
import json, sys
world = {"token": None, "counter": 900000000000000000, "posts": {}}
json.dump(world, open(sys.argv[1], "w"))
PY
start_server "$WORLD" "$PORT_FILE"
PORT=$(cat "$PORT_FILE")
export FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT"
export FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops"
export FM_DISCORD_LIVE_RETRY_SLEEP=0
cat > "$TMP_ROOT/fake-sops" <<FAKE
#!/usr/bin/env bash
[ "\$1" = "-d" ] || exit 64
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: $FAKE_TOKEN\n'
FAKE
chmod +x "$TMP_ROOT/fake-sops"

if ! command -v tasks-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skip: tasks-axi and jq are required to exercise the automatic card surfacing"
  exit 0
fi

make_home h1
CFG="$H/config/discord-conversation-console.json"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
cat > "$H/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" start --config "$CFG" >/dev/null 2>&1 \
  || fail "card gateway start failed"

card_count() { find "$H/state/discord-workspace/conversation-console/cards" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
card_for_task() { # card_for_task <task-id> -> prints the path of that task's card, if any
  python3 - "$H" "$1" <<'PY'
import glob, json, sys
for path in sorted(glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")):
    if json.load(open(path)).get("task_id") == sys.argv[2]:
        print(path)
        break
PY
}
posts_in_channel() { python3 - "$WORLD" "$1" "$2" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
needle = sys.argv[3]
print(sum(1 for m in world.get("posts", {}).get(sys.argv[2], []) if needle in (m.get("content") or "")))
PY
}
custom_ids_of() { # custom_ids_of <channel-id> <content-needle> -> comma-joined button custom ids
  python3 - "$WORLD" "$1" "$2" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
needle = sys.argv[3]
for message in world.get("posts", {}).get(sys.argv[2], []):
    if needle in (message.get("content") or ""):
        ids = []
        for row in message.get("components") or []:
            for button in row.get("components") or []:
                ids.append(button.get("custom_id"))
        print(",".join(ids))
        break
PY
}
esc_of_task() { # esc_of_task <task-id> -> "<delivered>:<channel>:<message>"
  python3 - "$H" "$1" <<'PY'
import glob, json, sys
for path in glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json"):
    record = json.load(open(path))
    if record.get("task_id") == sys.argv[2]:
        esc = record.get("escalation") or {}
        print(f"{esc.get('delivered')}:{esc.get('channel_id') or ''}:{esc.get('message_id') or ''}")
        break
PY
}

esc() { # esc <config> -> the bounded scan's stats as "k=v k=v"
  # The manual card-escalate command was removed; the automatic scan is the
  # only front door, so tests drive its public function directly.
  FM_HOME="$H" python3 - "$ROOT" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_discord_conversation_console_lib as fmc

env = fmc.fwl.Env(sys.argv[1] + "/bin")
cfg = fmc.ConsoleConfig.load(env, sys.argv[2])
stats = fmc.run_card_escalations(env, cfg, fmc.ConsoleClient(cfg, env))
print(" ".join(f"{key}={value}" for key, value in stats.items()))
PY
}

cat > "$TMP_ROOT/card-hold.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "auto-card-test",
  "body": "Le correctif est pret. On merge ?",
  "fallback_hint": "Ou reponds directement dans la conversation.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "Oui, vas-y."},
    {"label": "Non", "action": "answer", "value": "Non, pas encore."},
    {"label": "En chat", "action": "chat"}
  ]
}
JSON

# --- 1. holding a call publishes its card with no manual step ----------------
out=$(hold hold auto-card-test --title "Auto card test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-hold.json" --card-channel "$CH" 2>&1) \
  || fail "hold with --card-file failed: $out"
assert_contains "$out" "card posted in conversation $CH" "holding the call posts its card automatically"
assert_equals "1" "$(card_count)" "the held call carries exactly one card"
assert_equals "1" "$(posts_in_channel "$CH" 'Le correctif est pret')" "the card message reached the captain's channel"
assert_equals "0" "$(posts_in_channel "$BLOCAGES" 'Le correctif est pret')" "the card first appears only in its originating conversation"
pass "opening a captain call publishes its Discord card with no manual step"

# The same hold replayed cannot deliver a second card.
out=$(hold hold auto-card-test --title "Auto card test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-hold.json" --card-channel "$CH" 2>&1) \
  || fail "replaying the hold failed: $out"
assert_contains "$out" "no second delivery" "an exact hold replay is deduplicated"
assert_equals "1" "$(card_count)" "the replay left exactly one card"
assert_equals "1" "$(posts_in_channel "$CH" 'Le correctif est pret')" "the replay posted no second card message"
pass "one held call carries at most one active card"

# --- 2. an already-recorded answer cannot be replayed ------------------------
printf 'Oui, vas-y.' > "$TMP_ROOT/decision.txt"
out=$(hold answer auto-card-test --decision-file "$TMP_ROOT/decision.txt" 2>&1) \
  || fail "recording the answer failed: $out"
# A press would have settled the card; mirror that settled state before the
# replay attempt, so the hold guard is what fires, not the open-card guard.
python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
path = next(c for c in cards if json.load(open(c)).get("task_id") == "auto-card-test")
record = json.load(open(path))
record["status"] = "answered"
json.dump(record, open(path, "w"))
PY
out=$(FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" card --config "$CFG" --channel "$CH" \
  --card-file "$TMP_ROOT/card-hold.json" --nonce "replay-attempt" 2>&1) \
  && fail "a card was posted for an answered call" || true
assert_contains "$out" "task auto-card-test is not held for the captain" \
  "an answered call refuses a card replay with the hold error"
pass "an answer already recorded can no longer be replayed through a card"

# --- 3. release is a liberation, not an answer that closes the work ----------
REL=$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_discord_conversation_console_lib as fmc

calls = []
fmc.run_captain_hold = lambda env, argv: (calls.append(argv), (0, ""))[1]
class Env:
    pass
env = Env()
fmc.run_card_option(env, "t", {"label": "Go", "action": "release", "value": "vas-y"})
fmc.run_card_option(env, "t", {"label": "Oui", "action": "answer", "value": "oui"})
fmc.run_card_option(env, "t", {"label": "Plus tard", "action": "later", "until": "2026-10-01"})
release_argv = next(a for a in calls if "--release" in a)
answer_argv = next(a for a in calls if a[0] == "answer" and "--release" not in a)
later_argv = next(a for a in calls if a[0] == "hold")
ok = (
    release_argv[0] == "answer" and "--release" in release_argv
    and "--release" not in answer_argv
    and later_argv[0] == "hold" and "--until" in later_argv
)
print("ok" if ok else "bad:" + repr(calls))
PY
)
assert_equals "ok" "$REL" "a release button lifts the hold, an answer button closes, a later button defers"
pass "release semantics are a liberation, distinct from a work-closing answer"

# --- 4. one bounded escalation mirrors the same card into #blocages ----------
cat > "$TMP_ROOT/card-esc.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "esc-card-test",
  "body": "Encore sans reponse.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "oui"}
  ]
}
JSON
out=$(hold hold esc-card-test --title "Escalation card test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-esc.json" --card-channel "$CH" 2>&1) \
  || fail "holding the escalation task failed: $out"
assert_equals "0" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "no mirror before the delay scan runs"

out=$(esc "$CFG")
assert_contains "$out" "escalated=1" "the first pass mirrors exactly one card"
assert_equals "1" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "the card reached the #blocages channel"
assert_equals "1" "$(posts_in_channel "$CH" 'Encore sans reponse')" "the originating conversation keeps its card"
ORIGIN_IDS=$(custom_ids_of "$CH" 'Encore sans reponse')
MIRROR_IDS=$(custom_ids_of "$BLOCAGES" 'Encore sans reponse')
assert_equals "$ORIGIN_IDS" "$MIRROR_IDS" "the mirror carries the same durable card identity and buttons"
assert_contains "$(esc_of_task esc-card-test)" "True:$BLOCAGES:" "the card records its delivered mirror"
pass "an unanswered held card is mirrored once into #blocages with the same identity"

out=$(esc "$CFG")
assert_contains "$out" "escalated=0" "the second pass mirrors nothing"
assert_equals "1" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "no escalation loop exists"
pass "a card receives at most one bounded mirror"

# A card younger than the delay is skipped.
out=$(FM_CONSOLE_CARD_ESCALATION_DELAY=999999 esc "$CFG")
assert_contains "$out" "escalated=0" "a card younger than the delay is not escalated"
pass "a card younger than the delay receives no mirror"

# A transient Discord failure is retried on later scans up to the documented
# ceiling; a recovered gateway lands exactly one mirror and no loop.
hold hold retry-esc-test --title "Retry escalation test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-esc.json" --card-channel "$CH" >/dev/null 2>&1 \
  || fail "holding the retry escalation task failed"
python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
path = next(c for c in cards if json.load(open(c)).get("task_id") == "retry-esc-test")
record = json.load(open(path))
record["created_at"] = "2020-01-01T00:00:00Z"
json.dump(record, open(path, "w"))
PY
BEFORE=$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')
out=$(FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:1" esc "$CFG")
assert_contains "$out" "failed=1" "a transient mirror failure is reported"
ATTEMPTS=$(python3 - "$H" <<'PY'
import glob, json, sys
for path in glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json"):
    record = json.load(open(path))
    if record.get("task_id") == "retry-esc-test":
        print((record.get("escalation") or {}).get("attempts"))
        break
PY
)
assert_equals "1" "$ATTEMPTS" "the failed attempt is recorded for a bounded retry"
assert_equals "$BEFORE" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "a failed mirror posts nothing"
out=$(FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:1" esc "$CFG")
assert_contains "$out" "failed=1" "the failed mirror is retried on the next scan"
# The gateway recovers before the ceiling: the retry lands exactly one mirror.
out=$(esc "$CFG")
assert_contains "$out" "escalated=1" "a recovered retry lands the mirror"
assert_equals "$((BEFORE + 1))" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "the retried mirror lands exactly once"
out=$(esc "$CFG")
assert_contains "$out" "escalated=0" "a delivered retry is never mirrored again"
CEILING=$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_discord_conversation_console_lib as fmc
print(fmc.CARD_ESCALATION_MAX_ATTEMPTS)
PY
)
assert_equals "3" "$CEILING" "the retry ceiling is documented and bounded"
pass "a failed mirror retries a bounded number of times and then stops"

# An answered call's card is never mirrored: strip its recorded escalation,
# backdate it, and confirm the scan skips it because the call is no longer held.
hold hold answered-esc-test --title "Answered escalation test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-esc.json" --card-channel "$CH" >/dev/null 2>&1 \
  || fail "holding the answered-escalation task failed"
hold answer answered-esc-test --decision-file "$TMP_ROOT/decision.txt" >/dev/null 2>&1 \
  || fail "answering the answered-escalation task failed"
python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
path = next(c for c in cards if json.load(open(c)).get("task_id") == "answered-esc-test")
record = json.load(open(path))
record["created_at"] = "2020-01-01T00:00:00Z"
record.pop("escalation", None)
json.dump(record, open(path, "w"))
PY
BEFORE=$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')
out=$(esc "$CFG")
assert_contains "$out" "escalated=0" "an answered call's card is not mirrored"
assert_equals "$BEFORE" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "an answered call produced no mirror"
pass "a call whose answer is recorded never receives a mirror"

# A card with no #blocages channel configured consumes the attempt at once and
# records the fallback visibly instead of looping or failing silently.
python3 - "$CFG" "$TMP_ROOT/nochannel.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["cards"]["escalation_channel_id"] = ""
json.dump(data, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
hold hold fallback-esc-test --title "Fallback escalation test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-esc.json" --card-channel "$CH" >/dev/null 2>&1 \
  || fail "holding the fallback escalation task failed"
python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
path = next(c for c in cards if json.load(open(c)).get("task_id") == "fallback-esc-test")
record = json.load(open(path))
record["created_at"] = "2020-01-01T00:00:00Z"
record.pop("escalation", None)
json.dump(record, open(path, "w"))
PY
BEFORE=$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')
out=$(esc "$TMP_ROOT/nochannel.json")
assert_contains "$out" "failed=1" "an undeliverable mirror is reported, not silent"
assert_equals "$BEFORE" "$(posts_in_channel "$BLOCAGES" 'Encore sans reponse')" "an undeliverable mirror posts nothing"
GAPS=$(python3 - "$H" <<'PY'
import glob, json, sys
paths = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/delivery-gaps.json")
gaps = json.load(open(paths[0])).get("gaps", []) if paths else []
print(sum(1 for g in gaps if g.get("kind") == "card-escalation" and "fallback-esc-test" in g.get("detail", "")))
PY
)
assert_equals "1" "$GAPS" "the failed attempt is recorded as a visible delivery gap"
out=$(esc "$CFG")
assert_contains "$out" "failed=0" "a permanent misconfiguration is never retried into a loop"
pass "an undeliverable mirror is recorded honestly and never loops"

# --- 5. a press resolves both surfaces of the one card -----------------------
DUAL=$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_discord_conversation_console_lib as fmc

card = {
    "card_id": "a" * 16,
    "body": "b",
    "options": [{"label": "Oui", "action": "answer", "value": "oui", "style": 1}],
    "guild_id": "G",
    "channel_id": "C1",
    "message_id": "M1",
    "escalation": {"delivered": True, "channel_id": "C2", "message_id": "M2"},
}
class Client:
    def __init__(self):
        self.interaction = 0
        self.edits = []
    def interaction_edit_original(self, token, payload):
        self.interaction += 1
    def edit_message(self, channel_id, message_id, payload):
        self.edits.append((channel_id, message_id, payload.get("components")))
    def redact(self, text):
        return text
client = Client()
fmc.settle_card_surfaces(None, client, card, "tok", "C1", "M1", suffix="R\u00e9pondu", disabled=True)
mirror_press = fmc.card_matches_surface(card, "", "C2", "M2")
origin_press = fmc.card_matches_surface(card, "G", "C1", "M1")
other_press = fmc.card_matches_surface(card, "", "C3", "M3")
mirror_edit = client.edits == [("C2", "M2", client.edits[0][2])] if client.edits else False
ok = (
    origin_press and mirror_press and not other_press
    and client.interaction == 1 and len(client.edits) == 1
    and client.edits[0][0] == "C2" and client.edits[0][1] == "M2"
)
print("ok" if ok else f"bad:{origin_press},{mirror_press},{other_press},{client.interaction},{client.edits}")
PY
)
assert_equals "ok" "$DUAL" "a press on either surface resolves the one card and both surfaces settle"
pass "first-answer-wins resolution is reflected on both card surfaces"

# --- 6. an honest fallback when the card itself cannot be published ----------
cat > "$TMP_ROOT/card-fb.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "fallback-hold-test",
  "body": "Publication impossible.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "oui"}
  ]
}
JSON
out=$(FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:1" hold hold fallback-hold-test --title "Fallback hold test" \
  --reason "Choose the card option" --repo firstmate --card-file "$TMP_ROOT/card-fb.json" --card-channel "$CH" 2>&1)
HOLD_RC=$?
assert_equals "0" "$HOLD_RC" "a failed card publication never fails the hold"
assert_contains "$out" "could not be published" "the publication failure is reported, not swallowed"
HELD=$(FM_HOME="$H" "$ROOT/bin/fm-captain-hold.sh" open fallback-hold-test >/dev/null 2>&1 && echo held || echo unheld)
assert_equals "held" "$HELD" "the call stays held and visible after the fallback"
pass "a failed card publication leaves the call held and reports the fallback"

# --- 7. the explicit trigger mapping owns which shapes produce a card --------
TRIGGER=$(python3 - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_discord_conversation_console_lib as fmc

expected = {
    "decision": "decision",
    "blocker": "blocker",
    "clarification": "clarification",
    "projection": "projection",
    "free_request": "free_request",
}
ok = all(fmc.card_type_for_interaction(k) == v for k, v in expected.items())
ok = ok and fmc.card_type_for_interaction("chat") is None
ok = ok and fmc.card_type_for_interaction("") is None
ok = ok and set(fmc.INTERACTION_CARD_TRIGGERS) == set(fmc.CARD_TYPES)
print("ok" if ok else "bad")
PY
)
assert_equals "ok" "$TRIGGER" "every card-worthy interaction maps to its card and an ordinary answer maps to none"
pass "the trigger mapping is explicit and enumerable"

# --- 8. a reply carries its card automatically, one per interaction ----------
for SHAPE in clarification projection free_request; do
  TASK="reply-$SHAPE-test"
  cat > "$TMP_ROOT/card-$SHAPE.json" <<JSON
{
  "schema": "fm-discord-conversation-console.card.v1",
  "type": "$SHAPE",
  "task_id": "$TASK",
  "body": "Carte $SHAPE",
  "fallback_hint": "Ou reponds directement dans la conversation.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "Oui, $SHAPE."},
    {"label": "En chat", "action": "chat"}
  ]
}
JSON
  printf 'Reponse %s' "$SHAPE" > "$TMP_ROOT/reply-$SHAPE.txt"
  out=$(hold hold "$TASK" --title "Reply $SHAPE test" --reason "Choose the card option" --repo firstmate 2>&1) \
    || fail "holding $TASK failed: $out"
  out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:800000000000000001" --text-file "$TMP_ROOT/reply-$SHAPE.txt" \
    --card-file "$TMP_ROOT/card-$SHAPE.json" 2>&1) \
    || fail "reply with a $SHAPE card failed: $out"
  assert_contains "$out" "replied in conversation $CH" "the $SHAPE reply text still posts"
  assert_contains "$out" "card posted in conversation $CH" "the $SHAPE card accompanies the reply"
  assert_equals "1" "$(posts_in_channel "$CH" "Reponse $SHAPE")" "the $SHAPE reply text posted once and was not replaced"
  assert_equals "1" "$(posts_in_channel "$CH" "Carte $SHAPE")" "the $SHAPE card posted once alongside the reply"
  RECORDED=$(python3 - "$H" "$TASK" <<'PY'
import glob, json, sys
for path in glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json"):
    record = json.load(open(path))
    if record.get("task_id") == sys.argv[2]:
        print(record.get("type") or "")
        break
PY
)
  assert_equals "$SHAPE" "$RECORDED" "the $SHAPE card records its interaction shape"
done
pass "a clarification, a projection choice, and a free request each carry their card"

# A replayed reply mints no second reply and no second card.
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:800000000000000001" --text-file "$TMP_ROOT/reply-projection.txt" \
  --card-file "$TMP_ROOT/card-projection.json" 2>&1) \
  || fail "the replayed reply failed: $out"
assert_contains "$out" "receipt exists for nonce" "a replayed reply posts no second text"
assert_contains "$out" "card exists for nonce" "a replayed reply mints no second card"
assert_equals "1" "$(posts_in_channel "$CH" "Carte projection")" "the replay posted no second card message"
pass "one reply carries at most one card, replay-safe"

# An interaction shape outside the trigger mapping is refused before any post.
cat > "$TMP_ROOT/card-unknown.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "type": "nonsense",
  "task_id": "reply-clarification-test",
  "body": "Carte inconnue",
  "options": [{"label": "Oui", "action": "answer", "value": "oui"}]
}
JSON
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:801000000000000001" --text-file "$TMP_ROOT/reply-clarification.txt" \
  --card-file "$TMP_ROOT/card-unknown.json" 2>&1) \
  && fail "an unknown interaction shape was accepted" || true
assert_contains "$out" "card.type must be one of" "an interaction shape outside the mapping is refused"
assert_equals "0" "$(posts_in_channel "$CH" "Carte inconnue")" "the refused card posted nothing"
pass "an interaction shape outside the trigger mapping produces no card"

# --- 9. the card is mandatory for every captain decision reply --------------
# An ordinary reply that asks nothing is never refused, so the guard cannot
# turn every answer into a card demand.
printf 'Le correctif est pret.\n- PR: https://example.com/pr/1' > "$TMP_ROOT/plain-reply.txt"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:802000000000000001" --text-file "$TMP_ROOT/plain-reply.txt" 2>&1) \
  || fail "an ordinary cardless reply was refused: $out"
assert_contains "$out" "replied in conversation $CH" "an ordinary cardless reply still posts"
pass "an ordinary cardless reply that is not a decision is never refused"

# A reply that poses a decision question must carry its card.
printf 'Faut-il merger maintenant ?' > "$TMP_ROOT/decision-reply.txt"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:802000000000000002" --text-file "$TMP_ROOT/decision-reply.txt" 2>&1) \
  && fail "a cardless decision reply was posted" || true
assert_contains "$out" "poses a captain decision but carries no card" "a cardless decision reply is refused"
assert_equals "0" "$(posts_in_channel "$CH" 'Faut-il merger maintenant')" "the refused decision reply posted nothing"
pass "a decision-shaped reply without a card is refused, not posted silently"

# A quoted question is not the captain's own decision and is never refused.
printf '> Pourquoi ?\nLe correctif est pret.' > "$TMP_ROOT/quoted-reply.txt"
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:802000000000000003" --text-file "$TMP_ROOT/quoted-reply.txt" 2>&1) \
  || fail "a reply quoting a question was refused: $out"
assert_contains "$out" "replied in conversation $CH" "a quoted question is not a decision"
pass "a reply that quotes a question is never refused"

# With its card, the decision reply posts both the text and the card.
DEC_TASK=reply-decision-test
hold hold "$DEC_TASK" --title "Decision reply test" --reason "Choose the card option" --repo firstmate >/dev/null 2>&1 \
  || fail "holding $DEC_TASK failed"
cat > "$TMP_ROOT/card-decision-reply.json" <<JSON
{
  "schema": "fm-discord-conversation-console.card.v1",
  "type": "decision",
  "task_id": "$DEC_TASK",
  "body": "Faut-il merger maintenant ?",
  "options": [{"label": "Oui", "action": "answer", "value": "oui"}]
}
JSON
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:802000000000000004" --text-file "$TMP_ROOT/decision-reply.txt" \
  --card-file "$TMP_ROOT/card-decision-reply.json" 2>&1) \
  || fail "a decision reply with its card failed: $out"
assert_contains "$out" "replied in conversation $CH" "the decision reply text posts"
assert_contains "$out" "card posted in conversation $CH" "the decision reply carries its card"
pass "a decision reply with its card posts both the text and the card"

# A decision reply whose card names an unheld task is refused before it posts,
# so the text cannot slip out ahead of a card that would have been refused.
FM_HOME="$H" "$ROOT/bin/fm-tasks-axi.sh" add reply-unheld-test "Unheld reply target" --kind ship >/dev/null 2>&1 \
  || fail "creating the unheld reply task failed"
printf 'On repond au capitaine ?' > "$TMP_ROOT/unheld-reply.txt"
cat > "$TMP_ROOT/card-unheld-reply.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "reply-unheld-test",
  "body": "On repond au capitaine ?",
  "options": [{"label": "Oui", "action": "answer", "value": "oui"}]
}
JSON
out=$(dc reply --config "$CFG" --request-id "discord:$GUILD:$CH:802000000000000005" --text-file "$TMP_ROOT/unheld-reply.txt" \
  --card-file "$TMP_ROOT/card-unheld-reply.json" 2>&1) \
  && fail "a decision reply with an unheld card was posted" || true
assert_contains "$out" "not held for the captain" "a decision reply with an unheld card is refused before posting"
assert_equals "0" "$(posts_in_channel "$CH" 'On repond au capitaine')" "the refused reply text posted nothing"
pass "a decision reply validates its card before the text posts"

# --- 10. a "later" choice defers, keeps the call held, and re-surfaces ------
LATER_TASK=later-defers-test
cat > "$TMP_ROOT/card-later2.json" <<JSON
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "$LATER_TASK",
  "body": "On en reparle plus tard ?",
  "options": [
    {"label": "Plus tard", "action": "later", "until": "2026-10-01"},
    {"label": "Oui", "action": "answer", "value": "oui"}
  ]
}
JSON
hold hold "$LATER_TASK" --title "Later defers test" --reason "Pick later" --repo firstmate \
  --card-file "$TMP_ROOT/card-later2.json" --card-channel "$CH" >/dev/null 2>&1 \
  || fail "holding $LATER_TASK failed"
LATER_OK=$(FM_HOME="$H" python3 - "$ROOT" "$H" "$CFG" "$GUILD" "$CH" "$CAPTAIN" <<'PY'
import glob, json, os, subprocess, sys
sys.path.insert(0, sys.argv[1] + "/bin")
import fm_discord_conversation_console_lib as fmc

root, home, cfg_path, guild, channel, captain = sys.argv[1:7]
env = fmc.fwl.Env(root + "/bin")
cfg = fmc.ConsoleConfig.load(env, cfg_path)
card_path = next(
    path
    for path in glob.glob(f"{home}/state/discord-workspace/conversation-console/cards/*.json")
    if json.load(open(path)).get("task_id") == "later-defers-test"
)
card = json.load(open(card_path))

class Client:
    def __init__(self):
        self.edits = []
    def interaction_ack(self, interaction_id, token):
        pass
    def interaction_followup(self, token, payload):
        pass
    def interaction_edit_original(self, token, payload):
        pass
    def post_message(self, channel_id, text, components=None):
        self.posts = getattr(self, "posts", 0) + 1
        return "999000000000000099"
    def edit_message(self, channel_id, message_id, payload):
        self.edits.append((channel_id, message_id, payload.get("components")))
    def redact(self, text):
        return text

client = Client()
fmc.handle_card_interaction(
    env, cfg, client, "999000000000000020", "tok", captain,
    fmc.card_custom_id(card["card_id"], 0), guild, channel, card["message_id"],
)
after = json.load(open(card_path))
assert after.get("status") == fmc.CARD_STATUS_DEFERRED, after.get("status")
assert after.get("deferred_until") == "2026-10-01", after
assert (after.get("answer") or {}).get("action") == "later", after.get("answer")
held = subprocess.run(
    [root + "/bin/fm-captain-hold.sh", "open", "later-defers-test"],
    env={**os.environ, "FM_HOME": home}, capture_output=True, text=True,
)
assert held.returncode == 0, held.stdout + held.stderr
# Backdate the deferral and run the bounded scan: the same card re-surfaces.
after["deferred_until"] = "2020-01-01"
json.dump(after, open(card_path, "w"))
stats = fmc.run_card_escalations(env, cfg, client)
assert stats.get("resurfaced") == 1, stats
resurfaced = json.load(open(card_path))
assert not resurfaced.get("deferred_until"), resurfaced
assert resurfaced.get("resurfaced_at"), resurfaced
assert client.edits, "the re-surface did not edit the card message"
print("ok")
PY
)
assert_equals "ok" "$LATER_OK" "a later press defers the card, keeps the call held, and re-surfaces it on its date"
assert_grep "hold-until: 2026-10-01" "$H/data/backlog.md" "the later press records the dated deferral"
pass "a later choice defers, keeps the call held, and re-surfaces the same card"

# --- 11. a card requires its exact durable identity --------------------------
# No nonce: refused before any post.
cat > "$TMP_ROOT/card-nonce-less.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "nonce-less-test",
  "body": "Sans identite.",
  "options": [{"label": "Oui", "action": "answer", "value": "oui"}]
}
JSON
out=$(dc card --config "$CFG" --channel "$CH" --card-file "$TMP_ROOT/card-nonce-less.json" 2>&1) \
  && fail "a card without an explicit nonce was accepted" || true
assert_contains "$out" "--nonce is required" "a card without its durable identity is refused"
pass "a card requires its exact durable identity"

# The same identity with a different card is refused rather than silently reused.
hold hold identity-a-test --title "Identity A" --reason "Choose" --repo firstmate >/dev/null 2>&1 \
  || fail "holding identity-a-test failed"
hold hold identity-b-test --title "Identity B" --reason "Choose" --repo firstmate >/dev/null 2>&1 \
  || fail "holding identity-b-test failed"
cat > "$TMP_ROOT/card-identity-a.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "identity-a-test",
  "body": "Premiere carte.",
  "options": [{"label": "Oui", "action": "answer", "value": "oui"}]
}
JSON
cat > "$TMP_ROOT/card-identity-b.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "identity-b-test",
  "body": "Deuxieme carte.",
  "options": [{"label": "Oui", "action": "answer", "value": "oui"}]
}
JSON
out=$(dc card --config "$CFG" --channel "$CH" --card-file "$TMP_ROOT/card-identity-a.json" --nonce shared-identity 2>&1) \
  || fail "the first identity card failed: $out"
out=$(dc card --config "$CFG" --channel "$CH" --card-file "$TMP_ROOT/card-identity-b.json" --nonce shared-identity 2>&1) \
  && fail "a reused card identity was accepted" || true
assert_contains "$out" "already used by another card" "a reused identity is refused"
assert_equals "0" "$(posts_in_channel "$CH" 'Deuxieme carte')" "the colliding card posted nothing"
pass "a card identity is never reused across calls"

# --- 12. the manual escalation path is gone ---------------------------------
out=$(dc card-escalate --config "$CFG" 2>&1) && fail "the manual card-escalate command still exists" || true
assert_contains "$out" "invalid choice" "the manual escalation command is removed"
pass "the automatic scan is the only escalation front door"

echo "all fm-discord-card-auto-surface tests passed"
