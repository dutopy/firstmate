#!/usr/bin/env bash
# Native reflex anomaly reporter.
#
# This is a bounded command surface, not a daemon or a second ledger. It records
# suspicion, report, review, and resolution as ordinary status events in
# state/<task>.status. Raw evidence is never persisted; only its SHA-256 digest
# is retained. The watcher and wake drain therefore remain the intake and
# presentation owners.
#
# Usage:
#   fm-reflex.sh intake <task> <instance> <cause> <evidence>
#   fm-reflex.sh report <task> <key>
#   fm-reflex.sh review <task> <key>
#   fm-reflex.sh resolve <task> <key> [note]
#   fm-reflex.sh list <task>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REFLEX_MAX_SCAN_BYTES=${REFLEX_MAX_SCAN_BYTES:-131072}
REFLEX_MAX_LIST_LINES=${REFLEX_MAX_LIST_LINES:-512}
REFLEX_LOCK_ATTEMPTS=${REFLEX_LOCK_ATTEMPTS:-50}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  exit 2
}

die() { printf 'fm-reflex: %s\n' "$*" >&2; exit 1; }

valid_id() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) [ "${#1}" -le 64 ] ;;
  esac
}

valid_field() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._:-]*) return 1 ;;
    *) [ "${#1}" -le 64 ] ;;
  esac
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    die 'no SHA-256 tool is available'
  fi
}

task_status() {
  local task=$1
  valid_id "$task" || die "invalid task id"
  printf '%s/%s.status' "$STATE" "$task"
}

key_digest() { sha256_text "$1" | cut -c1-24; }

# Print the latest lifecycle event for a key. The status log is append-only;
# resolution is the only event that closes an open reflex record.
latest_state() {  # <status-file> <key>
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  # Status files are append-only and may be long-lived. Inspect only the
  # bounded suffix; callers reject unknown keys rather than scanning history.
  tail -c "$REFLEX_MAX_SCAN_BYTES" "$file" 2>/dev/null | awk -v key="$key" '
    index($0, "[key=" key "]") {
      if ($0 ~ /^reflex-intake /) state="intake"
      else if ($0 ~ /^reflex-report /) state="report"
      else if ($0 ~ /^needs-decision /) state="review"
      else if ($0 ~ /^resolved /) state="resolved"
    }
    END { if (state != "") print state }
  ' 2>/dev/null || true
}

has_event() {  # <status-file> <key> <state>
  [ "$(latest_state "$1" "$2")" = "$3" ]
}

has_reflex_origin() {  # <status-file> <key>
  tail -c "$REFLEX_MAX_SCAN_BYTES" "$1" 2>/dev/null \
    | awk -v key="$2" 'index($0, "reflex-intake [key=" key "]") { found=1 } END { exit(found ? 0 : 1) }'
}

acquire_reflex_lock() {  # <status-file>
  local lock="$1.lock" attempts=0
  mkdir -p "$STATE"
  while ! fm_lock_try_acquire "$lock"; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt "$REFLEX_LOCK_ATTEMPTS" ] || return 1
    sleep 0.1
  done
}

append_status_locked() {  # <status-file> <line>
  printf '%s\n' "$2" >> "$1"
}

cmd_intake() {
  local task=$1 instance=$2 cause=$3 evidence=$4 file digest key line
  valid_id "$task" || die 'invalid task id'
  valid_field "$instance" || die 'invalid instance (use a privacy-safe identifier)'
  valid_field "$cause" || die 'invalid cause (use unknown when unconfirmed)'
  [ "${#evidence}" -le 4096 ] || die 'evidence exceeds 4096 bytes'
  file=$(task_status "$task")
  digest=$(sha256_text "$evidence")
  key="reflex-$(key_digest "$task|$instance|$cause|$digest")"
  acquire_reflex_lock "$file" || die 'could not acquire status lock within bounded wait'
  case "$(latest_state "$file" "$key")" in
    intake|report|review)
      fm_lock_release "$file.lock"
      printf 'already-intake\t%s\n' "$key"
      return 0
      ;;
  esac
  line="reflex-intake [key=$key] [instance=$instance] [cause=$cause] [evidence=sha256:$digest]: suspicion"
  append_status_locked "$file" "$line" || { fm_lock_release "$file.lock"; die 'could not append suspicion'; }
  fm_lock_release "$file.lock"
  printf 'intake\t%s\n' "$key"
}

cmd_report() {
  local task=$1 key=$2 file line
  valid_id "$task" || die 'invalid task id'
  valid_field "$key" || die 'invalid reflex key'
  file=$(task_status "$task")
  [ -f "$file" ] || die 'no suspicion exists for task'
  acquire_reflex_lock "$file" || die 'could not acquire status lock within bounded wait'
  case "$(latest_state "$file" "$key")" in
    report|review) fm_lock_release "$file.lock"; printf 'already-report\t%s\n' "$key"; return 0 ;;
    resolved) fm_lock_release "$file.lock"; die 'intake is already resolved' ;;
  esac
  has_event "$file" "$key" intake || { fm_lock_release "$file.lock"; die 'report requires an open intake event'; }
  line="reflex-report [key=$key]: bounded report; cause remains as recorded"
  append_status_locked "$file" "$line" || { fm_lock_release "$file.lock"; die 'could not append report'; }
  fm_lock_release "$file.lock"
  printf 'report\t%s\n' "$key"
}

cmd_review() {
  local task=$1 key=$2 file line
  valid_id "$task" || die 'invalid task id'
  valid_field "$key" || die 'invalid reflex key'
  file=$(task_status "$task")
  [ -f "$file" ] || die 'no report exists for task'
  acquire_reflex_lock "$file" || die 'could not acquire status lock within bounded wait'
  case "$(latest_state "$file" "$key")" in
    review) fm_lock_release "$file.lock"; printf 'already-review\t%s\n' "$key"; return 0 ;;
    resolved) fm_lock_release "$file.lock"; die 'report is already resolved' ;;
  esac
  has_event "$file" "$key" report || { fm_lock_release "$file.lock"; die 'review requires a report event'; }
  line="needs-decision [key=$key]: reflex review requested"
  append_status_locked "$file" "$line" || { fm_lock_release "$file.lock"; die 'could not append review trigger'; }
  fm_lock_release "$file.lock"
  printf 'review\t%s\n' "$key"
}

cmd_resolve() {
  local task=$1 key=$2 note=${3:-resolved} file line
  valid_id "$task" || die 'invalid task id'
  valid_field "$key" || die 'invalid reflex key'
  [ "${#note}" -le 256 ] || die 'resolution note exceeds 256 bytes'
  file=$(task_status "$task")
  [ -f "$file" ] || die 'no reflex exists for task'
  acquire_reflex_lock "$file" || die 'could not acquire status lock within bounded wait'
  has_reflex_origin "$file" "$key" || {
    fm_lock_release "$file.lock"
    die 'unknown reflex key (resolution requires an existing reflex lifecycle)'
  }
  state=$(latest_state "$file" "$key")
  case "$state" in
    intake|report|review) ;;
    resolved)
      fm_lock_release "$file.lock"
    printf 'already-resolved\t%s\n' "$key"
    return 0
      ;;
    *)
      fm_lock_release "$file.lock"
      die 'unknown reflex key (resolution requires an existing reflex lifecycle)'
      ;;
  esac
  line="resolved [key=$key]: $(printf '%s' "$note" | fm_wake_clean_field)"
  append_status_locked "$file" "$line" || { fm_lock_release "$file.lock"; die 'could not append resolution'; }
  fm_lock_release "$file.lock"
  printf 'resolved\t%s\n' "$key"
}

cmd_list() {
  local task=$1 file
  file=$(task_status "$task")
  [ -f "$file" ] || exit 0
  tail -n "$REFLEX_MAX_LIST_LINES" "$file" \
    | awk '/^(reflex-intake|reflex-report|needs-decision|resolved) / { print }'
}

case "${1:-}" in
  intake) [ "$#" -eq 5 ] || usage; cmd_intake "$2" "$3" "$4" "$5" ;;
  report) [ "$#" -eq 3 ] || usage; cmd_report "$2" "$3" ;;
  review) [ "$#" -eq 3 ] || usage; cmd_review "$2" "$3" ;;
  resolve) [ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage; cmd_resolve "$2" "$3" "${4:-resolved}" ;;
  list) [ "$#" -eq 2 ] || usage; cmd_list "$2" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
