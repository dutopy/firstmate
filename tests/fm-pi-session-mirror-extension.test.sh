#!/usr/bin/env bash
# Behavior tests for the native Pi session mirror
# (.pi/extensions/fm-discord-session-mirror.ts).
#
# The Pi SDK is stubbed with a scriptable in-process event bus; the extension
# under test is the real tracked file, and every delivery runs the REAL
# bin/fm-discord-conversation-console.sh `mirror` subcommand against a fake
# local HTTP Discord server. No real token is read and no network call leaves
# loopback.
#
# Covers: the disabled default is inert, session-start-anchored collection, the
# durable cursor, the replay that posts nothing twice because the receipt owns
# idempotence, whole-turn collection (an empty or errored or tool-only item is
# skipped), operational injections staying unmirrored, the mid-session enable
# that seeds instead of dumping history, a failed delivery that holds the cursor
# and records its reason, and the per-turn item cap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-pi-session-mirror-extension-tests)
EXT="$ROOT/.pi/extensions/fm-discord-session-mirror.ts"
export NODE_NO_WARNINGS=1

GUILD=111111111111111111
BOT=333333333333333333
CAPTAIN=444444444444444444
CH=666000000000000001
FAKE_TOKEN=faketoken-mirror-extension

cleanup_mirror_extension() {
  kill %1 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_mirror_extension EXIT

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

H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/config"
chmod 700 "$H/state"
FM_HOME="$H" "$ROOT/bin/fm-discord-conversation-console.sh" sample-config > "$H/config/discord-conversation-console.json"
python3 - "$H/config/discord-conversation-console.json" <<PY
import json, sys
data = json.load(open(sys.argv[1]))
data["bot"]["user_id"] = "$BOT"
data["captain_user_ids"] = ["$CAPTAIN"]
data["channels"] = [{"label": "Firstmate", "guild_id": "$GUILD", "channel_id": "$CH"}]
data["live"]["polling"] = False
data["live"]["posting"] = True
data["mirror"] = {"enabled": False, "channel_id": "$CH", "max_chars": 1800}
json.dump(data, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
printf 'FIRSTMATE_DISCORD_BOT_TOKEN: %s\n' "$FAKE_TOKEN" > "$H/config/discord-workspace.secrets.sops.yaml"

DRIVER="$TMP_ROOT/driver.mjs"
cat > "$DRIVER" <<'JS'
import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const home = process.env.FM_HOME;
const root = process.env.FM_ROOT_OVERRIDE;
const world = process.env.MIRROR_WORLD;
const channel = process.env.MIRROR_CHANNEL;
const configFile = `${home}/config/discord-conversation-console.json`;
const cursorFile = `${home}/state/discord-workspace/conversation-console/mirror-cursor.json`;
const receiptsDir = `${home}/state/discord-workspace/receipts`;
const sessionFile = `${home}/session-fixture.jsonl`;

let failures = 0;
let checks = 0;
function check(ok, label, detail) {
  checks += 1;
  if (ok) {
    console.log(`ok - ${label}`);
    return;
  }
  failures += 1;
  console.log(`not ok - ${label}${detail === undefined ? "" : ` (${detail})`}`);
}
function eq(expected, actual, label) {
  check(expected === actual, label, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function posts() {
  const data = JSON.parse(readFileSync(world, "utf8"));
  return data.posts?.[channel] ?? [];
}
function bodies() {
  return posts().map((message) => message.content);
}
function readCursor() {
  if (!existsSync(cursorFile)) return null;
  return JSON.parse(readFileSync(cursorFile, "utf8"));
}
function setConfig(update) {
  const data = JSON.parse(readFileSync(configFile, "utf8"));
  Object.assign(data.mirror, update);
  writeFileSync(configFile, JSON.stringify(data, null, 2));
}
function receiptFor(nonce) {
  return `${receiptsDir}/${createHash("sha256").update(nonce).digest("hex")}.json`;
}

const piHandlers = new Map();
const pi = {
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);

const entries = [];
const sessionManager = {
  getSessionFile: () => sessionFile,
  getEntries: () => entries,
};
function message(role, content) {
  return { type: "message", message: { role, content } };
}
async function fire(event) {
  for (const handler of piHandlers.get(event) ?? []) await handler({}, { sessionManager });
}

// --- A. the disabled default is inert ---------------------------------------
setConfig({ enabled: false });
entries.push(message("user", "Captain asked something in the terminal."));
await fire("session_start");
await fire("turn_end");
eq(0, posts().length, "a disabled mirror posts nothing");
check(!existsSync(cursorFile), "a disabled mirror writes no cursor");

// --- B. a session under the mirror's watch mirrors its dialog ---------------
rmSync(cursorFile, { force: true });
entries.length = 0;
setConfig({ enabled: true });
await fire("session_start");
entries.push(message("user", "Captain asked something in the terminal."));
entries.push(message("assistant", "Firstmate answered in the terminal."));
await fire("turn_end");
eq(2, posts().length, "an enabled mirror posts the captain line and the answer");
eq("[captain] Captain asked something in the terminal.", bodies()[0], "the captain line is attributed");
eq("[main] Firstmate answered in the terminal.", bodies()[1], "the answer is attributed");
eq(2, readCursor()?.index, "the cursor advances past the mirrored items");
check(typeof readCursor()?.recorded_at === "string", "the cursor records when it advanced");
eq("", readCursor()?.last_error, "a clean delivery records no error");
const nonce = `mirror:${channel}:${sessionFile.split("/").pop().replace(/\.jsonl$/, "")}:1`;
const receipt = JSON.parse(readFileSync(receiptFor(nonce), "utf8"));
eq(nonce, receipt.nonce, "the receipt is keyed by the session-scoped source position");
eq("mirror", receipt.kind, "the durable receipt names the mirror kind");
eq(channel, receipt.target.channel_id, "the durable receipt names the mirrored channel");

// --- C. a lost cursor replays nothing twice --------------------------------
rmSync(cursorFile, { force: true });
await fire("turn_end");
eq(2, posts().length, "a lost cursor posts nothing twice, because the receipts own idempotence");
eq(2, readCursor()?.index, "the replayed turn restores the cursor");

// --- D. a settled cursor neither replays nor drops -------------------------
await fire("turn_end");
eq(2, posts().length, "a turn with no new dialog posts nothing");
entries.push(message("user", "A later terminal line."));
await fire("turn_end");
eq(3, posts().length, "only the new dialog is mirrored");
eq(3, readCursor()?.index, "the cursor follows the new dialog");

// --- E. whole turns only: empty, tool-only, and errored items ---------------
const before = posts().length;
entries.push(message("assistant", [{ type: "toolCall", name: "read", arguments: {} }]));
entries.push({ type: "message", message: { role: "assistant", content: "A failed turn.", stopReason: "error", errorMessage: "provider exploded" } });
entries.push(message("user", "   "));
await fire("turn_end");
eq(before, posts().length, "an empty, tool-only, or errored item is never posted");
eq(entries.length, readCursor()?.index, "the cursor still advances past unmirrored items");

// --- F. operational injections stay unmirrored ------------------------------
const afterSkip = posts().length;
entries.push(message("user", "\u2063FIRSTMATE_OP: v1 watcher: queued wake"));
await fire("turn_end");
eq(afterSkip, posts().length, "an operational injection is not mirrored");
eq(entries.length, readCursor()?.index, "the cursor advances past the injection");

// --- G. enabling mid-session seeds instead of dumping history ---------------
rmSync(cursorFile, { force: true });
await fire("session_shutdown");
await fire("turn_end");
eq(afterSkip, posts().length, "a mid-session enable dumps no history");
eq(entries.length, readCursor()?.index, "the mid-session enable seeds the cursor at the current position");
entries.push(message("user", "Mirrored only from here on."));
await fire("turn_end");
eq(afterSkip + 1, posts().length, "dialog after the mid-session enable is mirrored");
eq("Mirrored only from here on.", bodies().at(-1).replace("[captain] ", ""), "the new dialog is the mirrored one");

// --- H. a refused delivery holds the cursor and records its reason ----------
const beforeFailure = posts().length;
entries.push(message("user", "This one cannot reach Discord yet."));
setConfig({ channel_id: "999999999999999999" });
await fire("turn_end");
eq(beforeFailure, posts().length, "a refused delivery posts nothing");
eq(entries.length - 1, readCursor()?.index, "a refused delivery holds the cursor before the failed item");
check((readCursor()?.last_error ?? "").length > 0, "a refused delivery records its reason durably", JSON.stringify(readCursor()?.last_error));
setConfig({ channel_id: channel });
await fire("turn_end");
eq(beforeFailure + 1, posts().length, "the held item is delivered on the next turn end");
eq("", readCursor()?.last_error, "a later success clears the recorded reason");

// --- I. the per-turn item cap bounds one turn end --------------------------
const beforeCap = posts().length;
const capStart = entries.length;
for (let index = 0; index < 10; index += 1) entries.push(message("user", `Bounded item ${index}`));
await fire("turn_end");
eq(beforeCap + 8, posts().length, "one turn end delivers at most eight items");
eq(capStart + 8, readCursor()?.index, "the capped batch resumes at the next unmirrored item");
await fire("turn_end");
eq(beforeCap + 10, posts().length, "the remaining items follow at the next turn end");
eq(entries.length, readCursor()?.index, "the cursor catches the end of the entries");

console.log(`SUMMARY checks=${checks} failures=${failures}`);
JS

PLUGIN="$EXT" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" MIRROR_WORLD="$WORLD" MIRROR_CHANNEL="$CH" \
  FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
  FM_DISCORD_LIVE_API_BASE="http://127.0.0.1:$PORT" FM_DISCORD_LIVE_SOPS="$TMP_ROOT/fake-sops" \
  FM_DISCORD_LIVE_RETRY_SLEEP=0 \
  node "$DRIVER" > "$TMP_ROOT/node-output" 2>&1 || true
cat "$TMP_ROOT/node-output"
if grep -q '^not ok' "$TMP_ROOT/node-output"; then
  fail "the native Pi session mirror extension failed its behavior checks"
fi
grep -q '^SUMMARY checks=[0-9][0-9]* failures=0$' "$TMP_ROOT/node-output" \
  || fail "the extension driver did not finish with a clean summary"

pass "native Pi session mirror extension"
