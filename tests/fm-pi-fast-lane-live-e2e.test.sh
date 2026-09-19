#!/usr/bin/env bash
# Opt-in live guard for the captain-message fast lane on the REAL installed Pi.
#
# The captain's Discord message becomes a captain-inbox note wake. This guard
# answers the one question only a real Pi can: when main is mid-turn on a fleet
# task, how long does that wake take to reach the running run? It boots the real
# `pi` in print mode against a local, never-contacted fake provider whose
# completion asks for a short `bash` tool call each round. The real watcher
# extension is loaded, the arm child raises a wake once the run is under way,
# and the fake provider records when the wake text appears in the model context.
#
# Two arms, same busy turn:
#   steer     - a `check: captain inbox note` wake, which the fast lane delivers
#               as steering input at the next tool boundary.
#   follow-up - any other main wake, which still waits for the whole run to end.
# The follow-up arm is the before behavior for a captain note: before the fast
# lane, every wake was a follow-up, so it paid the full turn.
#
# No provider call leaves the machine: the endpoint is 127.0.0.1, the provider
# key is a placeholder, and the only tool the fake completion asks for is a
# short local `sleep`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_FAST_LANE_LIVE_E2E pi node

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
TMP_ROOT=$(fm_test_tmproot fm-pi-fast-lane-live)
project="$TMP_ROOT/project"
home="$TMP_ROOT/home"
agentdir="$TMP_ROOT/agent"

mkdir -p "$project/bin" "$project/.pi/extensions/lib" "$home/state" "$home/config" "$agentdir"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$project/.pi/extensions/fm-primary-pi-watch.ts"
for lib in fm-branch-dispatch fm-native-contract fm-async-exec fm-calm-visibility fm-operational-input; do
  cp "$ROOT/.pi/extensions/lib/$lib.ts" "$project/.pi/extensions/lib/$lib.ts"
done
cp "$ROOT/bin/fm-operational-input.sh" "$project/bin/fm-operational-input.sh"
chmod +x "$project/bin/fm-operational-input.sh"

# The arm child stands in for the real watcher loop: it reports one wake once
# the fake provider has the run under way, then a successor blocks so no second
# wake is raised. The `--handling-delivered` confirmation is a clean exit.
cat > "$project/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
if [ -e "$FM_FASTLANE_ARMDONE" ]; then
  trap 'exit 0' TERM INT
  while :; do sleep 0.1; done
fi
i=0
while [ ! -e "$FM_FASTLANE_TRIGGER" ] && [ "$i" -lt 3000 ]; do sleep 0.01; i=$((i+1)); done
printf '%s\n' "$FM_FASTLANE_REASON"
: > "$FM_FASTLANE_ARMDONE"
exit 0
SH
chmod +x "$project/bin/fm-watch-arm.sh"

# The launch wrapper writes the session lock as its own pid and then execs pi,
# so the extension sees the lock owned by the pi process it is loaded into.
cat > "$TMP_ROOT/launch.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/.lock"
cd "$FM_PROJECT" || exit 1
exec "$@"
SH
chmod +x "$TMP_ROOT/launch.sh"

# The fake provider: the first request writes the trigger file so the arm raises
# the wake while the run is busy; each request that has not yet seen the wake
# asks for one short `bash` tool call, and the run ends once the wake is in
# context or after MAX_ROUNDS rounds. It listens on an ephemeral port and logs
# the trigger and wake-seen timestamps the guard measures.
cat > "$TMP_ROOT/server.mjs" <<'JS'
import http from "node:http";
import { writeFileSync, appendFileSync } from "node:fs";
const trigger = process.env.TRIGGER;
const logPath = process.env.LOGPATH;
const wake = process.env.WAKE_TEXT;
const maxRounds = Number(process.env.MAX_ROUNDS || "8");
let rounds = 0;
let triggered = false;
const log = (obj) => appendFileSync(logPath, JSON.stringify({ ...obj, t: Date.now() }) + "\n");
http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    let payload = {};
    try { payload = JSON.parse(body); } catch {}
    const all = (payload.messages || [])
      .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content ?? "")))
      .join("\n");
    const seen = all.includes(wake);
    if (!triggered) { triggered = true; writeFileSync(trigger, "go\n"); log({ event: "trigger", rounds }); }
    if (seen) log({ event: "wake_seen", rounds });
    res.writeHead(200, { "content-type": "text/event-stream" });
    const chunk = (d, f) => `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 1, model: "det", choices: [{ index: 0, delta: d, finish_reason: f }] })}\n\n`;
    if (seen || rounds >= maxRounds) {
      res.write(chunk({ role: "assistant", content: "done" }));
      res.write(chunk({}, "stop"));
      res.write("data: [DONE]\n\n");
      res.end();
      return;
    }
    rounds += 1;
    res.write(chunk({ role: "assistant" }));
    res.write(chunk({ tool_calls: [{ index: 0, id: `c${rounds}`, type: "function", function: { name: "bash", arguments: JSON.stringify({ command: "sleep 0.15" }) } }] }));
    res.write(chunk({}, "tool_calls"));
    res.write("data: [DONE]\n\n");
    res.end();
  });
}).listen(0, function () { log({ event: "listening", port: this.address().port }); });
JS

# Run one arm and print the wake delivery latency in milliseconds.
run_arm() {  # <label> <wake-text> <reason>
  local label=$1 wake_text=$2 reason=$3
  local arm="$TMP_ROOT/$label"
  local trigger="$arm.trigger" armdone="$arm.armdone" log="$arm.jsonl"
  mkdir -p "$arm"
  rm -f "$trigger" "$armdone" "$log"
  WAKE_TEXT="$wake_text" TRIGGER="$trigger" LOGPATH="$log" MAX_ROUNDS=8 node "$TMP_ROOT/server.mjs" > "$arm.server.out" 2>&1 &
  local server_pid=$!
  local i port=""
  for ((i = 0; i < 200; i += 1)); do
    port=$(printf '%s' "$(grep -o '"port":[0-9]*' "$log" 2>/dev/null | head -1 | cut -d: -f2)" )
    [ -n "$port" ] && break
    sleep 0.05
  done
  [ -n "$port" ] || { kill "$server_pid" 2>/dev/null; fail "the fake provider never bound a port for the $label arm: $(cat "$arm.server.out")"; }
  cat > "$agentdir/models.json" <<JSON
{ "providers": { "fm-fastlane": { "baseUrl": "http://127.0.0.1:$port/v1", "api": "openai-completions", "apiKey": "placeholder", "models": [ { "id": "det", "name": "det", "contextWindow": 8192, "maxTokens": 256 } ] } } }
JSON
  rm -f "$home/state/.lock" "$home/state/.pi-watch-extension-loaded"
  timeout 90 env \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_PROJECT="$project" \
    PI_CODING_AGENT_DIR="$agentdir" PI_OFFLINE=1 \
    FM_FASTLANE_TRIGGER="$trigger" FM_FASTLANE_ARMDONE="$armdone" FM_FASTLANE_REASON="$reason" \
    "$TMP_ROOT/launch.sh" pi --approve --no-extensions \
      -e "$project/.pi/extensions/fm-primary-pi-watch.ts" \
      --no-context-files --no-skills --no-prompt-templates \
      --print --model fm-fastlane/det "start the task" > "$arm.pi.out" 2>&1
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  WAKE_TEXT="$wake_text" LOGPATH="$log" node --input-type=module > "$arm.measure" 2>&1 <<'JS' || { cat "$arm.measure" >&2; fail "the $label arm could not be measured"; }
import { readFileSync } from "node:fs";
const rows = readFileSync(process.env.LOGPATH, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
const trigger = rows.find((row) => row.event === "trigger");
const seen = rows.find((row) => row.event === "wake_seen");
if (!trigger || !seen) throw new Error(`missing trigger or wake_seen in ${process.env.LOGPATH}`);
if (!rows.some((row) => row.event === "listening")) throw new Error("the fake provider never listened");
process.stdout.write(`${seen.t - trigger.t}`);
JS
  local measured
  measured=$(cat "$arm.measure")
  case "$measured" in ''|*[!0-9]*) fail "the $label arm produced no measured milliseconds: $(cat "$arm.measure")";; esac
  printf '%s\n' "$measured"
}

steer_ms=$(run_arm steer 'captain inbox note' 'check: captain inbox note 1700000000-loop - is the acknowledgement gone?') \
  || fail "the captain-note steering arm failed to run"
followup_ms=$(run_arm followup 'gh auth check failed' 'check: gh auth check failed; re-authenticate before dispatch') \
  || fail "the follow-up control arm failed to run"

printf 'info - captain-note steering delivery: %s ms; non-captain follow-up control: %s ms (pi %s)\n' "$steer_ms" "$followup_ms" "$PI_VERSION"

[ "$steer_ms" -lt 1000 ] || fail "a captain note took ${steer_ms} ms to reach a busy run, past the 1s bound"
[ "$followup_ms" -gt "$steer_ms" ] || fail "the steering arm (${steer_ms} ms) did not beat the follow-up control (${followup_ms} ms), so the fast lane is not proven"
pass "a captain inbox note reaches a busy real Pi run at the next tool boundary, well before the follow-up control"
