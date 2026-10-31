#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.urgent-state unread-urgent tier: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.urgent-escalated  oldest-message name already surfaced as
#                              unread-urgent
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: a busy pane waits,
# while a positively dead or missing endpoint skips delivery and the ladder and
# escalates directly. This library owns only the schedule and escalation marker.
# Unread-urgent tier (same function): once the oldest unhandled message is
# older than FM_TASK_INBOX_URGENT_SECS it is due an urgent re-ring every
# FM_TASK_INBOX_URGENT_SECS, up to FM_TASK_INBOX_URGENT_MAX of them, and then
# one unread-urgent escalation. Unlike the idle ladder above, the caller does
# not hold an urgent re-ring for a busy pane: a pane that has looked busy for
# that long is either genuinely mid-turn, where a TUI queues the typed line for
# its next turn, or misread as busy, which is exactly how a message used to
# sit unread for hours. The composer pre-check in the doorbell still protects
# proven pending text. The tier is independent of the idle ladder's escalation,
# so a message that the idle ladder already surfaced still gets its urgent
# re-rings and a distinct unread-urgent event. FM_TASK_INBOX_URGENT_SECS=0
# disables the tier; it is evaluated only once a message is past
# FM_TASK_INBOX_GRACE_SECS.
# If attempt bookkeeping cannot be persisted while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation
#   FM_TASK_INBOX_URGENT_SECS  default 360; unacknowledged age before an
#                              urgent re-ring, and their spacing (0 disables)
#   FM_TASK_INBOX_URGENT_MAX   default 2; urgent re-rings before the
#                              unread-urgent escalation
#   FM_TASK_INBOX_RING_ATTEMPTS default 3; bounded submit attempts inside one
#                              doorbell (fm_task_inbox_ring)
#   FM_TASK_INBOX_ENTER_PAUSE  default 1; seconds between the doorbell's
#                              submitting Enter and its confirming Enter

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5
FM_TASK_INBOX_URGENT_SECS_DEFAULT=360
FM_TASK_INBOX_URGENT_MAX_DEFAULT=2
FM_TASK_INBOX_RING_ATTEMPTS_DEFAULT=3
FM_TASK_INBOX_ENTER_PAUSE_DEFAULT=1

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_urgent_secs() {
  local u=${FM_TASK_INBOX_URGENT_SECS:-$FM_TASK_INBOX_URGENT_SECS_DEFAULT}
  case "$u" in ''|*[!0-9]*) u=$FM_TASK_INBOX_URGENT_SECS_DEFAULT ;; esac
  printf '%s' "$u"
}

fm_task_inbox_urgent_max() {
  local m=${FM_TASK_INBOX_URGENT_MAX:-$FM_TASK_INBOX_URGENT_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_URGENT_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_ring_attempts() {
  local a=${FM_TASK_INBOX_RING_ATTEMPTS:-$FM_TASK_INBOX_RING_ATTEMPTS_DEFAULT}
  case "$a" in ''|0|*[!0-9]*) a=$FM_TASK_INBOX_RING_ATTEMPTS_DEFAULT ;; esac
  printf '%s' "$a"
}

# Seconds as accepted by sleep: digits with at most one decimal point.
fm_task_inbox_enter_pause() {
  local p=${FM_TASK_INBOX_ENTER_PAUSE:-$FM_TASK_INBOX_ENTER_PAUSE_DEFAULT}
  case "$p" in
    ''|.|*.*.*|*[!0-9.]*) p=$FM_TASK_INBOX_ENTER_PAUSE_DEFAULT ;;
  esac
  printf '%s' "$p"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list '%s'/*.msg and, in numeric order, read and act on each, then mv each handled file to '%s'/handled/." \
    "$quoted" "$quoted"
}

# The ONE doorbell, used by every delivery path: fm-send's local ring, the
# remote host-local steer leg, and the watcher's re-rings all call this, so a
# delivery fix lands everywhere at once. Sequence per call:
#   1. endpoint-liveness pre-check (dead or missing: nothing is typed);
#   2. advisory composer pre-check (proven pending text: skip, see below);
#   3. type the constant line once and submit it through the backend's
#      verifying submit machinery (one Enter);
#   4. respect that submit verdict: `empty` is the backend's proof that the
#      line left the composer (including its queued-busy conversion), so it is
#      a success with no further Enter; any other verdict pauses
#      FM_TASK_INBOX_ENTER_PAUSE seconds and sends one confirming Enter,
#      because TUI agents (Claude Code, Codex) measurably leave a single-Enter
#      submission in the composer, while an Enter on an empty composer is a
#      no-op;
#   5. a re-read `pending` or `pending-unproven` composer is retried on the next
#      attempt - never with a retyped line, and never abandoned just because
#      the pane reports busy - while any other composer verdict ends the
#      doorbell as delivered.
# Steps 3-5 repeat up to FM_TASK_INBOX_RING_ATTEMPTS times. A backend send
# failure before the line provably landed retypes on the next attempt after a
# pause and a fresh liveness check, because a transient Herdr socket error was
# the measured cause of "doorbell did not reach" on remote panes; the worst
# outcome of that retype is a duplicated CONSTANT line the worker recovers
# semantically.
# Returns 0 rang (verified, or unverifiable because the classifier cannot read
# the composer), 1 skipped because the composer PROVENLY holds pending text
# before anything was typed (the watcher re-rings later), 2 the backend send
# failed on every attempt, 3 skipped because the endpoint is positively dead
# or missing (nothing typed; recovery owns the record), 4 typed but the
# composer still holds pending text after every attempt. No return value is
# delivery proof; the acknowledgement move is the only delivery signal.
# The pre-check skip is deliberately narrow: only an exact `pending` verdict
# defers, because there our Enter could submit someone's real half-typed
# content. `pending-unproven` and `unknown` still ring - the worst outcome is a
# garbled CONSTANT line the worker recovers semantically, while skipping on
# ambiguous verdicts would starve a harness whose idle screen the classifier
# cannot positively identify (that classifier is advisory here by design).
# Once this call has typed the line, a pending composer is presumed to hold
# that line, exactly as every backend submit core presumes for its own text.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict
  local attempt=0 attempts pause typed=0 last=send-failed
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending) return 1 ;;
  esac
  attempts=$(fm_task_inbox_ring_attempts)
  pause=$(fm_task_inbox_enter_pause)
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1 ]; then
      sleep "$pause"
      case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
        dead|missing) return 3 ;;
      esac
    fi
    if [ "$typed" -eq 0 ]; then
      # Accepted residual race: terminal input and Enter are separate delivery
      # steps, so an agent exiting after the liveness check could leave a bare
      # shell only a suffix; the `: ` prefix protects complete lines only.
      verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 "$pause" 0.3 "$label" 2>/dev/null) \
        || verdict=send-failed
      if [ "$verdict" = send-failed ]; then
        # The line may sit unsubmitted if only the Enter failed; a proven
        # pending composer means it landed, so the next attempt only submits.
        cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
        [ "$cstate" != pending ] || typed=1
        last=send-failed
        continue
      fi
      typed=1
      # `empty` is the backend's proof that the line left the composer, so the
      # confirming Enter is unnecessary; anything else still needs one.
      [ "$verdict" != empty ] || return 0
    elif ! fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1; then
      last=send-failed
      continue
    fi
    sleep "$pause"
    fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || true
    sleep 0.3
    cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
    case "$cstate" in
      empty) return 0 ;;
      pending|pending-unproven) last=pending ;;
      *) return 0 ;;
    esac
  done
  [ "$last" != pending ] || return 4
  return 2
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# The unread-urgent tier decision for the current oldest record, or nothing
# when no urgent action is due. See the header for the policy.
_fm_task_inbox_urgent_due() {  # <inbox-dir> <record-path> <age>
  local dir=$1 oldest=$2 age=$3 base urgent max state rec_base count last now
  urgent=$(fm_task_inbox_urgent_secs)
  [ "$urgent" -gt 0 ] || return 0
  [ "$age" -ge "$urgent" ] || return 0
  base=${oldest##*/}
  count=0
  last=0
  state=$(cat "$dir/.urgent-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$state
EOF
  if [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$(cat "$dir/.urgent-escalated" 2>/dev/null || true)" != "$base" ] || return 0
  max=$(fm_task_inbox_urgent_max)
  if [ "$count" -ge "$max" ]; then
    printf 'urgent-escalate %s %s %s' "$oldest" "$count" "$age"
    return 0
  fi
  now=$(date +%s)
  [ "$((now - last))" -ge "$urgent" ] || return 0
  printf 'urgent-ring %s' "$oldest"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   urgent-ring <record-path> one unread-urgent re-ring is due, even on a
#                             busy pane
#   urgent-escalate <record-path> <count> <age-secs>
#                             urgent budget spent; surface as unread-urgent
# The urgent verbs take precedence while due, so a pane the idle ladder keeps
# waiting on as busy cannot hold a message past the urgent schedule.
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last age urgent_action
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.urgent-state" "$dir/.urgent-escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  age=$(fm_path_age "$oldest")
  if [ "$age" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  urgent_action=$(_fm_task_inbox_urgent_due "$dir" "$oldest" "$age")
  if [ -n "$urgent_action" ]; then
    printf '%s' "$urgent_action"
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  _fm_task_inbox_bump "$(fm_task_inbox_dir "$1" "$2")" .ring-state "${3##*/}"
}

# Advance the unread-urgent tier after an urgent re-ring attempt, with the
# same budget and failure contract as fm_task_inbox_record_ring.
fm_task_inbox_record_urgent_ring() {  # <state-dir> <task-id> <record-path>
  _fm_task_inbox_bump "$(fm_task_inbox_dir "$1" "$2")" .urgent-state "${3##*/}"
}

_fm_task_inbox_bump() {  # <inbox-dir> <state-file-name> <record-basename>
  local dir=$1 file=$2 base=$3 ladder rec_base count last
  count=0
  ladder=$(cat "$dir/$file" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/$file"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  _fm_task_inbox_mark "$(fm_task_inbox_dir "$1" "$2")" .escalated "${3##*/}"
}

# Mark the current oldest as surfaced unread-urgent, with the same
# wake-before-marker ordering as fm_task_inbox_record_escalated.
fm_task_inbox_record_urgent_escalated() {  # <state-dir> <task-id> <record-path>
  _fm_task_inbox_mark "$(fm_task_inbox_dir "$1" "$2")" .urgent-escalated "${3##*/}"
}

_fm_task_inbox_mark() {  # <inbox-dir> <marker-name> <record-basename>
  local dir=$1
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "$3" > "$dir/$2"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
