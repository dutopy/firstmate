#!/usr/bin/env bash
set -eu
LAB="$PWD/.test-lab"
ROOT="$LAB/product"
EVIDENCE=/Users/pierre/.no-mistakes/evidence/01M6E9WDM51BZDDFZG5H6CW49E
ACCOUNT="$LAB/account"
FMHOME="$LAB/fleet-home"
export HOME="$LAB/home" TMPDIR="$LAB/tmp" PATH="$ACCOUNT/.local/bin:$PATH" FM_REMOTE_JOB_STATE_ROOT="$LAB/queue"
cd "$ROOT"
. "$ROOT/bin/fm-task-inbox-lib.sh"
. "$ROOT/bin/fm-remote-job-lib.sh"
for ((i=0;i<60;i++)); do
 if [ "$(fm_backend_composer_state tmux live:worker)" = empty ] && ! tmux capture-pane -p -t live:worker | grep -q 'esc to interrupt'; then break; fi
 sleep 1
done
line=$(<"$LAB/doorbell")
rec="$FMHOME/state/check.inbox/handled/001.msg"
for name in human different-path partial added-text; do
 case "$name" in
  human) draft='Do not submit this human draft' ;;
  different-path) draft=${line//check.inbox/other.inbox} ;;
  partial) draft=${line:0:100} ;;
  added-text) draft="$line DO NOT SUBMIT" ;;
 esac
 tmux send-keys -t live:worker -l "$draft"
 sleep 0.5
 [ "$(fm_backend_composer_state tmux live:worker)" = pending ]
 tmux capture-pane -p -t live:worker > "$EVIDENCE/guard-$name-before.txt"
 : > "$LAB/keys.log"
 rc=0
 fm_task_inbox_ring tmux live:worker "$rec" || rc=$?
 [ "$rc" = 1 ]
 ! grep -q '^send-keys ' "$LAB/keys.log"
 tmux capture-pane -p -t live:worker > "$EVIDENCE/guard-$name-after.txt"
 printf 'protected %s: ring_exit=%s; no text or keys sent; composer remains %s\n' "$name" "$rc" "$(fm_backend_composer_state tmux live:worker)"
 [ "$(fm_backend_composer_state tmux live:worker)" = pending ]
 # Claude deletes only the current visual row with Ctrl-U.
 for ((clear=0;clear<10;clear++)); do
   tmux send-keys -t live:worker C-u
   sleep 0.2
   [ "$(fm_backend_composer_state tmux live:worker)" != empty ] || break
 done
 [ "$(fm_backend_composer_state tmux live:worker)" = empty ]
done
# A matching earlier doorbell is now in the transcript, but the selected
# composer is empty: the next real remote steer must type its own doorbell.
: > "$LAB/keys.log"
id=$(fm_remote_job_stage "$ACCOUNT" "$ROOT" "$FMHOME" fm-send.sh check "Run touch '$LAB/third-acted', then acknowledge this message using the instructed mv." </dev/null)
env -i HOME="$ACCOUNT" PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$LAB/queue" /usr/local/bin/bash "$ROOT/bin/fm-remote-job-worker.sh" --lane "$id"
fm_remote_job_wait "$ACCOUNT" "$id"
printf 'normal remote steer exit=%s\n' "$FM_REMOTE_JOB_EXIT"
/bin/cat "$FM_REMOTE_JOB_STDOUT" "$FM_REMOTE_JOB_STDERR"
[ "$FM_REMOTE_JOB_EXIT" = 0 ]
! grep -q 'doorbell skipped' "$FM_REMOTE_JOB_STDERR"
[ "$(grep -c 'send-keys.* -l ' "$LAB/keys.log" || true)" = 1 ]
for ((i=0;i<120;i++)); do
 [ -f "$LAB/third-acted" ] && [ -f "$FMHOME/state/check.inbox/handled/003.msg" ] && break
 sleep 1
done
[ -f "$LAB/third-acted" ] && [ -f "$FMHOME/state/check.inbox/handled/003.msg" ]
tmux capture-pane -p -t live:worker > "$EVIDENCE/normal-steer-after-transcript.txt"
cp "$FMHOME/state/check.inbox/handled/003.msg" "$EVIDENCE/handled-003.msg"
cp "$LAB/keys.log" "$EVIDENCE/normal-steer-keys.log"
printf 'PASS: matching transcript did not replace the selected empty composer; exactly one literal doorbell was sent and the third order was acted on and acknowledged.\n'
