#!/usr/bin/env bash
# Behavior tests for automatic decision-card surfacing.
#
# Covers the hold -> card linkage (one held call, at most one active card, no
# replay after an answer, honest fallback when publication fails), the
# release-versus-answer button semantics, and the bounded single nudge for a
# held card left unanswered. Everything runs against a fake local HTTP Discord
# server, so no real token is read and no real Discord message is sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-discord-card-auto-surface-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# The nudge delay is read at scan time; zero makes every posted card eligible.
export FM_CONSOLE_CARD_NUDGE_DELAY=0

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
CH=666000000000000001
FAKE_TOKEN=faketoken-abc123

dc() { FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" "$@"; }
hold() { FM_HOME="$H" "$ROOT/bin/fm-captain-hold.sh" "$@"; }

cleanup_console() {
  local home
  for home in "${H:-}"; do
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
posts_in_channel() { python3 - "$WORLD" "$CH" "$1" <<'PY'
import json, sys
world = json.load(open(sys.argv[1]))
needle = sys.argv[3]
print(sum(1 for m in world.get("posts", {}).get(sys.argv[2], []) if needle in (m.get("content") or "")))
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
assert_equals "1" "$(posts_in_channel 'Le correctif est pret')" "the card message reached the captain's channel"
pass "opening a captain call publishes its Discord card with no manual step"

# The same hold replayed cannot deliver a second card.
out=$(hold hold auto-card-test --title "Auto card test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-hold.json" --card-channel "$CH" 2>&1) \
  || fail "replaying the hold failed: $out"
assert_contains "$out" "no second delivery" "an exact hold replay is deduplicated"
assert_equals "1" "$(card_count)" "the replay left exactly one card"
assert_equals "1" "$(posts_in_channel 'Le correctif est pret')" "the replay posted no second card message"
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

# --- 4. one bounded nudge for a held card left unanswered --------------------
cat > "$TMP_ROOT/card-nudge.json" <<'JSON'
{
  "schema": "fm-discord-conversation-console.card.v1",
  "task_id": "nudge-card-test",
  "body": "Encore sans reponse.",
  "options": [
    {"label": "Oui", "action": "answer", "value": "oui"}
  ]
}
JSON
out=$(hold hold nudge-card-test --title "Nudge card test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-nudge.json" --card-channel "$CH" 2>&1) \
  || fail "holding the nudge task failed: $out"

out=$(dc card-nudges --config "$CFG" --dry-run 2>&1) || fail "card-nudges dry run failed: $out"
assert_contains "$out" "card nudge plan (no network)" "the dry run makes no network call"
assert_contains "$out" "eligible" "an open unanswered held card is nudge-eligible"

out=$(dc card-nudges --config "$CFG" 2>&1) || fail "card-nudges failed: $out"
assert_contains "$out" "nudged=1" "the first pass sends exactly one nudge"
assert_equals "1" "$(posts_in_channel 'Relance (une seule)')" "one reminder message reached the channel"
NUDGED=$(python3 - "$H" <<'PY'
import glob, json, sys
import glob as g, json as j
paths = g.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
record = next(j.load(open(p)) for p in paths if j.load(open(p)).get("task_id") == "nudge-card-test")
nudge = record.get("nudge") or {}
print(f"{nudge.get('delivered')}:{record.get('status')}")
PY
)
assert_equals "True:open" "$NUDGED" "the single nudge attempt is recorded on the card"

out=$(dc card-nudges --config "$CFG" 2>&1) || fail "the second card-nudges pass failed: $out"
assert_contains "$out" "nudged=0" "the second pass nudges nothing"
assert_equals "1" "$(posts_in_channel 'Relance (une seule)')" "no reminder loop exists"
pass "an unanswered held card receives at most one bounded reminder"

# An answered call's card is never nudged: strip its recorded nudge, backdate
# it, and confirm the scan skips it because the call is no longer held.
hold hold answered-nudge-test --title "Answered nudge test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-nudge.json" --card-channel "$CH" >/dev/null 2>&1 \
  || fail "holding the answered-nudge task failed"
[ -n "$(card_for_task answered-nudge-test)" ] \
  || fail "the command line's task id did not bind the reused card file to the held call"
hold answer answered-nudge-test --decision-file "$TMP_ROOT/decision.txt" >/dev/null 2>&1 \
  || fail "answering the answered-nudge task failed"
python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
path = next(c for c in cards if json.load(open(c)).get("task_id") == "answered-nudge-test")
record = json.load(open(path))
record["created_at"] = "2020-01-01T00:00:00Z"
record.pop("nudge", None)
json.dump(record, open(path, "w"))
PY
BEFORE=$(posts_in_channel 'Relance (une seule)')
out=$(dc card-nudges --config "$CFG" 2>&1) || fail "the post-answer nudge pass failed: $out"
assert_contains "$out" "nudged=0" "an answered call's card receives no nudge"
assert_equals "$BEFORE" "$(posts_in_channel 'Relance (une seule)')" "an answered call produced no reminder post"
pass "a call whose answer is recorded never receives a reminder"

# A deliverable-that-cannot-post consumes the single attempt and records the
# fallback visibly instead of looping or failing silently.
hold hold fallback-card-test --title "Fallback card test" --reason "Choose the card option" --repo firstmate \
  --card-file "$TMP_ROOT/card-nudge.json" --card-channel "$CH" >/dev/null 2>&1 \
  || fail "holding the fallback task failed"
[ -n "$(card_for_task fallback-card-test)" ] \
  || fail "the command line's task id did not bind the reused card file to the fallback call"
python3 - "$H" <<'PY'
import glob, json, sys
cards = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/cards/*.json")
path = next(c for c in cards if json.load(open(c)).get("task_id") == "fallback-card-test")
record = json.load(open(path))
record["created_at"] = "2020-01-01T00:00:00Z"
record["channel_id"] = ""
record.pop("nudge", None)
json.dump(record, open(path, "w"))
PY
BEFORE=$(posts_in_channel 'Relance (une seule)')
out=$(dc card-nudges --config "$CFG" 2>&1) || fail "the fallback nudge pass failed: $out"
assert_contains "$out" "failed=1" "an undeliverable nudge is reported, not silent"
assert_equals "$BEFORE" "$(posts_in_channel 'Relance (une seule)')" "an undeliverable nudge posts nothing"
GAPS=$(python3 - "$H" <<'PY'
import glob, json, sys
paths = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/delivery-gaps.json")
gaps = json.load(open(paths[0])).get("gaps", []) if paths else []
print(sum(1 for g in gaps if g.get("kind") == "card-nudge" and "fallback-card-test" in g.get("detail", "")))
PY
)
assert_equals "1" "$GAPS" "the failed attempt is recorded as a visible delivery gap"
out=$(dc card-nudges --config "$CFG" 2>&1) || fail "the post-failure nudge pass failed: $out"
assert_contains "$out" "failed=0" "a failed attempt is never retried into a loop"
GAPS2=$(python3 - "$H" <<'PY'
import glob, json, sys
paths = glob.glob(f"{sys.argv[1]}/state/discord-workspace/conversation-console/delivery-gaps.json")
gaps = json.load(open(paths[0])).get("gaps", []) if paths else []
print(sum(1 for g in gaps if g.get("kind") == "card-nudge" and "fallback-card-test" in g.get("detail", "")))
PY
)
assert_equals "1" "$GAPS2" "the failed attempt stays recorded exactly once"
pass "an undeliverable reminder is recorded honestly and never loops"

# --- 5. an honest fallback when the card itself cannot be published ----------
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

echo "all fm-discord-card-auto-surface tests passed"
