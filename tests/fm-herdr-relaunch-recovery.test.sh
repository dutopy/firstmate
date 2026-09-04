#!/usr/bin/env bash
# Portable regression coverage for Herdr lifecycle recovery after an agent exits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-relaunch-recovery)
mkdir -p "$TMP_ROOT/fakebin"
STATE="$TMP_ROOT/herdr.json"
LOG="$TMP_ROOT/herdr.log"
: > "$LOG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$TMP_ROOT/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
{
  printf 'call'
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"

save_state() {
  local tmp="$state.tmp.$$"
  cat > "$tmp" && mv "$tmp" "$state"
}

case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}\n'
    ;;
  "pane get")
    pane=${3:-}
    jq --arg pane "$pane" '{id:"cli:pane:get",result:{type:"pane_info",pane:{pane_id:$pane,foreground_cwd:.cwd}}}' "$state"
    ;;
  "agent get")
    pane=${3:-}
    if [ "$(jq -r '.registered' "$state")" = true ]; then
      jq --arg pane "$pane" '{id:"cli:agent:get",result:{type:"agent_info",agent:{pane_id:$pane,agent:"pi",agent_status:"idle"}}}' "$state"
    else
      printf '{"id":"cli:agent:get","error":{"code":"agent_not_found"}}\n'
    fi
    ;;
  "pane process-info")
    pane=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --pane ]; then pane=${2:-}; break; fi
      shift
    done
    if [ "$(jq -r '.process_info_failures // 0' "$state")" -gt 0 ]; then
      jq '.process_info_failures -= 1' "$state" | save_state
      printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"wrong"}}}\n'
      exit 0
    fi
    mode=$(jq -r '.process' "$state")
    case "$mode" in
      shell)
        jq -n --arg pane "$pane" '{id:"cli:pane:process_info",result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:41001,foreground_process_group_id:41001,foreground_processes:[{pid:41001,name:"bash",argv:["/bin/bash"]}]}}}'
        ;;
      live)
        jq -n --arg pane "$pane" '{id:"cli:pane:process_info",result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:41001,foreground_process_group_id:41002,foreground_processes:[{pid:41002,name:"pi",argv:["/opt/pi/bin/pi"]}]}}}'
        ;;
      *) printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"wrong"}}}\n' ;;
    esac
    ;;
  "pane send-text")
    text=${4:-}
    jq --arg text "$text" '
      .pending=((.pending // "") + $text)
      | if .fail_after_send_once then .fail_after_send_once=false | .process_info_failures=1 else . end
      | if ((.process_after_send // "") != "") then .process=.process_after_send else . end
    ' "$state" | save_state
    ;;
  "pane run")
    text=${4:-}
    pending=$(jq -r '.pending // empty' "$state")
    cwd=$(jq -r '.cwd' "$state")
    new_cwd=$(cd "$cwd" && bash -c "$pending$text; pwd -P") || exit 1
    jq --arg cwd "$new_cwd" '.cwd=$cwd | .pending=""' "$state" | save_state
    ;;
  "pane send-keys")
    key=${4:-}
    if [ "$key" = ctrl+c ]; then
      jq '.pending=""' "$state" | save_state
    elif [ "$key" = enter ]; then
      pending=$(jq -r '.pending // empty' "$state")
      cwd=$(jq -r '.cwd' "$state")
      if [ -n "$pending" ]; then
        new_cwd=$(cd "$cwd" && bash -c "$pending; pwd -P") || exit 1
        jq --arg cwd "$new_cwd" '.cwd=$cwd | .pending=""' "$state" | save_state
      fi
    fi
    ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/herdr"

cat > "$TMP_ROOT/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '41001 1\n' ;;
  "-p 41001 -o stat=") printf 'S\n' ;;
  "-p 41001 -o comm=") printf 'bash\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/ps"

cat > "$TMP_ROOT/fakebin/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/claude"

write_state() {
  jq -n --arg cwd "$1" --arg process "$2" --argjson registered "$3" \
    '{cwd:$cwd,process:$process,registered:$registered,pending:"",fail_after_send_once:false,process_info_failures:0,process_after_send:""}' > "$STATE"
  : > "$LOG"
}

run_backend() {
  PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_FAKE_HERDR_STATE="$STATE" FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    bash -c '. "$0/bin/fm-backend.sh"; "$@"' "$ROOT" "$@"
}

OLD="$TMP_ROOT/old"
mkdir -p "$OLD"

write_state "$OLD" shell true
ordinary=$(run_backend fm_backend_agent_state herdr fmtest:w1:p1)
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$ordinary" = alive ] || fail "the ordinary Herdr registry read should remain alive, got '$ordinary'"
[ "$recovery" = dead ] || fail "a retained registration over one lone idle shell should be dead for lifecycle recovery, got '$recovery'"
pass "Herdr relaunch recovery: a provably stale registered-agent report reconciles to agent-free"

write_state "$OLD" live true
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$recovery" = alive ] || fail "a registered agent with a distinct foreground process group must remain alive, got '$recovery'"
pass "Herdr relaunch recovery: a real foreground agent remains alive and cannot be replaced"

write_state "$OLD" ambiguous true
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$recovery" = unreadable ] || fail "an ambiguous registered process surface must remain unreadable, got '$recovery'"
pass "Herdr relaunch recovery: ambiguous process evidence refuses rather than becoming agent-free"

TARGET="$TMP_ROOT/recorded ' ; touch PWNED ; #"
mkdir -p "$TARGET"
write_state "$OLD" shell true
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "an agent-free Herdr shell should restore to its exact recorded path"
seen=$(jq -r '.cwd' "$STATE")
[ "$seen" = "$TARGET" ] || fail "the restored foreground cwd should equal the quoted recorded path, got '$seen'"
[ ! -e "$OLD/PWNED" ] || fail "recorded-path bytes escaped shell quoting and executed as syntax"
command=$(awk -F '\x1f' '$2 == "pane" && $3 == "send-text" {print $5}' "$LOG")
case "$command" in "cd -- "*) ;; *) fail "path restoration did not submit a cd command: $command" ;; esac
count_before=$(grep -c $'\x1fpane\x1fsend-text\x1f' "$LOG" || true)
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "repeated exact-path preparation should be an idempotent success"
count_after=$(grep -c $'\x1fpane\x1fsend-text\x1f' "$LOG" || true)
[ "$count_after" -eq "$count_before" ] || fail "idempotent path preparation submitted a second cd command"
pass "Herdr relaunch recovery: exact path restoration is persistent, quoted, and idempotent"

EXACT_MARKER="$TMP_ROOT/exact-cwd-marker"
write_state "$TARGET" shell true
jq --arg pending "touch '$EXACT_MARKER'; " '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "exact-cwd preparation should still clear pending shell input"
[ ! -e "$EXACT_MARKER" ] || fail "exact-cwd preparation executed preexisting buffered shell input"
[ -z "$(jq -r '.pending // empty' "$STATE")" ] || fail "exact-cwd preparation left shell input buffered"
pass "Herdr relaunch recovery: exact-cwd preparation still clears shell input"

BUFFERED_MARKER="$TMP_ROOT/buffered-marker"
write_state "$OLD" shell true
jq --arg pending "touch '$BUFFERED_MARKER'; " '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "path restoration should clear preexisting idle-shell input before submitting"
[ ! -e "$BUFFERED_MARKER" ] || fail "path restoration executed preexisting buffered shell input"
[ "$(jq -r '.cwd' "$STATE")" = "$TARGET" ] || fail "path restoration lost the recorded path after clearing buffered input"
pass "Herdr relaunch recovery: preexisting shell input is cancelled before path restoration"

write_state "$OLD" shell true
jq '.fail_after_send_once=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "a transient post-send process inspection failure should abort path restoration"
fi
[ -z "$(jq -r '.pending // empty' "$STATE")" ] || fail "failed path restoration left its command buffered for a retry"
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "path restoration should retry cleanly after post-send cleanup"
[ "$(jq -r '.cwd' "$STATE")" = "$TARGET" ] || fail "the clean retry did not restore the recorded path"
pass "Herdr relaunch recovery: pre-submit failures clean their buffered command for retry"

write_state "$OLD" shell true
jq '.process_after_send="live"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "path restoration should refuse when the shell owner changes after typing"
fi
[ -n "$(jq -r '.pending // empty' "$STATE")" ] || fail "cleanup sent input after the pane stopped belonging to the exact idle shell"
pass "Herdr relaunch recovery: cleanup refuses a changed shell owner"

DIRECT_HOME="$TMP_ROOT/direct-home"
DIRECT_PROJECT="$TMP_ROOT/direct-project"
DIRECT_WT="$TMP_ROOT/direct-worktree"
DIRECT_MARKER="$TMP_ROOT/direct-marker"
fm_git_worktree "$DIRECT_PROJECT" "$DIRECT_WT" direct-relaunch
mkdir -p "$DIRECT_HOME/state" "$DIRECT_HOME/data/direct"
cat > "$DIRECT_HOME/data/direct/brief.md" <<'EOF'
# Task
## Captain's intent
Resume the existing worker safely.

## Firstmate spec
Relaunch in the recorded worktree.
EOF
cat > "$DIRECT_HOME/state/direct.meta" <<EOF
window=fmtest:w1:p1
endpoint_task_id=direct
worktree=$DIRECT_WT
project=$DIRECT_PROJECT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
backend=herdr
herdr_session=fmtest
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
EOF
write_state "$DIRECT_WT" shell true
jq --arg pending "touch '$DIRECT_MARKER'; " '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
  FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness claude 2>&1) \
  || fail "direct Herdr relaunch should prepare its endpoint before launch: $DIRECT_OUT"
[ ! -e "$DIRECT_MARKER" ] || fail "direct Herdr relaunch executed buffered shell input before launch"
case "$DIRECT_OUT" in *"spawned direct "*) : ;; *) fail "direct Herdr relaunch did not complete: $DIRECT_OUT" ;; esac
pass "fm-spawn relaunch: direct Herdr entry prepares buffered shell input"

write_state "$OLD" live true
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "path restoration must refuse while a real foreground agent remains"
fi
! grep -q $'\x1fpane\x1fsend-text\x1f' "$LOG" || fail "live-agent refusal typed a shell command"
pass "Herdr relaunch recovery: live-agent refusal sends no path-changing input"

write_state "$OLD" ambiguous true
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "path restoration must refuse ambiguous endpoint evidence"
fi
! grep -q $'\x1fpane\x1fsend-text\x1f' "$LOG" || fail "ambiguous-state refusal typed a shell command"
pass "Herdr relaunch recovery: ambiguous-state refusal sends no path-changing input"

run_backend fm_backend_prepare_relaunch_path tmux ignored "$TARGET" \
  || fail "tmux relaunch path preparation should retain its existing no-op behavior"
if run_backend fm_backend_prepare_relaunch_path zellij ignored "$TARGET" >/dev/null 2>&1; then
  fail "a backend without verified lifecycle recovery must not gain path-changing behavior"
fi
pass "Relaunch path recovery: tmux remains unchanged and unverified backends refuse"
