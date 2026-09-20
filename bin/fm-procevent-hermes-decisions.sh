#!/usr/bin/env bash
# fm-procevent-hermes-decisions.sh - built-in process-event adapter for the
# #decisions channel of a Hermes pilot profile.
#
# This adapter is the register's inbound half for one Discord channel. A captain
# answer written in that profile's #decisions channel is captured by the profile's
# own `decisions-register` plugin into one durable answer record; this adapter
# reads that record through the profile's own CLI and reports what the captain
# chose. What the answer MEANS is owned once by bin/fm-captain-hold.sh's
# keyed-answer intake, never here.
#
# Usage:
#   fm-procevent-hermes-decisions.sh arm [--dry-run] --profile <name> --profile-home <dir>
#   fm-procevent-hermes-decisions.sh source --profile <name> --profile-home <dir>
#   fm-procevent-hermes-decisions.sh classify <result-file>
#   fm-procevent-hermes-decisions.sh silent <result-file>
#   fm-procevent-hermes-decisions.sh terminal <result-file>
#   fm-procevent-hermes-decisions.sh answers <result-file>
#   fm-procevent-hermes-decisions.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-hermes-decisions.sh source-id
#
# `arm` binds this source BEFORE it registers it, as the process-event contract
# requires, so the source can never produce an answer that has nowhere to go. It
# refuses unless the profile's own `decisions-register` CLI answers, so a source
# that cannot capture is never registered.
#
# `source` runs one bounded read of the profile's durable answer records. It
# prints the oldest uncaptured keyed answer as one JSON object and exits 0, or
# prints nothing and exits with the profile CLI's no-result code (75), which the
# runner records as no-result and leaves the source armed.
#
# `answers` prints `<task-id>\t<answer>\t<label>` for the captured record, which
# is exactly the keyed line bin/fm-captain-hold.sh's one intake reads. It prints
# nothing for a keyless record: a channel never invents a key.
#
# `autohandle` acknowledges the captured answer in the profile's own store so it
# is not captured twice. It deliberately does NOT acknowledge the result to the
# runner, because recording the captain's answer is transcription while acting on
# it is firstmate's judgement, and the wake must still reach the handler.
#
# `classify` returns `answer`, `keyless`, or `malformed`; `silent` suppresses only
# a routine no-op (a keyless record) so it never becomes a wake; `terminal`
# always refuses, because this source is meant to stay armed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

SOURCE_ID="hermes-decisions"
NO_RESULT_EXIT=75
# The profile CLI is invoked by name so the adapter stays a thin reader of the
# profile's own contract; FM_HERMES_DECISIONS_BIN is the documented test seam and
# never changes what the adapter reports.
HERMES_BIN="${FM_HERMES_DECISIONS_BIN:-hermes}"

die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

read_result() {  # <result-file>
  local file=${1-}
  [ -n "$file" ] || die "a result file is required"
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  printf '%s\n' "$file"
}

# The profile CLI is the single owner of what was captured; this adapter parses
# nothing the profile does not hand it, and never reads the profile's state files.
profile_cli() {  # <profile-home> <profile> <argv...>
  local home=$1 profile=$2
  shift 2
  HERMES_HOME="$home" "$HERMES_BIN" --profile "$profile" decisions-register "$@"
}

result_field() {  # <result-file> <field>
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(data, dict) or data.get("schema") != "decisions-register.answer.v1":
    sys.exit(1)
value = data.get(field)
if value is None:
    sys.exit(0)
if not isinstance(value, str):
    sys.exit(1)
sys.stdout.write(value)
PY
}

cmd_classify() {  # <result-file>
  local file=${1-} key
  # An unreadable result is malformed, never a wake: the adapter fails closed.
  if [ -z "$file" ] || [ ! -f "$file" ] || [ -L "$file" ]; then printf 'malformed\n'; return 0; fi
  key=$(result_field "$file" key 2>/dev/null) || { printf 'malformed\n'; return 0; }
  if [ -n "$key" ]; then printf 'answer\n'; else printf 'keyless\n'; fi
}

cmd_silent() {  # <result-file>
  # Only a routine no-op is silent: a keyless record positively proves the
  # captain named no captain-held task, so there is nothing to announce. Every
  # other shape stays announced.
  [ "$(cmd_classify "${1-}")" = "keyless" ]
}

cmd_terminal() {  # <result-file>
  # The source is meant to stay armed for the life of the channel.
  return 1
}

cmd_answers() {  # <result-file>
  local file=${1-} key answer label
  [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || exit 0
  key=$(result_field "$file" key 2>/dev/null) || exit 0
  [ -n "$key" ] || exit 0
  answer=$(result_field "$file" answer 2>/dev/null) || exit 0
  [ -n "$answer" ] || exit 0
  label=$(result_field "$file" label 2>/dev/null) || label=""
  [ -n "$label" ] || label="#decisions"
  printf '%s\t%s\t%s\n' "$key" "$answer" "$label"
}

cmd_autohandle() {  # <source-id> <sequence> <result-file>
  local id=${1-} seq=${2-} file home profile message_id
  [ "$id" = "$SOURCE_ID" ] || die "not a $SOURCE_ID capture: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be numeric" ;; esac
  file=$(read_result "${3-}") || exit 1
  message_id=$(result_field "$file" message_id 2>/dev/null) || die "the captured answer carries no message id"
  [ -n "$message_id" ] || die "the captured answer carries no message id"
  home=""
  profile=""
  # The profile identity is read from this source's own live registration, so it
  # has exactly one owner and no second configuration file can drift from it.
  home=$(registration_arg --profile-home 2>/dev/null) || home=""
  profile=$(registration_arg --profile 2>/dev/null) || profile=""
  [ -n "$home" ] && [ -n "$profile" ] || die "the profile identity could not be resolved from the registration"
  profile_cli "$home" "$profile" consume "$message_id" >/dev/null \
    || die "the captured answer could not be acknowledged in the profile store"
  printf 'autohandled #decisions answer %s\n' "$message_id"
}

cmd_source() {  # <profile-home> <profile>
  # The profile CLI's own stdout is the captured result, so its diagnostics are
  # kept out of it: a genuine failure is reported as one bounded actionable line
  # (which the runner captures and retries), while the CLI's own no-result code
  # with empty output stays silent so the source keeps its armed contract.
  local home=$1 profile=$2 out err rc errfile
  errfile=$(mktemp)
  set +e
  out=$(profile_cli "$home" "$profile" next 2>"$errfile")
  rc=$?
  set -e
  err=$(cat "$errfile" 2>/dev/null || true)
  rm -f "$errfile"
  if [ "$rc" -eq 0 ]; then
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
    return 0
  fi
  if [ "$rc" -eq "$NO_RESULT_EXIT" ] && [ -z "$out" ]; then
    return "$NO_RESULT_EXIT"
  fi
  printf 'hermes #decisions source failed: %s\n' \
    "$(printf '%s\n%s' "$err" "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-300)"
  return 1
}

cmd_source_id() { printf '%s\n' "$SOURCE_ID"; }

procevent_state_dir() {
  # The runner exports the state root it bound, so the adapter resolves the live
  # registration the same way the runner does rather than guessing a second one.
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf '%s\n' "$FM_STATE_OVERRIDE"; return 0; fi
  printf '%s/state\n' "${FM_HOME:-$FM_ROOT}"
}

registration_arg() {  # <flag>
  # Read the live registration's argv for this source id, one argument per line.
  local want=${1-} file line found=0 state
  state=$(procevent_state_dir)
  file="$state/procevent/$SOURCE_ID.source"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line; do
    if [ "$found" -eq 1 ]; then printf '%s\n' "$line"; return 0; fi
    [ "$line" = "$want" ] && found=1
  done < <(sed -n '/^argv:$/,$p' "$file" | tail -n +2)
  return 1
}

cmd_arm() {  # [--dry-run] --profile <name> --profile-home <dir>
  local dry_run=0 profile="" home=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --profile) profile=${2-}; shift 2 ;;
      --profile-home) home=${2-}; shift 2 ;;
      *) die "unknown arm option: $1" ;;
    esac
  done
  [ -n "$profile" ] || die "arm requires --profile"
  [ -n "$home" ] || die "arm requires --profile-home"
  [ -d "$home" ] || die "no profile home at $home"
  local adapter="$SCRIPT_DIR/fm-procevent-hermes-decisions.sh"
  [ -x "$adapter" ] || die "the adapter is not executable: $adapter"
  local register_cmd=("$FM_ROOT/bin/fm-procevent.sh" register hermes-decisions "$SOURCE_ID" --
    "$adapter" source --profile "$profile" --profile-home "$home")
  if [ "$dry_run" -eq 1 ]; then
    printf 'Hermes #decisions process-event arm dry-run (no registration, no network).\n'
    printf 'source id: %s\n' "$SOURCE_ID"
    printf 'bind command:\n  %s/bin/fm-captain-hold.sh bind %s\n' "$FM_ROOT" "$SOURCE_ID"
    printf 'register command:\n  %s\n' "${register_cmd[*]}"
    return 0
  fi
  # The profile CLI must already answer, so a source that cannot capture is never
  # registered and a broken profile is loud at arm time rather than silent later.
  profile_cli "$home" "$profile" status >/dev/null 2>&1 \
    || die "the profile's decisions-register CLI does not answer; install the plugin first"
  # Bind BEFORE arming, as the process-event contract requires.
  "$FM_ROOT/bin/fm-captain-hold.sh" bind "$SOURCE_ID" >/dev/null \
    || die "the source could not be bound to the keyed-answer intake"
  "${register_cmd[@]}" \
    || die "the source could not be registered"
  printf 'bound: %s -> %s\n' "$SOURCE_ID" "$("$FM_ROOT/bin/fm-captain-hold.sh" binding "$SOURCE_ID" 2>/dev/null || true)"
  printf 'armed: %s (reconcile and retire through fm-procevent.sh)\n' "$SOURCE_ID"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  source)
    shift
    home=""; profile=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --profile) profile=${2-}; shift 2 ;;
        --profile-home) home=${2-}; shift 2 ;;
        *) die "unknown source option: $1" ;;
      esac
    done
    [ -n "$profile" ] || die "source requires --profile"
    [ -n "$home" ] || die "source requires --profile-home"
    cmd_source "$home" "$profile"
    ;;
  classify) shift; cmd_classify "$@" ;;
  silent) shift; cmd_silent "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  answers) shift; cmd_answers "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  source-id) cmd_source_id ;;
  -h|--help|"") usage ;;
  *) die "unknown command: $1" ;;
esac
