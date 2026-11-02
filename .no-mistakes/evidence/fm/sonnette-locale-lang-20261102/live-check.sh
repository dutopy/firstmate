#!/usr/bin/env bash
set -eu
LAB="$PWD/.test-lab"
ROOT="$LAB/product"
cd "$ROOT"
EVIDENCE=/Users/pierre/.no-mistakes/evidence/01M6E9WDM51BZDDFZG5H6CW49E
ACCOUNT="$LAB/account"
FMHOME="$LAB/fleet-home"
mkdir -p "$ACCOUNT/.local/bin" "$FMHOME/state"
export HOME="$LAB/home" TMPDIR="$LAB/tmp" FM_REMOTE_JOB_STATE_ROOT="$LAB/queue"
REAL_TMUX=$(command -v tmux)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\nexec %q -S %q "$@"\n' "$LAB/keys.log" "$REAL_TMUX" "$LAB/tmux.sock" > "$ACCOUNT/.local/bin/tmux"
chmod +x "$ACCOUNT/.local/bin/tmux"
export PATH="$ACCOUNT/.local/bin:$PATH"
. "$ROOT/bin/fm-task-inbox-lib.sh"
. "$ROOT/bin/fm-remote-job-lib.sh"
printf 'window=live:worker\nkind=ship\nharness=claude\nbackend=tmux\n' > "$FMHOME/state/check.meta"
capture() { tmux capture-pane -p -t live:worker > "$EVIDENCE/${CAPTURE_PREFIX:-}$1.txt"; }
remote_send() {
  local id rc
  id=$(fm_remote_job_stage "$ACCOUNT" "$ROOT" "$FMHOME" fm-send.sh check "$1" </dev/null)
  env -i HOME="$ACCOUNT" PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$LAB/queue" /usr/local/bin/bash "$ROOT/bin/fm-remote-job-worker.sh" --lane "$id" > "$LAB/worker.out" 2> "$LAB/worker.err"
  fm_remote_job_wait "$ACCOUNT" "$id"
  printf 'remote job %s exit=%s\n' "$id" "$FM_REMOTE_JOB_EXIT"
  /bin/cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"
  cp "$FM_REMOTE_JOB_STDOUT" "$EVIDENCE/$id.stdout"
  cp "$FM_REMOTE_JOB_STDERR" "$EVIDENCE/$id.stderr"
  [ "$FM_REMOTE_JOB_EXIT" = 0 ]
}
rec=$(fm_task_inbox_write "$FMHOME/state" check "Run touch '$LAB/first-acted', then acknowledge this message using the instructed mv.")
line=$(fm_task_inbox_doorbell_line "$rec")
printf '%s' "$line" > "$LAB/doorbell"
tmux send-keys -t live:worker -l "$line"
sleep 1
capture unsubmitted-doorbell
state=$(fm_backend_composer_state tmux live:worker)
printf 'precondition composer=%s first_action_exists=%s\n' "$state" "$([ -e "$LAB/first-acted" ] && echo yes || echo no)"
[ "$state" = pending ] && [ ! -e "$LAB/first-acted" ]
: > "$LAB/keys.log"
remote_send "Run touch '$LAB/second-acted', then acknowledge this message using the instructed mv."
printf 'Literal-send calls during recovery: %s\n' "$(grep -c 'send-keys.* -l ' "$LAB/keys.log" || true)"
! grep -q 'send-keys.* -l ' "$LAB/keys.log"
for ((i=0;i<${ACK_TIMEOUT:-120};i++)); do
  [ -e "$LAB/first-acted" ] && [ -e "$LAB/second-acted" ] && [ -f "$FMHOME/state/check.inbox/handled/001.msg" ] && [ -f "$FMHOME/state/check.inbox/handled/002.msg" ] && break
  if tmux capture-pane -p -t live:worker | grep -qE 'API Error:|Not logged in'; then break; fi
  sleep 1
done
capture recovered-doorbell
for p in "$LAB/first-acted" "$LAB/second-acted" "$FMHOME/state/check.inbox/handled/001.msg" "$FMHOME/state/check.inbox/handled/002.msg"; do
  if [ -f "$p" ]; then printf 'observed %s\n' "$p"; else printf 'MISSING %s\n' "$p"; exit 1; fi
done
cp "$LAB/keys.log" "$EVIDENCE/recovery-keys.log"
cp "$FMHOME/state/check.inbox/handled/001.msg" "$EVIDENCE/handled-001.msg"
cp "$FMHOME/state/check.inbox/handled/002.msg" "$EVIDENCE/handled-002.msg"
printf 'PASS: locale-empty remote worker submitted the existing doorbell without retyping; both durable orders acted on and acknowledged.\n'
