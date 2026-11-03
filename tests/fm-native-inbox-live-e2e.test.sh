#!/usr/bin/env bash
# Real unsubmitted composers, native delivery, executed instructions, and inbox
# acknowledgement. External-editor export / Pi's native editor API proves the
# ENTIRE draft remains identical; rendered rows are never delivery authority.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fm_live_gate opt-in FM_NATIVE_INBOX_LIVE_E2E tmux node
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-native-inbox-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCKET="fm-native-inbox-live-$$"
SESSION=nativelive
TIMEOUT=${FM_NATIVE_INBOX_LIVE_TIMEOUT:-180}
REAL_TMUX=$(command -v tmux)
CHECKED=0 FAILED=0
cleanup() {
  for h in pi codex opencode idle; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$h" C-c C-c C-d 2>/dev/null || true
  done
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/shim" "$LAB/state"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/bin/fm-task-inbox-lib.sh"
MODULE="$ROOT/bin/fm-native-inbox.mjs"
# This is a TEST OPERATOR: it exports the real harness buffer. Only set_draft
# supplies a one-shot replacement, removed before testing delivery. Subsequent
# snapshots cannot restore a buffer accidentally cleared by the harness API.
cat > "$LAB/editor.sh" <<'SH'
#!/usr/bin/env bash
set -eu
cp "$1" "$FM_NATIVE_EDITOR_SNAPSHOT"
if [ -f "$FM_NATIVE_EDITOR_SEED" ]; then
  cp "$FM_NATIVE_EDITOR_SEED" "$1"
  rm "$FM_NATIVE_EDITOR_SEED"
fi
SH
chmod +x "$LAB/editor.sh"
tmux new-session -d -s "$SESSION" -n idle -x 220 -y 50 -c "$LAB" -- sleep 3600
snapshot() { # harness
  local h=$1 i=0
  if [ "$h" != pi ]; then
    rm -f "$LAB/$h.snapshot"
    case "$h" in codex) tmux send-keys -t "$SESSION:$h" C-g ;;
      opencode) tmux send-keys -t "$SESSION:$h" C-x e ;; esac
  fi
  while [ ! -f "$LAB/$h.snapshot" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  test -f "$LAB/$h.snapshot"
}
set_draft() { # harness expected-file
  local h=$1 expected=$2 i=0
  cp "$expected" "$LAB/$h.seed"
  if [ "$h" != pi ]; then snapshot "$h" || return 1; fi
  while [ -f "$LAB/$h.seed" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  test ! -f "$LAB/$h.seed" || return 1
  sleep 0.3
  snapshot "$h" && cmp -s "$expected" "$LAB/$h.snapshot"
}
check_harness() { # pi|codex|opencode
  local h=$1 version config launch i case_name index=0 rec handled acted line
  version=$("$h" --version 2>/dev/null)
  printf 'backend=tmux\nwindow=%s:%s\nharness=%s\n' "$SESSION" "$h" "$h" > "$LAB/state/$h.meta"
  mkdir -p "$LAB/state/$h.inbox/handled" "$LAB/$h-project"
  config=$(node "$MODULE" arm "$LAB/state" "$h" "$h" "$LAB/$h-project") || return 1
  case "$h" in
    pi)
      cat > "$LAB/pi-extension.ts" <<JS
import {installPiNativeInbox} from "$MODULE";
import {readFileSync,writeFileSync,renameSync,existsSync,unlinkSync} from 'node:fs';
export default function(pi) {
  installPiNativeInbox(pi, "$config");
  pi.on('session_start', (_event,ctx) => {
    const timer=setInterval(()=>{
      if(existsSync("$LAB/pi.seed")) {
        const text=readFileSync("$LAB/pi.seed",'utf8');
        unlinkSync("$LAB/pi.seed");
        ctx.ui.setEditorText(text);
      }
      writeFileSync("$LAB/pi.snapshot.tmp",ctx.ui.getEditorText());
      renameSync("$LAB/pi.snapshot.tmp","$LAB/pi.snapshot");
    },100);
    pi.on('session_shutdown',()=>clearInterval(timer));
  });
}
JS
      launch="pi --no-extensions --no-skills --no-context-files --no-session --tui-mode regular --approve -e '$LAB/pi-extension.ts'"
      ;;
    codex)
      launch="node '$MODULE' codex '$config' -- codex --dangerously-bypass-approvals-and-sandbox --disable hooks 'Reply native-ready. Do not run commands.'"
      ;;
    opencode)
      mkdir -p "$LAB/$h-project/.opencode/plugins"
      cat > "$LAB/$h-project/.opencode/plugins/fm-native.js" <<JS
import {openCodeNativeInbox} from "$MODULE";
export const nativeInbox=async({client})=>{
  const actor=openCodeNativeInbox(client,"$config");
  return {"chat.message":actor.message,event:async({event})=>actor.event(event)};
};
JS
      launch="OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode --model '${FM_NATIVE_INBOX_OPENCODE_MODEL:-opencode-go/deepseek-v4.1-flash}' --prompt 'Reply native-ready. Do not run commands.'"
      ;;
  esac
  tmux new-window -d -t "$SESSION:" -n "$h" -c "$LAB/$h-project" -- env \
    EDITOR="$LAB/editor.sh" VISUAL="$LAB/editor.sh" \
    FM_NATIVE_EDITOR_SNAPSHOT="$LAB/$h.snapshot" FM_NATIVE_EDITOR_SEED="$LAB/$h.seed" \
    bash -c "$launch" || return 1
  i=0
  while [ ! -f "$LAB/state/$h.native-inbox.binding.json" ] && [ "$i" -lt "$TIMEOUT" ]; do sleep 1; i=$((i+1)); done
  if [ ! -f "$LAB/state/$h.native-inbox.binding.json" ]; then
    printf 'not ok - %s (%s): real native session never bound\n' "$h" "$version"
    tmux capture-pane -p -t "$SESSION:$h"
    return 1
  fi
  # The positive case is the actual stranded canonical doorbell. Negatives
  # include unrelated text, a hidden human tail, and a partial doorbell.
  for case_name in stranded unrelated hidden-tail partial; do
    index=$((index+1))
    rec=$(printf '%s/state/%s.inbox/%03d.msg' "$LAB" "$h" "$index")
    handled="$LAB/state/$h.inbox/handled/${rec##*/}"
    acted="$LAB/$h-$case_name.acted"
    printf "Run exactly: printf 'native-%s' > '%s'; mv '%s' '%s' . Then reply with one short line.\n" "$case_name" "$acted" "$rec" "$handled" > "$rec"
    line=$(fm_task_inbox_doorbell_line "$rec") || return 1
    case "$case_name" in
      stranded) printf '%s' "$line" > "$LAB/$h.expected" ;;
      unrelated) printf '%s' 'HUMAN DRAFT - NEVER SUBMIT' > "$LAB/$h.expected" ;;
      hidden-tail) printf '%s\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nHUMAN DRAFT - NEVER SUBMIT' "$line" > "$LAB/$h.expected" ;;
      partial) printf '%s' "${line:0:30}" > "$LAB/$h.expected" ;;
    esac
    set_draft "$h" "$LAB/$h.expected" || { printf 'not ok - %s: cannot prove real %s composer before native delivery\n' "$h" "$case_name"; return 1; }
    test -f "$rec" && test ! -f "$acted" || return 1
    fm_task_inbox_ring tmux "$SESSION:$h" "$rec" || { printf 'not ok - %s: native resend refused %s\n' "$h" "$case_name"; return 1; }
    i=0
    while [ "$i" -lt "$TIMEOUT" ]; do
      [ -f "$handled" ] && [ -f "$acted" ] && break
      sleep 1; i=$((i+1))
    done
    if [ ! -f "$handled" ] || [ ! -f "$acted" ] || [ "$(cat "$acted")" != "native-$case_name" ]; then
      printf 'not ok - %s (%s): %s native instruction not executed and acknowledged\n' "$h" "$version" "$case_name"
      tmux capture-pane -p -t "$SESSION:$h"
      return 1
    fi
    sleep 1
    snapshot "$h" && cmp -s "$LAB/$h.expected" "$LAB/$h.snapshot" || {
      printf 'not ok - %s (%s): native delivery changed the real %s draft\n' "$h" "$version" "$case_name"; return 1;
    }
    printf 'ok - %s (%s): %s draft unchanged; native instruction executed and inbox record acknowledged\n' "$h" "$version" "$case_name"
  done
  CHECKED=$((CHECKED+1))
}
HARNESSES=${FM_NATIVE_INBOX_LIVE_HARNESSES:-'pi codex opencode'}
for h in $HARNESSES; do
  case "$h" in pi|codex|opencode) ;; *) printf 'not ok - unsupported native harness: %s\n' "$h"; FAILED=1; continue ;; esac
  if ! command -v "$h" >/dev/null; then printf '# harness absent, not verified here: %s\n' "$h"; continue; fi
  check_harness "$h" || FAILED=1
done
[ "$FAILED" -eq 0 ] && [ "$CHECKED" -gt 0 ]
