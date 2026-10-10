#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the task-worker destructive-command guard (docs/worker-guard.md).
#
# bin/fm-worker-guard-policy.mjs owns the decision and
# bin/fm-worker-guard-pretool-check.sh is the public hook transport. Every case
# drives the transport through its public Claude-shaped PreToolUse JSON on stdin
# (or --command), against REAL disposable processes and filesystem sentinels
# owned by this test: a deny must leave the foreign process alive and the
# foreign sentinel intact, an allow must really perform the action. Nothing
# real is ever killed or deleted to prove a denial. Live vendor evidence for
# Claude and omp lives in tests/fm-worker-guard-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-worker-guard)
CHECK="$ROOT/bin/fm-worker-guard-pretool-check.sh"

WT="$TMP_ROOT/copy6"
EVIL="$TMP_ROOT/copy6evil"
FOREIGN="$TMP_ROOT/foreign"
OTHER_WT="$TMP_ROOT/copy7"
mkdir -p "$WT" "$EVIL/keep" "$FOREIGN/keep" "$OTHER_WT/keep"
git init -q -b main "$WT"
# A reviewed helper script that exists in the task base (main), then the
# worker's own branch on top of it.
printf '#!/usr/bin/env bash\necho hello\nrm -rf "$TMPDIR/scratch"\n' >"$WT/ok.sh"
git -C "$WT" add ok.sh
git -C "$WT" commit -q -m init
git -C "$WT" checkout -q -b fm/worker
# The trusted script base is launch state (fm-spawn exports the commit the
# worktree was at), never a ref the worker could move.
FM_WORKER_GUARD_BASE=$(git -C "$WT" rev-parse HEAD)
export FM_WORKER_GUARD_BASE
printf 'precious\n' >"$EVIL/keep/data"
printf 'precious\n' >"$FOREIGN/keep/data"
printf 'precious\n' >"$OTHER_WT/keep/data"
WT=$(cd -P "$WT" && pwd -P)
EVIL=$(cd -P "$EVIL" && pwd -P)
FOREIGN=$(cd -P "$FOREIGN" && pwd -P)
OTHER_WT=$(cd -P "$OTHER_WT" && pwd -P)
ln -s "$EVIL" "$WT/evil-link"
export FM_WORKER_GUARD_ROOT="$WT"
unset FM_WORKER_GUARD_EXTRA_ROOTS

STARTED_PIDS=()
cleanup_pids() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
}
trap 'cleanup_pids; fm_test_cleanup' EXIT

# Real processes are started in the current shell (never a command
# substitution) so STARTED_PIDS keeps every PID for the exit trap.
# start_foreign: cwd outside the worker copy, no relation to the owner.
start_foreign() {
  (cd "$FOREIGN" && exec sleep 600) >/dev/null 2>&1 &
  STARTED_PIDS+=("$!")
  STARTED=$!
}

# start_cwd_owned: cwd is the worker copy (cwd-proved ownership).
start_cwd_owned() {
  (cd "$WT" && exec sleep 601) >/dev/null 2>&1 &
  STARTED_PIDS+=("$!")
  STARTED=$!
}

alive() { kill -0 "$1" 2>/dev/null; }

hook_json() { # <command> [cwd]
  jq -nc --arg c "$1" --arg d "${2:-$WT}" '{session_id:"t",cwd:$d,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'
}

# run_hook <command> [cwd] [extra transport args...]: sets HOOK_CODE, HOOK_OUT, HOOK_ERR.
# Without an explicit --owner-pid the agent identity is "none", so the verdict
# does not depend on the claude/omp session this suite itself runs inside.
run_hook() {
  local cmd=$1 cwd=${2:-$WT}
  local errf="$TMP_ROOT/err.$$"
  if [ "$#" -ge 2 ]; then shift 2; else shift "$#"; fi
  [ "$#" -gt 0 ] || set -- --owner-pid none
  HOOK_OUT=$(hook_json "$cmd" "$cwd" | "$CHECK" --claude "$@" 2>"$errf")
  HOOK_CODE=$?
  HOOK_ERR=$(cat "$errf")
  rm -f "$errf"
}

start_foreign
FOREIGN_PID=$STARTED
start_foreign
OTHER_PID=$STARTED

assert_denied() { # <label> <command> [cwd]
  run_hook "$2" "${3:-$WT}"
  [ "$HOOK_CODE" = 2 ] || fail "$1: expected deny (exit 2), got $HOOK_CODE for: $2"
  [ -z "$HOOK_OUT" ] || fail "$1: Claude requires empty stdout on deny"
  assert_contains "$HOOK_ERR" "worker-guard" "$1: deny reason names the guard"
  assert_contains "$HOOK_ERR" "blocked:" "$1: deny reason names the allowed escalation path"
}

assert_allowed() { # <label> <command> [cwd]
  run_hook "$2" "${3:-$WT}"
  [ "$HOOK_CODE" = 0 ] || fail "$1: expected allow, got $HOOK_CODE ($HOOK_ERR) for: $2"
  [ -z "$HOOK_ERR" ] && [ -z "$HOOK_OUT" ] || fail "$1: allow must be silent"
}

assert_nothing_destroyed() {
  alive "$FOREIGN_PID" || fail "$1: foreign process was killed"
  alive "$OTHER_PID" || fail "$1: second foreign process was killed"
  [ -f "$EVIL/keep/data" ] || fail "$1: copy6evil sentinel was deleted"
  [ -f "$FOREIGN/keep/data" ] || fail "$1: foreign sentinel was deleted"
  [ -f "$OTHER_WT/keep/data" ] || fail "$1: other worker copy sentinel was deleted"
}

# --- named incident: pkill/killall and their indirect spellings -------------

test_broad_kill_denied() {
  local i=0 cmd
  local cmds=(
    "pkill -f sleep"
    "pkill -f chrome-headless-shell"
    "pkill -9 -f daemon.py"
    "killall sleep"
    "/usr/bin/pkill -f sleep"
    "command pkill -f sleep"
    "env pkill -f sleep"
    "sudo killall sleep"
    "nohup pkill -f sleep"
    "timeout 5 pkill -f sleep"
    "pgrep -f 'sleep 600' | xargs kill"
    "pgrep -f 'sleep 600' | xargs -n1 kill -9"
    "ps aux | grep sleep | awk '{print \$2}' | xargs kill -9"
    'kill $(pgrep -f "sleep 600")'
    'kill -9 `pgrep -f sleep`'
    "lsof -t -i :8000 | xargs kill"
    "fuser -k 8000/tcp"
    "tmux kill-server"
    "launchctl kill 9 system/foo"
    "echo go && pkill -f sleep"
    "ls; pkill -f sleep"
    "(pkill -f sleep)"
    "{ pkill -f sleep; }"
    "if pkill -f sleep; then echo x; fi"
    "for i in 1 2; do pkill -f sleep; done"
    "f() { pkill -f sleep; }; f"
  )
  for cmd in "${cmds[@]}"; do
    i=$((i + 1))
    assert_denied "broad-kill-$i" "$cmd"
  done
  assert_nothing_destroyed "broad kill denials"
  pass "pkill/killall/xargs kill/kill \$(pgrep) denied, nothing killed"
}

test_script_bypass_denied() {
  local i=0 cmd
  local cmds=(
    "bash -c 'pkill -f sleep'"
    "sh -c \"pkill -f sleep\""
    "zsh -c 'killall sleep'"
    "bash -c \"kill $FOREIGN_PID\""
    "eval 'pkill -f sleep'"
    "echo 'pkill -f sleep' | sh"
    "echo 'pkill -f sleep' | bash"
    "printf 'killall sleep' | zsh"
    "bash <<EOF
pkill -f sleep
EOF"
    "bash <<< 'pkill -f sleep'"
    "cat > /tmp/fm-wg-x.sh <<EOF
pkill -f sleep
EOF
bash /tmp/fm-wg-x.sh"
    "cat > run.sh <<EOF
kill $FOREIGN_PID
EOF
chmod +x run.sh && ./run.sh"
    "cat > run.sh <<EOF
kill $FOREIGN_PID
EOF
source run.sh"
    "python3 -c 'import os; os.kill($FOREIGN_PID, 9)'"
    "python3 -c 'import os; os.killpg($FOREIGN_PID, 9)'"
    "python3 -c 'import os,signal; os.kill(-1, signal.SIGKILL)'"
    "python3 -c 'import subprocess; subprocess.run([\"pkill\", \"-f\", \"sleep\"])'"
    "python3 -c 'import os; os.system(\"pkill -f sleep\")'"
    "python3 -c 'import subprocess; subprocess.run(\"kill $FOREIGN_PID\", shell=True)'"
    "python3 -c 'import subprocess; subprocess.Popen([\"rm\", \"-rf\", \"$EVIL/keep\"])'"
    "python3 - <<EOF
import psutil
for p in psutil.process_iter():
    if 'sleep' in p.name():
        p.kill()
EOF"
    "python3 - <<EOF
import os, subprocess
out = subprocess.check_output(['pgrep', '-f', 'sleep']).split()
for pid in out:
    os.kill(int(pid), 9)
EOF"
    "python3 -c 'import shutil; shutil.rmtree(\"$EVIL/keep\")'"
    "python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' $EVIL/keep"
    "python3 -c 'import os; exec(\"os.kill(%d, 9)\" % $FOREIGN_PID)'"
    "python3 -c 'import os; getattr(os, \"ki\" + \"ll\")($FOREIGN_PID, 9)'"
    "python3 -c 'import base64,os; exec(base64.b64decode(\"cGFzcw==\"))'"
    "node -e 'process.kill($FOREIGN_PID)'"
    "node -e 'require(\"child_process\").execSync(\"pkill -f sleep\")'"
    "node -e 'require(\"fs\").rmSync(\"$EVIL/keep\", {recursive:true})'"
    "ruby -e 'Process.kill(\"KILL\", $FOREIGN_PID)'"
    "perl -e 'kill 9, $FOREIGN_PID'"
    "perl -e 'system(\"pkill\", \"-f\", \"sleep\")'"
    "python3 -c 'print(1)' | python3 -"
  )
  for cmd in "${cmds[@]}"; do
    i=$((i + 1))
    assert_denied "script-bypass-$i" "$cmd"
  done
  assert_nothing_destroyed "script bypass denials"
  pass "bash -c / eval / pipes / heredocs / python / node / ruby bypasses denied, nothing destroyed"
}

test_script_files_in_tree() {
  printf '#!/usr/bin/env bash\npkill -f sleep\n' >"$WT/new-bypass.sh"
  chmod +x "$WT/new-bypass.sh"
  assert_denied "untracked shell script with pkill" "bash new-bypass.sh"
  assert_denied "untracked shell script run by path" "./new-bypass.sh"
  printf 'import os\nos.kill(%s, 9)\n' "$FOREIGN_PID" >"$WT/new-bypass.py"
  assert_denied "untracked python script killing a foreign pid" "python3 new-bypass.py"
  printf 'import psutil\nfor p in psutil.process_iter():\n    p.kill()\n' >"$WT/sweep.py"
  assert_denied "untracked python sweep" "python3 sweep.py"
  printf '#!/usr/bin/env bash\nrm -rf "$1"\n' >"$WT/del.sh"
  assert_denied "untracked script deleting an unprovable argument" "bash del.sh $EVIL/keep"
  # A helper script that exists unchanged in the task base is reviewed code.
  assert_allowed "base script is not strictly scanned" "bash ok.sh"
  # The worker's own commit never launders a script: it is not in the base.
  printf '#!/usr/bin/env bash\nrm -rf "$1"\n' >"$WT/del-committed.sh"
  git -C "$WT" add del-committed.sh && git -C "$WT" commit -q -m "worker adds a deleting script"
  assert_denied "a script the worker committed itself" "bash del-committed.sh $EVIL/keep"
  printf '#!/usr/bin/env bash\npkill -f x\n' >"$WT/ok.sh"
  assert_denied "a base script modified to call pkill" "bash ok.sh"
  git -C "$WT" commit -q -am "worker commits pkill into a base script"
  assert_denied "a base script whose pkill edit was committed by the worker" "bash ok.sh"
  assert_nothing_destroyed "in-tree script denials"
  pass "in-tree scripts are read, never run: only base-identical scripts escape the strict scan"
}

# --- rm -r outside the isolated copy ---------------------------------------

test_rm_outside_denied() {
  local i=0 cmd
  local cmds=(
    "rm -rf $EVIL/keep"
    "rm -rf $EVIL"
    "rm -rf $FOREIGN"
    "rm -r $OTHER_WT/keep"
    "rm -Rf $EVIL/keep"
    "rm --recursive --force $EVIL/keep"
    "rm -rf ../copy6evil/keep"
    "rm -rf ../copy6evil"
    "rm -rf $WT/../copy6evil/keep"
    "rm -rf $WT"
    "rm -rf $WT/"
    "rm -rf ."
    "rm -rf ./"
    "rm -rf .."
    "rm -rf .*"
    "rm -rf evil-link/"
    "rm -rf evil-link/*"
    "rm -rf evil-link/keep"
    "rm -rf \$UNSET/keep"
    "rm -rf \"\$(echo $EVIL)/keep\""
    "rm -rf \`echo $EVIL\`/keep"
    "rm -rf ~/definitely-not-there"
    "rm -rf /"
    "cd $EVIL && rm -rf keep"
    "cd .. && rm -rf copy6evil"
    "(cd $EVIL && rm -rf keep)"
    "cd $FOREIGN; rm -rf *"
    "X=$EVIL; rm -rf \$X/keep"
    "bash -c 'rm -rf $EVIL/keep'"
    "bash -c \"rm -rf \$TARGET\""
    "sh -c 'cd $EVIL && rm -rf keep'"
    "echo $EVIL/keep | xargs rm -rf"
    "find $EVIL -delete"
    "find $FOREIGN -name '*' -delete"
    "find $EVIL -type f -exec rm -rf {} +"
    "find .. -name keep -delete"
    "find / -name data -delete"
    "alias gone='rm -rf'; gone $EVIL/keep"
    "R=rm; \$R -rf $EVIL/keep"
    "cat > nuke.sh <<EOF
rm -rf $EVIL/keep
EOF
sh nuke.sh"
  )
  for cmd in "${cmds[@]}"; do
    i=$((i + 1))
    assert_denied "rm-outside-$i" "$cmd"
  done
  assert_nothing_destroyed "rm denials"
  [ -d "$WT" ] || fail "the worker copy itself must survive"
  pass "rm -r outside the copy, on the copy root, via symlink, expansion, cd, or script denied; sentinels intact"
}

test_copy_prefix_is_not_ownership() {
  assert_denied "copy6evil is not copy6" "rm -rf $EVIL/keep"
  local pid
  (cd "$EVIL" && exec sleep 602) >/dev/null 2>&1 &
  pid=$!
  STARTED_PIDS+=("$pid")
  assert_denied "a process whose cwd is copy6evil is not owned" "kill $pid"
  alive "$pid" || fail "copy6evil process must survive"
  pass "copy6evil never counts as copy6 (path and process cwd)"
}

# --- kill: owned allow, foreign / unknown deny ------------------------------

test_foreign_pid_denied() {
  local fake_group
  assert_denied "foreign literal pid" "kill $FOREIGN_PID"
  assert_denied "foreign literal pid with signal" "kill -9 $FOREIGN_PID"
  assert_denied "foreign literal pid with -s" "kill -s KILL $FOREIGN_PID"
  assert_denied "foreign literal pid with -KILL" "kill -KILL $FOREIGN_PID"
  assert_denied "mixed owned-looking list with a foreign pid" "kill $FOREIGN_PID $OTHER_PID"
  assert_denied "variable pid" "P=$FOREIGN_PID; kill \$P"
  assert_denied "unset variable pid" 'kill $PID'
  assert_denied "pidfile pid" 'kill $(cat /tmp/some.pid)'
  assert_denied "process group" "kill -9 -$FOREIGN_PID"
  assert_denied "all processes" "kill -9 -1"
  assert_denied "pid 0" "kill 0"
  assert_denied "init" "kill 1"
  assert_denied "kill via /bin/kill" "/bin/kill -9 $FOREIGN_PID"
  assert_denied "env kill" "env kill -9 $FOREIGN_PID"
  assert_denied "kill under a wrapper loop" "for p in $FOREIGN_PID; do kill \$p; done"
  fake_group=$(ps -o pgid= -p "$FOREIGN_PID" | tr -d ' ')
  assert_denied "foreign process group" "kill -- -$fake_group"
  assert_nothing_destroyed "foreign pid denials"
  pass "foreign / unknown / group / init / variable PIDs denied, foreign processes alive"
}

test_owned_pid_allowed_and_really_killed() {
  local owned
  start_cwd_owned
  owned=$STARTED
  alive "$owned" || fail "owned fixture did not start"
  run_hook "kill -9 $owned"
  [ "$HOOK_CODE" = 0 ] || fail "cwd-proved owned PID kill must be allowed: $HOOK_ERR"
  kill -9 "$owned"
  sleep 0.3
  alive "$owned" && fail "the allowed kill must really terminate the owned process"
  assert_nothing_destroyed "owned kill"
  pass "kill of a cwd-proved owned PID is allowed and effective"
}

test_ancestry_owned_pid_allowed() {
  local owner_pid child_pid pidfile="$TMP_ROOT/child.pid"
  # The "agent": a process outside the copy that launches a child outside the copy.
  (cd "$FOREIGN" && exec bash -c 'sleep 603 & echo $! >"$1"; wait' _ "$pidfile") >/dev/null 2>&1 &
  owner_pid=$!
  STARTED_PIDS+=("$owner_pid")
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$pidfile" ] && break; sleep 0.2; done
  child_pid=$(cat "$pidfile")
  STARTED_PIDS+=("$child_pid")
  run_hook "kill $child_pid" "$WT" --owner-pid "$owner_pid"
  [ "$HOOK_CODE" = 0 ] || fail "descendant of the agent must be allowed: $HOOK_ERR"
  run_hook "kill $child_pid" "$WT"
  [ "$HOOK_CODE" = 2 ] || fail "without the agent identity the same PID is foreign"
  run_hook "kill $FOREIGN_PID" "$WT" --owner-pid "$owner_pid"
  [ "$HOOK_CODE" = 2 ] || fail "a non-descendant stays foreign even with an agent identity"
  run_hook "kill $owner_pid" "$WT" --owner-pid "$owner_pid"
  [ "$HOOK_CODE" = 2 ] || fail "the agent must not kill itself"
  kill "$child_pid"
  pass "ancestry proves ownership; agent/supervisor chain is protected"
}

test_job_and_dead_pid_allowed() {
  assert_allowed "kill \$! of its own background job" 'sleep 30 & kill $!'
  assert_allowed "kill %1" 'kill %1'
  assert_allowed "kill \$\$" 'kill $$'
  assert_allowed "signal 0 liveness probe" "kill -0 $FOREIGN_PID"
  assert_allowed "kill -l" 'kill -l'
  assert_allowed "P=\$! then kill \$P" 'sleep 30 & P=$!; kill $P'
  assert_allowed "dead pid" "kill 999999"
  assert_allowed "python kills the .pid of its own Popen child" "python3 -c 'import subprocess; p = subprocess.Popen([\"sleep\", \"1\"]); p.kill()'"
  pass "own jobs, signal 0, dead PIDs, and own Popen children stay allowed"
}

# --- ordinary workflows must not be refused ---------------------------------

test_safe_workflows_allowed() {
  local i=0 cmd
  mkdir -p "$WT/build/sub" "$WT/dist" "$WT/node_modules/.cache"
  touch "$WT/build/sub/a.o" "$WT/note.txt" "$WT/a.pyc"
  local cmds=(
    "ls -la"
    "git status && git diff --stat"
    "git commit -m 'fix: stop using pkill in the harness'"
    "grep -rn pkill docs/ bin/"
    "echo 'never run pkill or killall'"
    "cat docs/worker-guard.md"
    "printf '%s\\n' 'rm -rf is dangerous'"
    "rm note.txt"
    "rm -f a.pyc"
    "rm -rf build"
    "rm -rf build/ dist"
    "rm -rf ./build/*"
    "rm -rf build/sub/a.o"
    "rm -rf node_modules/.cache"
    "cd build && rm -rf sub"
    "(cd dist && ls)"
    "find . -name '*.pyc' -delete"
    "find build -type f -exec rm {} +"
    "bash -c 'echo hi && ls'"
    "bash -c 'rm -rf build/sub'"
    "sh -c \"cd $WT/build && ls\""
    "python3 -c 'print(1 + 1)'"
    "python3 -c 'import shutil; shutil.rmtree(\"build\", ignore_errors=True)'"
    "node -e 'console.log(1)'"
    "python3 - <<EOF
print('hello')
EOF"
    "cat > hello.sh <<EOF
echo hello
EOF
bash hello.sh"
    "sleep 1 & wait"
    "make -j4 test"
    "npm run build"
    "timeout 5 sleep 1"
    "xargs echo < /dev/null"
    "ps aux | grep sleep"
    "pgrep -f sleep"
    "lsof -i :8000"
    "kill -l"
    "echo done"
  )
  for cmd in "${cmds[@]}"; do
    i=$((i + 1))
    assert_allowed "safe-$i" "$cmd"
  done
  pass "ordinary workflows (grep pkill, git commit text, rm inside the copy, scripts, builds, ps/pgrep reads) allowed"
}

test_rm_inside_really_works() {
  mkdir -p "$WT/gone/deep"
  touch "$WT/gone/deep/f"
  run_hook "rm -rf gone"
  [ "$HOOK_CODE" = 0 ] || fail "rm -rf inside the copy must be allowed: $HOOK_ERR"
  rm -rf "$WT/gone"
  [ ! -e "$WT/gone" ] || fail "allowed deletion must be effective"
  pass "rm -r inside the copy is allowed and effective"
}

test_extra_root_allowed() {
  local scratch="$TMP_ROOT/task-scratch"
  mkdir -p "$scratch/inner"
  local verdict
  verdict=$(hook_json "rm -rf $scratch/inner" | FM_WORKER_GUARD_EXTRA_ROOTS="$scratch" "$CHECK" --claude --owner-pid none 2>&1; echo "rc=$?")
  assert_contains "$verdict" "rc=0" "task-owned extra scratch root is allowed"
  run_hook "rm -rf $scratch"
  [ "$HOOK_CODE" = 2 ] || fail "extra root without it configured is outside"
  pass "firstmate-declared extra task roots are honored, and only those"
}

# --- transport: fail closed, payload shapes --------------------------------

test_transport_fails_closed() {
  local out code
  out=$(printf 'not json' | "$CHECK" --claude 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "unparsable payload must deny, got $code"
  assert_contains "$out" "PAYLOAD" "unparsable payload reason"
  out=$(hook_json "ls" | env -u FM_WORKER_GUARD_ROOT "$CHECK" --claude 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "missing worker root must deny, got $code"
  assert_contains "$out" "FM_WORKER_GUARD_ROOT" "missing root reason"
  out=$(hook_json "ls" | PATH=/nonexistent /bin/bash "$CHECK" --claude 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "missing node must deny, got $code"
  assert_contains "$out" "node is not available" "missing node reason"
  out=$(jq -nc --arg d "$WT" '{cwd:$d,tool_name:"Read",tool_input:{file_path:"/etc/hosts"}}' | "$CHECK" --claude 2>&1)
  code=$?
  [ "$code" = 0 ] || fail "a tool with no command is not execution-shaped and must be allowed, got $code ($out)"
  out=$(jq -nc --arg d "$WT" '{cwd:$d,tool_name:"Monitor",tool_input:{command:"pkill -f sleep"}}' | "$CHECK" --claude 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "any tool carrying a command is guarded, not only Bash (Monitor), got $code"
  pass "transport fails closed; every command-carrying tool is guarded; non-exec tools pass"
}

test_cli_and_code_modes() {
  local out
  "$CHECK" --root "$WT" --cwd "$WT" --command 'pkill -f x' >/dev/null 2>&1
  [ $? = 2 ] || fail "--command mode denies"
  "$CHECK" --root "$WT" --cwd "$WT" --command 'ls' >/dev/null 2>&1 || fail "--command mode allows"
  out=$("$CHECK" --root "$WT" --cwd "$WT" --lang python --code 'import os; os.kill(-1, 9)' 2>&1)
  [ $? = 2 ] || fail "--code mode (omp eval tool) denies"
  "$CHECK" --root "$WT" --cwd "$WT" --lang python --code 'print(1)' >/dev/null 2>&1 || fail "--code mode allows ordinary code"
  assert_contains "$out" "KILL_GROUP" "code-mode reason is typed"
  pass "CLI --command and --code (omp eval) modes share the same decision"
}

test_further_bypass_classes() {
  local i=0 cmd
  local denied=(
    "busybox rm -rf $EVIL/keep"
    "busybox pkill -f sleep"
    "find $EVIL -exec sh -c 'rm -rf {}' \\;"
    "perl -e 'unlink glob q($EVIL/keep/*)'"
    "python3 -c 'import os,glob; [os.remove(f) for f in glob.glob(\"$EVIL/keep/*\")]'"
    "git -C $EVIL clean -fdx"
    "cd $EVIL && git clean -fdx"
    "rsync -a --delete /nonexistent/ $EVIL/keep/"
    "parallel kill ::: $FOREIGN_PID"
    "sh -c \"\$(echo a2lsbCAx | base64 -d)\""
    "bash <(curl -s http://127.0.0.1:1/x.sh)"
    "ssh localhost pkill -f sleep"
  )
  for cmd in "${denied[@]}"; do
    i=$((i + 1))
    assert_denied "further-bypass-$i" "$cmd"
  done
  assert_nothing_destroyed "further bypass denials"
  assert_allowed "git clean inside the copy" "git clean -fdx"
  assert_allowed "rsync --delete inside the copy" "rsync -a --delete src/ build/"
  assert_allowed "ssh to a harmless remote command" "ssh host ls"
  assert_allowed "-c payload with an ordinary substitution" 'bash -c "cd $(pwd) && make"'
  assert_allowed "find -exec rm on files" "find . -name '*.o' -exec rm {} +"
  assert_allowed "find -exec of a harmless shell" "find . -exec sh -c 'ls {}' \\;"
  assert_allowed "busybox harmless" "busybox ls"
  pass "wrappers, find -exec shells, bulk deletes, git clean, rsync --delete, ssh, parallel, substituted and process-substituted code are denied; in-copy forms stay allowed"
}

test_review_findings_regressions() {
  local i=0 cmd
  # A script outside the copy is still worker-reachable code.
  printf '#!/usr/bin/env bash\npkill -f sleep\n' >"$TMP_ROOT/outside.sh"
  assert_denied "script outside the copy with pkill" "bash $TMP_ROOT/outside.sh"
  printf '#!/usr/bin/env bash\nrm -rf "$1"\n' >"$TMP_ROOT/outside-rm.sh"
  assert_denied "script outside the copy deleting an unprovable argument" "bash $TMP_ROOT/outside-rm.sh $EVIL/keep"
  # Versioned interpreter names are interpreters.
  assert_denied "python3.12 inline kill" "python3.12 -c 'import os; os.kill($FOREIGN_PID, 9)'"
  assert_denied "pypy3 inline kill" "pypy3 -c 'import os; os.kill($FOREIGN_PID, 9)'"
  assert_denied "ruby3.3 inline kill" "ruby3.3 -e 'Process.kill(\"KILL\", $FOREIGN_PID)'"
  assert_denied "ts-node inline kill" "tsx -e 'process.kill($FOREIGN_PID)'"
  # ssh options with values must not hide the remote command.
  assert_denied "ssh -p 22 host pkill" "ssh -p 22 localhost pkill -f sleep"
  assert_denied "ssh -i key -o X=Y host pkill" "ssh -i k -o StrictHostKeyChecking=no localhost pkill -f sleep"
  # rsync --delete: options after the operands must not hide the destination.
  assert_denied "rsync --delete with a trailing option" "rsync -a --delete src/ $EVIL/keep/ --exclude x"
  assert_denied "rsync --del short form" "rsync -a --del src/ $EVIL/keep/"
  assert_denied "rsync --delete-after" "rsync -a --delete-after src/ $EVIL/keep/"
  # A substitution may not build a command word inside inline code.
  assert_denied "command word built from echo" 'bash -c "p$(echo kill) -f sleep"'
  assert_denied "arguments built from a decoder" 'bash -c "$(echo a2lsbA== | base64 -d) -f x"'
  assert_denied "eval of a substitution" 'eval "$(printf pkill) -f sleep"'
  # Readers that can echo attacker-shaped text are not fixed metadata.
  assert_denied "head of a file as code" 'bash -c "$(head -1 /etc/hosts)"'
  assert_denied "basename building the command word" 'bash -c "$(basename /usr/bin/pkill) -f sleep"'
  assert_denied "pwd as a path prefix of the command" 'bash -c "$(pwd)/payload.sh"'
  assert_denied "printenv as code" 'bash -c "$(printenv CMD)"'
  assert_denied "git config as code" 'bash -c "$(git config --get alias.x)"'
  assert_denied "git branch name as code" 'bash -c "$(git rev-parse --abbrev-ref HEAD) -f x"'
  assert_denied "date format text as a command word" 'bash -c "$(date +pkill) -f x"'
  assert_allowed "a plain reader inside inline code" 'bash -c "cd $(pwd) && ls"'
  assert_allowed "git rev-parse inside inline code" 'bash -c "echo $(git rev-parse --short HEAD)"'
  # The trusted base is launch state: moving a branch cannot launder a script.
  printf '#!/usr/bin/env bash\nrm -rf "$1"\n' >"$WT/launder.sh"
  git -C "$WT" add launder.sh && git -C "$WT" commit -q -m "launder"
  git -C "$WT" branch -f main HEAD
  git -C "$WT" update-ref refs/remotes/origin/main HEAD
  assert_denied "branch moved to include a deleting script" "bash launder.sh $EVIL/keep"
  git -C "$WT" branch -f main "$FM_WORKER_GUARD_BASE"
  git -C "$WT" update-ref -d refs/remotes/origin/main
  assert_nothing_destroyed "review-finding regressions"
  pass "scripts outside the copy, versioned interpreters, ssh options, rsync options, substituted command words, and a movable base ref are all covered"
}

test_fails_closed_never_leaks_a_non_blocking_exit() {
  local code out stub
  # The claude hook command exactly as the launch line carries it (consumer
  # behavior: claude blocks only on exit 2).
  local hook='"$FM_WORKER_GUARD_CHECK" --claude; c=$?; [ $c -eq 0 ] || { [ $c -eq 2 ] || echo "worker-guard: guard unavailable (exit $c); tool call refused" >&2; exit 2; }'
  out=$(hook_json "ls" | env -u FM_WORKER_GUARD_CHECK sh -c "$hook" 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "an unset guard path must still block, got $code ($out)"
  out=$(hook_json "ls" | FM_WORKER_GUARD_CHECK="$TMP_ROOT/not-executable" sh -c "$hook" 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "a missing guard binary must still block, got $code"
  # A transport copy whose policy cannot even be imported must exit 2, not 1.
  stub="$TMP_ROOT/broken-bin"
  mkdir -p "$stub"
  cp "$CHECK" "$stub/fm-worker-guard-pretool-check.sh"
  printf 'import { nothingHere } from "./does-not-exist.mjs";\n' >"$stub/fm-worker-guard-policy.mjs"
  out=$(hook_json "ls" | FM_WORKER_GUARD_CHECK="$stub/fm-worker-guard-pretool-check.sh" sh -c "$hook" 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "a crashing policy must block, got $code ($out)"
  assert_contains "$out" "worker-guard" "crash reason names the guard"
  pass "an unset path, missing binary, or crashing policy always leaves exit 2"
}

test_dead_pid_is_decided_by_the_kernel_not_ps() {
  local out code
  # ps unusable: the process listing is empty, yet a live foreign PID stays foreign.
  mkdir -p "$TMP_ROOT/brokenps"
  printf '#!/bin/sh\nexit 1\n' >"$TMP_ROOT/brokenps/ps"
  chmod +x "$TMP_ROOT/brokenps/ps"
  out=$(hook_json "kill $FOREIGN_PID" | PATH="$TMP_ROOT/brokenps:$PATH" "$CHECK" --claude --owner-pid none 2>&1)
  code=$?
  [ "$code" = 2 ] || fail "a foreign PID must stay denied when ps is unusable, got $code"
  alive "$FOREIGN_PID" || fail "foreign process died"
  pass "a failing ps cannot turn a live foreign PID into a dead one"
}

test_xargs_rm_without_recursion_is_not_refused() {
  assert_allowed "xargs rm -f on a name list" "find . -name '*.tmp' | xargs rm -f"
  assert_denied "xargs rm -rf" "find . -name '*.tmp' | xargs rm -rf"
  pass "xargs rm is refused only when recursive"
}

test_scripts_are_shellcheck_clean() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$CHECK" || fail "transport must be shellcheck-clean"
  fi
  pass "transport is shellcheck-clean"
}

test_broad_kill_denied
test_script_bypass_denied
test_script_files_in_tree
test_rm_outside_denied
test_copy_prefix_is_not_ownership
test_foreign_pid_denied
test_owned_pid_allowed_and_really_killed
test_ancestry_owned_pid_allowed
test_job_and_dead_pid_allowed
test_safe_workflows_allowed
test_rm_inside_really_works
test_extra_root_allowed
test_transport_fails_closed
test_cli_and_code_modes
test_further_bypass_classes
test_review_findings_regressions
test_fails_closed_never_leaks_a_non_blocking_exit
test_dead_pid_is_decided_by_the_kernel_not_ps
test_xargs_rm_without_recursion_is_not_refused
test_scripts_are_shellcheck_clean
assert_nothing_destroyed "end of suite"
pass "fm-worker-guard suite complete"
