#!/usr/bin/env bash
# Portable native-inbox authority regression: real Node actors in real tmux panes,
# no model credentials. The companion live guard owns vendor API behavior.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
command -v tmux >/dev/null || { echo 'skip: tmux absent'; exit 0; }
command -v node >/dev/null || { echo 'skip: node absent'; exit 0; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-native-inbox.XXXXXX")
REAL_TMUX=$(command -v tmux)
SOCKET="fm-native-inbox-$$"
cleanup() {
  for h in pi opencode codex idle; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "native:$h" C-c 2>/dev/null || true
  done
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/shim" "$LAB/state"
cat > "$LAB/shim/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
MODULE="$ROOT/bin/fm-native-inbox.mjs"
# An actual native actor process, whose session identity can change independently
# of its endpoint. A dispatch into the wrong session creates the wrong receipt.
cat > "$LAB/actor.mjs" <<'JS'
import {readFileSync, writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const {startNativeInbox}=await import(pathToFileURL(process.argv[2]));
const config=process.argv[3];
const sessionFile=process.argv[4];
const actor=await startNativeInbox({config, session:()=>readFileSync(sessionFile,'utf8'), deliver:()=>writeFileSync(process.argv[5], 'executed')});
if(!actor) process.exit(2);
setInterval(()=>{},1000);
JS
"$REAL_TMUX" -L "$SOCKET" new-session -d -s native -n idle -c "$LAB" -- sleep 3600
for h in pi opencode; do
  printf 'backend=tmux\nwindow=native:%s\nharness=%s\n' "$h" "$h" > "$LAB/state/$h.meta"
  mkdir -p "$LAB/state/$h.inbox/handled"
  printf 'instruction\n' > "$LAB/state/$h.inbox/001.msg"
  printf '%s-session' "$h" > "$LAB/$h.session"
  node "$MODULE" arm "$LAB/state" "$h" "$h" "$LAB"
  if node "$MODULE" request tmux "native:$h" "$LAB/state/$h.inbox/001.msg" doorbell; then
    echo "not ok - $h unbound endpoint accepted native delivery"; exit 1
  fi
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t native: -n "$h" -c "$LAB" -- node "$LAB/actor.mjs" "$MODULE" "$LAB/state/$h.native-inbox.config.json" "$LAB/$h.session" "$LAB/$h.acted"
  i=0
  while [ ! -e "$LAB/state/$h.native-inbox.binding.json" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  test -e "$LAB/state/$h.native-inbox.binding.json"
  # Same task and live process, wrong requested endpoint: must not dispatch.
  if node "$MODULE" request tmux native:idle "$LAB/state/$h.inbox/001.msg" doorbell; then
    echo "not ok - $h cross-pane delivery accepted"; exit 1
  fi
  test ! -e "$LAB/$h.acted"
  node "$MODULE" request tmux "native:$h" "$LAB/state/$h.inbox/001.msg" doorbell || {
    cat "$LAB/state/$h.native-inbox.config.json" "$LAB/state/$h.native-inbox.binding.json" "$LAB/state/$h.meta"
    tmux display-message -p -t "native:$h" '#{socket_path} #{pane_id} #{pane_pid}'
    exit 1
  }
  test "$(cat "$LAB/$h.acted")" = executed
  rm "$LAB/$h.acted"
  # A replaced native session must not inherit an old session's request.
  printf 'replacement-session' > "$LAB/$h.session"
  if node "$MODULE" request tmux "native:$h" "$LAB/state/$h.inbox/001.msg" doorbell; then
    echo "not ok - $h session replacement accepted stale binding"; exit 1
  fi
  test ! -e "$LAB/$h.acted"
  # A new launch generation retires even an otherwise still-live actor.
  node "$MODULE" arm "$LAB/state" "$h" "$h" "$LAB"
  if node "$MODULE" request tmux "native:$h" "$LAB/state/$h.inbox/001.msg" doorbell; then
    echo "not ok - $h retired actor accepted delivery"; exit 1
  fi
  test ! -e "$LAB/$h.acted"
  echo "ok - $h native delivery requires exact live endpoint, session, and generation"
done
# Codex attribution uses real notification subprocess ancestry and the exact
# launch prompt, not the most recent thread (which can be title generation).
printf 'backend=tmux\nwindow=native:codex\nharness=codex\n' > "$LAB/state/codex.meta"
node "$MODULE" arm "$LAB/state" codex codex "$LAB"
cat > "$LAB/codex-actor.mjs" <<'JS'
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const modulePath=process.argv[2], config=process.argv[3], lab=process.argv[4];
const {prepareCodexLaunch}=await import(pathToFileURL(modulePath));
assert.ok(await prepareCodexLaunch(config,'actual launch prompt',process.execPath));
writeFileSync(`${lab}/codex.ready`,'ready');
while(!existsSync(`${lab}/codex.go`)) await new Promise(resolve=>setTimeout(resolve,50));
const binding=config.replace('config.json','binding.json');
const event={type:'agent-turn-complete',client:'codex-tui',cwd:process.cwd(),'thread-id':'00000000-0000-0000-0000-000000000001','input-messages':['title generation: actual launch prompt']};
const notify=()=>spawnSync(process.execPath,[modulePath,'codex-notify',config,JSON.stringify(event)],{encoding:'utf8'});
assert.notEqual(notify().status,0);
assert.equal(existsSync(binding),false);
event['input-messages']=['actual launch prompt'];
assert.equal(notify().status,0);
assert.equal(JSON.parse(readFileSync(binding,'utf8')).session,event['thread-id']);
// A second possible root session invalidates rather than replaces attribution.
event['thread-id']='00000000-0000-0000-0000-000000000002';
assert.notEqual(notify().status,0);
assert.equal(existsSync(binding),false);
assert.equal(JSON.parse(readFileSync(config.replace('config.json','launch.json'),'utf8')).ambiguous,true);
writeFileSync(`${lab}/codex.acted`,'verified');
JS
"$REAL_TMUX" -L "$SOCKET" new-window -d -t native: -n codex -c "$LAB" -- node "$LAB/codex-actor.mjs" "$MODULE" "$LAB/state/codex.native-inbox.config.json" "$LAB"
i=0
while [ ! -e "$LAB/codex.ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
test -e "$LAB/codex.ready"
# The same correct prompt sent from an unrelated real process has no authority.
node --input-type=module - "$MODULE" "$LAB" <<'JS'
import assert from 'node:assert/strict';
import {existsSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const modulePath=process.argv[2],lab=process.argv[3];
const config=`${lab}/state/codex.native-inbox.config.json`;
const event=JSON.stringify({type:'agent-turn-complete',client:'codex-tui',cwd:lab,'thread-id':'00000000-0000-0000-0000-000000000001','input-messages':['actual launch prompt']});
assert.notEqual(spawnSync(process.execPath,[modulePath,'codex-notify',config,event]).status,0);
assert.equal(existsSync(config.replace('config.json','binding.json')),false);
writeFileSync(`${lab}/codex.go`,'go');
JS
i=0
while [ ! -e "$LAB/codex.acted" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
test "$(cat "$LAB/codex.acted")" = verified
echo 'ok - codex native attribution rejects foreign processes, title threads, and ambiguous root sessions'
