#!/usr/bin/env bash
# fm-turnend-guard-clear.sh - clear a saturated primary session's accumulated
# turn-end follow-ups and restart the bounded follow-up ladder.
#
# Usage: fm-turnend-guard-clear.sh
#        fm-turnend-guard-clear.sh --help
#
# WHY THIS EXISTS. A primary session whose supervision stays down while a pane
# keeps repeating a wake accumulates guard-driven follow-ups. That accumulation
# is bounded by design (the harness-side ceiling in the passive adapter plus the
# firstmate-owned early-alert/final-notice rungs in bin/fm-turnend-guard.sh), but
# a session that already accumulated them before the bound bit - or whose ladder
# was spent and has since recovered - needs an OPERATION to reset it, not an
# improvisation. This script is that operation.
#
# WHAT IT DOES. It removes, in this home's state directory, exactly the records
# that carry the passive-adapter follow-up ladder:
#   .turnend-pi-followups    Pi's consecutive guard-driven follow-up count and,
#                            when the harness-side ceiling stopped it, the
#                            "stopped=ceiling" record naming why.
#   .turnend-followup-alert  the shared guard's one-shot early-alert marker.
#   .turnend-followup-final  the shared guard's one-shot final-notice marker.
# Effect: the ladder restarts from zero and the one-shot alerts can be raised
# again for a genuinely new episode. Nothing else is touched: the durable wake
# queue, task records, worktrees, and unlanded work are all left alone, and no
# watcher is started, stopped, or signalled.
#
# WHAT IT DOES NOT DO. It does not remove the follow-up messages ALREADY QUEUED
# in the session - a shell script cannot reach another process's TUI queue. It
# prints the exact keys that do, including the Herdr shortcut conflict and the
# reliable pane-key path, because that half is an interactive operation on the
# session's own pane (docs/turnend-guard.md "Clearing accumulated follow-ups").
#
# Exit status: 0 on success (including "nothing to clear"), 2 on invalid use.
# Bash 3.2 compatible.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
Usage: fm-turnend-guard-clear.sh

Clears this home's passive-adapter turn-end follow-up ladder records so a
saturated primary session restarts it from zero, then prints the exact keys that
drain the follow-up messages already queued in that session without submitting
them.

Removes, in the state directory (FM_STATE_OVERRIDE wins over FM_HOME/state):
  .turnend-pi-followups     Pi's consecutive follow-up count / ceiling record
  .turnend-followup-alert   the shared guard's one-shot early-alert marker
  .turnend-followup-final   the shared guard's one-shot final-notice marker

Leaves alone: the durable wake queue, task records, worktrees, unlanded work,
and every watcher process.

Environment: FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE.

Exit status: 0 on success (including nothing to clear), 2 on invalid use.
EOF
}

case "${1-}" in
  '') ;;
  --help|-h) usage; exit 0 ;;
  *) echo "usage: $(basename "$0") [--help]" >&2; exit 2 ;;
esac

removed=0
for name in .turnend-pi-followups .turnend-followup-alert .turnend-followup-final; do
  if [ -e "$STATE/$name" ]; then
    if rm -f "$STATE/$name" 2>/dev/null; then
      printf 'cleared: %s\n' "$STATE/$name"
      removed=$((removed + 1))
    else
      printf 'error: could not remove %s\n' "$STATE/$name" >&2
      exit 1
    fi
  fi
done
[ "$removed" -gt 0 ] || printf 'cleared: nothing (no follow-up ladder records in %s)\n' "$STATE"

cat <<'EOF'

The follow-up messages ALREADY queued in the session are not removed by the
command above. Drain them on the session's own pane, WITHOUT submitting them:

  Attached directly to the Pi session:
    1. Alt+Up  - Pi's app.message.dequeue: restores the queued follow-up
                 messages into the editor. They are NOT submitted.
    2. Ctrl+C  - Pi's app.clear: clears the editor, dropping the restored
                 messages. Press it ONCE; a second press exits Pi.

  Under Herdr the Alt+Up shortcut never reaches Pi - Herdr binds alt+up to
  previous_workspace (and alt+enter to split_horizontal), so the client consumes
  the key before the pane sees it. Send the keys straight to the pane instead:
    herdr pane send-keys <pane-id> escape
    herdr pane send-keys <pane-id> ctrl+c
  The first key aborts the run and restores the queued messages to the editor
  without submitting them; the second clears that editor.

  Under tmux:
    tmux send-keys -t <pane> Escape
    tmux send-keys -t <pane> C-c

Then restore supervision with the session-start operating block for this
harness; the ladder restarts from zero and will alert again if it repeats.
EOF
