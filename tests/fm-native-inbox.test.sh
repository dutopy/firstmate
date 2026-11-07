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
printf 'backend=tmux\nwindow=native:opencode-race\nharness=opencode\n' > "$LAB/state/race.meta"
mkdir -p "$LAB/state/race.inbox/handled"
printf 'instruction\n' > "$LAB/state/race.inbox/001.msg"
node "$MODULE" arm "$LAB/state" race opencode "$LAB"
cat > "$LAB/opencode-race.mjs" <<'JS'
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, existsSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const {openCodeNativeInbox, request}=await import(pathToFileURL(process.argv[2]));
const lab=process.argv[3], config=`${lab}/state/race.native-inbox.config.json`;
const binding=`${lab}/state/race.native-inbox.binding.json`;
const pending=[];
const delivered=[];
const inbox=openCodeNativeInbox({session:{
  get:({path})=>new Promise(resolve=>pending.push({id:path.id,resolve})),
  promptAsync:async ({path,body})=>{delivered.push([path.id,body.parts[0].text]);},
}},config);
const resolveNext=()=>{
  const lookup=pending.shift();
  lookup.resolve({data:{id:lookup.id,directory:lab}});
};
for (const event of [
  {type:'tui.session.select',properties:{sessionID:'B'}},
  {type:'tui.session.select',properties:{sessionID:'A'}},
  {type:'session.deleted',properties:{info:{id:'A'}}},
  {type:'server.instance.disposed',properties:{}},
]) {
  const lookup=inbox.message({sessionID:'A'});
  inbox.event(event);
  resolveNext();
  await lookup;
  assert.equal(existsSync(binding),false,`${event.type} must invalidate pending attribution`);
}
const older=inbox.message({sessionID:'A'});
const newer=inbox.message({sessionID:'B'});
pending.splice(1,1)[0].resolve({data:{id:'B',directory:lab}});
await newer;
resolveNext();
await older;
assert.equal(JSON.parse(readFileSync(binding,'utf8')).session,'B');
const superseded=inbox.message({sessionID:'A'});
await inbox.message({sessionID:'B'});
resolveNext();
await superseded;
assert.equal(JSON.parse(readFileSync(binding,'utf8')).session,'B');
assert.equal(await request('tmux','native:opencode-race',`${lab}/state/race.inbox/001.msg`,'doorbell'),0);
assert.deepEqual(delivered,[['B','doorbell']]);
inbox.event({type:'session.deleted',properties:{info:{id:'B'}}});
assert.equal(existsSync(binding),false);
assert.equal(await request('tmux','native:opencode-race',`${lab}/state/race.inbox/001.msg`,'stale'),1);
const ordinary=inbox.message({sessionID:'A'});
resolveNext();
await ordinary;
assert.equal(await request('tmux','native:opencode-race',`${lab}/state/race.inbox/001.msg`,'ordinary'),0);
assert.deepEqual(delivered,[['B','doorbell'],['A','ordinary']]);
inbox.event({type:'server.instance.disposed',properties:{}});
assert.equal(existsSync(binding),false);
writeFileSync(`${lab}/race.acted`,'verified');
JS
"$REAL_TMUX" -L "$SOCKET" new-window -d -t native: -n opencode-race -c "$LAB" -- node "$LAB/opencode-race.mjs" "$MODULE" "$LAB"
i=0
while [ ! -e "$LAB/race.acted" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
test "$(cat "$LAB/race.acted")" = verified
echo 'ok - opencode rejects superseded lookups and delivers only to the current binding'
# Codex attribution uses real notification subprocess ancestry and the exact
# launch prompt, not the most recent thread (which can be title generation).
printf 'backend=tmux\nwindow=native:codex\nharness=codex\n' > "$LAB/state/codex.meta"
node "$MODULE" arm "$LAB/state" codex codex "$LAB"
cat > "$LAB/codex-actor.mjs" <<'JS'
#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, existsSync, unlinkSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
const lab=process.env.FM_NATIVE_FIXTURE_LAB;
const config=`${lab}/state/codex.native-inbox.config.json`;
const args=process.argv.slice(2);
const setting=args.find((arg,index)=>index>0&&args[index-1]==='-c'&&arg.startsWith('notify='));
assert.ok(setting,'the actual Codex subprocess must receive its native notify program');
const program=JSON.parse(setting.slice('notify='.length));
writeFileSync(`${lab}/codex.ready`,'ready');
while(!existsSync(`${lab}/codex.go`)) await new Promise(resolve=>setTimeout(resolve,50));
const binding=config.replace('config.json','binding.json');
const turnEnded=`${lab}/state/codex.turn-ended`;
const event={type:'agent-turn-complete',client:'codex-tui',cwd:process.cwd(),'thread-id':'00000000-0000-0000-0000-000000000001','input-messages':['title generation: actual launch prompt']};
const notify=()=>spawnSync(program[0],[...program.slice(1),JSON.stringify(event)],{encoding:'utf8'});
assert.notEqual(notify().status,0);
assert.equal(existsSync(binding),false);
assert.equal(existsSync(turnEnded),false,'title generation must not close the worker turn');
event['input-messages']=['actual launch prompt'];
assert.equal(notify().status,0);
assert.equal(JSON.parse(readFileSync(binding,'utf8')).session,event['thread-id']);
assert.equal(existsSync(turnEnded),true,'an attributed root completion must notify supervision');
unlinkSync(turnEnded);
for (const input of ['steering doorbell', 'ordinary follow-up']) {
  event['input-messages']=[input];
  assert.equal(notify().status,0,'attributed subsequent turns must notify supervision');
  assert.equal(existsSync(turnEnded),true);
  assert.equal(JSON.parse(readFileSync(binding,'utf8')).session,event['thread-id']);
  unlinkSync(turnEnded);
}
event['thread-id']='00000000-0000-0000-0000-000000000003';
assert.notEqual(notify().status,0);
assert.equal(existsSync(turnEnded),false);
assert.equal(JSON.parse(readFileSync(binding,'utf8')).session,'00000000-0000-0000-0000-000000000001');
event['input-messages']=['actual launch prompt'];
// A second possible root session invalidates rather than replaces attribution.
event['thread-id']='00000000-0000-0000-0000-000000000002';
assert.notEqual(notify().status,0);
assert.equal(existsSync(binding),false);
assert.equal(JSON.parse(readFileSync(config.replace('config.json','launch.json'),'utf8')).ambiguous,true);
assert.equal(existsSync(turnEnded),false,'an ambiguous root must not close another turn');
writeFileSync(`${lab}/codex.acted`,'verified');
JS
chmod +x "$LAB/codex-actor.mjs"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t native: -n codex -c "$LAB" -- env FM_NATIVE_FIXTURE_LAB="$LAB" node "$MODULE" codex "$LAB/state/codex.native-inbox.config.json" -- "$LAB/codex-actor.mjs" 'actual launch prompt'
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

# A hung harness API must not wedge the actor: the first delivery times out and is
# refused (2), the next one is served, and no stale request is left behind.
printf 'backend=tmux\nwindow=native:hang\nharness=pi\n' > "$LAB/state/hang.meta"
mkdir -p "$LAB/state/hang.inbox/handled"
printf 'instruction\n' > "$LAB/state/hang.inbox/001.msg"
node "$MODULE" arm "$LAB/state" hang pi "$LAB"
cat > "$LAB/hang-actor.mjs" <<'JS'
import {writeFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
const {startNativeInbox}=await import(pathToFileURL(process.argv[2]));
let calls=0;
const actor=await startNativeInbox({config:process.argv[3], session:()=>'hang-session', deliver:()=>{
  if (calls++===0) return new Promise(()=>{});
  writeFileSync(process.argv[4],'executed');
}});
if(!actor) process.exit(2);
setInterval(()=>{},1000);
JS
"$REAL_TMUX" -L "$SOCKET" new-window -d -t native: -n hang -c "$LAB" -- node "$LAB/hang-actor.mjs" "$MODULE" "$LAB/state/hang.native-inbox.config.json" "$LAB/hang.acted"
i=0
while [ ! -e "$LAB/state/hang.native-inbox.binding.json" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
test -e "$LAB/state/hang.native-inbox.binding.json"
rc=0; node "$MODULE" request tmux native:hang "$LAB/state/hang.inbox/001.msg" doorbell || rc=$?
test "$rc" = 2 || { echo "not ok - hung delivery returned $rc, expected 2"; exit 1; }
test ! -e "$LAB/state/hang.native-inbox.request.json" || { echo "not ok - refused request left behind"; exit 1; }
node "$MODULE" request tmux native:hang "$LAB/state/hang.inbox/001.msg" doorbell || { echo "not ok - actor wedged after a hung delivery"; exit 1; }
test "$(cat "$LAB/hang.acted")" = executed
echo 'ok - a hung native delivery times out, leaves no request, and does not wedge the actor'

# An actor that dies while a request is pending yields a native failure (2), not
# "unbound" (1), and removes its request.
"$REAL_TMUX" -L "$SOCKET" kill-window -t native:hang
rc=0; node "$MODULE" request tmux native:hang "$LAB/state/hang.inbox/001.msg" doorbell || rc=$?
test "$rc" = 1 || { echo "not ok - dead actor returned $rc, expected 1 (unbound before publish)"; exit 1; }
test ! -e "$LAB/state/hang.native-inbox.request.json"
echo 'ok - a dead actor is refused without leaving a request'
