#!/usr/bin/env bash
# fm-deferred-question.sh - opt-in "deferred answer" mode for Claude primary
# AskUserQuestion calls, plus the store that re-surfaces them.
#
# Why this exists: a Claude primary that calls AskUserQuestion blocks its turn
# until the captain answers. No Stop event fires while it waits, so the
# Stop-owned watcher re-arm (bin/fm-claude-stop-autoarm.sh) never runs and fleet
# supervision silently stops for as long as the captain is away.
# With the mode enabled, the PreToolUse hook records the question durably,
# optionally runs a notification command, and answers the tool call itself with
# a DEFERRED answer so the turn continues and ends normally. The
# UserPromptSubmit hook then re-surfaces every pending question at the next
# captain message. docs/deferred-questions.md owns the contract and its limits.
#
# Usage:
#   <PreToolUse JSON on stdin>       | bin/fm-deferred-question.sh pretool --claude
#   <UserPromptSubmit JSON on stdin> | bin/fm-deferred-question.sh prompt --claude
#   bin/fm-deferred-question.sh list
#   bin/fm-deferred-question.sh resolve <id>... | --all
#   bin/fm-deferred-question.sh --help
#
# Enablement (per home, off by default):
#   config/deferred-questions present -> enabled.
#   FM_DEFERRED_QUESTIONS overrides the file: 1/on/true/yes enables, any other
#   non-empty value disables, unset or empty defers to the file.
#   Each non-empty, non-# line of the file that reads `command:<cmd>` adds a
#   notification command, run detached via `sh -c` with a one-line summary as
#   $1 and the JSON record on stdin; its failure never affects the hook.
#
# State (captain-private, under the effective home's state directory):
#   state/deferred-questions/<id>.json            pending record
#   state/deferred-questions/resolved/<id>.json   resolved record
#
# pretool contract (Claude PreToolUse, matcher AskUserQuestion):
#   INERT - mode off, not AskUserQuestion, not a genuine primary home, missing
#           jq, malformed stdin, or a store write failure: exit 0, no output,
#           so Claude Code shows its ordinary blocking question.
#   DEFER - otherwise: write or reuse the record, start notifications, and
#           print an allow decision whose updatedInput echoes the questions
#           with a DEFERRED answer for each, plus additionalContext.
#           A call whose question texts match an existing pending record
#           reuses that record instead of writing a second one.
#           The call is never left to the ordinary blocking prompt while the
#           mode is on: that reopens the gap this mode exists to close.
#
# prompt contract (Claude UserPromptSubmit):
#   Runs whether or not the mode is enabled, so records left from an enabled
#   period are never stranded. Firstmate operational inputs (prompts starting
#   with U+2063) are not captain messages and are skipped. Any other prompt
#   with pending records prints additionalContext listing them and marks them
#   re-surfaced. That prompt is not proof the captain has returned. The context
#   tells the primary to restate the question in plain chat and to run resolve
#   only after the captain answers there. Otherwise exit 0 with no output.
#   Every failure is silent.
#
# Bash 3.2 compatible.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG_FILE=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/deferred-questions
STORE="$STATE/deferred-questions"
RESOLVED="$STORE/resolved"

DEFERRED_ANSWER='DEFERRED: the captain has not answered yet. Do not treat this as a choice. Continue supervision, restate the question in plain chat, and run bin/fm-deferred-question.sh resolve once the captain answers.'

usage() {
  sed -n '2,/^# Bash 3.2 compatible\./{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
}

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

deferred_enabled() {
  local v=${FM_DEFERRED_QUESTIONS:-}
  if [ -n "$v" ]; then
    case "$v" in
      1|on|true|yes|ON|TRUE|YES|On|True|Yes) return 0 ;;
      *) return 1 ;;
    esac
  fi
  [ -f "$CONFIG_FILE" ]
}

in_primary_scope() {
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || return 1
  fm_primary_scope_matches "$FM_ROOT" "$STATE"
}

pending_files() {
  local f
  [ -d "$STORE" ] || return 0
  for f in "$STORE"/*.json; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# Print the pending record whose question texts match <questions-json>, if any.
# Identical calls before any captain message must share one record.
find_duplicate_record() {  # <questions-json>
  local sig cand
  sig=$(printf '%s' "$1" | jq -c 'map(.question // "") | sort' 2>/dev/null) || return 1
  [ -n "$sig" ] || return 1
  while IFS= read -r cand; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    if jq -e --argjson sig "$sig" '([.questions[]?.question // ""] | sort) == $sig' "$cand" >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done <<EOF
$(pending_files)
EOF
  return 1
}

# Atomically replace <file> with stdin; empty input never replaces a record.
write_atomic() {  # <file>
  local file=$1 tmp
  tmp="$file.tmp.$$"
  cat > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

resolve_file() {  # <pending-file> <how>
  local f=$1 how=$2 base
  base=$(basename "$f")
  mkdir -p "$RESOLVED" 2>/dev/null || return 1
  jq --arg how "$how" --arg at "$(now_iso)" '.resolved_at = $at | .resolved_by = $how' "$f" 2>/dev/null \
    | write_atomic "$RESOLVED/$base" || return 1
  rm -f "$f"
}

run_notifications() {  # <record-file> <summary>
  local record=$1 summary=$2 line cmd
  [ -f "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      command:*) cmd=${line#command:} ;;
      *) continue ;;
    esac
    [ -n "$cmd" ] || continue
    # Detached and fully redirected so the hook never waits on it and Claude
    # Code's stdout pipe is never held open by the notifier.
    nohup sh -c "$cmd" sh "$summary" < "$record" > /dev/null 2>&1 &
  done < "$CONFIG_FILE"
  return 0
}

cmd_pretool() {
  local payload tool qjson id tuid sid epoch record summary dup answers texts ctx out
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
  [ "$tool" = AskUserQuestion ] || exit 0
  deferred_enabled || exit 0
  in_primary_scope || exit 0
  qjson=$(printf '%s' "$payload" | jq -c '.tool_input.questions | select(type == "array" and length > 0)' 2>/dev/null) || exit 0
  [ -n "$qjson" ] || exit 0

  mkdir -p "$STORE" 2>/dev/null || exit 0

  record=""
  trap 'if [ -n "$record" ]; then rm -f "$record"; fi' EXIT
  trap 'exit 0' HUP INT TERM PIPE
  dup=$(find_duplicate_record "$qjson") || dup=""
  if [ -n "$dup" ]; then
    id=$(basename "$dup" .json)
  else
    epoch=$(now_epoch)
    tuid=$(printf '%s' "$payload" | jq -r '.tool_use_id // empty' 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9_-' | cut -c1-40)
    [ -n "$tuid" ] || tuid="pid$$"
    sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
    id="$(date -u +%Y%m%dT%H%M%SZ)-$tuid"
    # A repeated tool_use_id in the same second must never overwrite a record.
    [ ! -e "$STORE/$id.json" ] || id="$id-$$"
    record="$STORE/$id.json"
    jq -n --arg id "$id" --arg at "$(now_iso)" --argjson epoch "$epoch" \
      --arg sid "$sid" --arg tuid "$tuid" --argjson q "$qjson" \
      '{id: $id, recorded_at: $at, recorded_epoch: $epoch, session_id: $sid,
        tool_use_id: $tuid, questions: $q, surfaced_at: null, surfaced_count: 0}' 2>/dev/null \
      | write_atomic "$record" || exit 0
    [ -s "$record" ] || exit 0

    summary=$(printf '%s' "$qjson" | jq -r '.[0].question // "question"' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' | cut -c1-180)
    run_notifications "$record" "Firstmate deferred a question for the captain: $summary"
  fi

  # If the allow decision cannot be emitted, the record must not outlive the
  # call: a pending record plus a blocking prompt would double-report it.
  answers=$(printf '%s' "$qjson" | jq -c --arg a "$DEFERRED_ANSWER" 'map({key: (.question // ""), value: $a}) | from_entries' 2>/dev/null) \
    || exit 0
  texts=$(printf '%s' "$qjson" | jq -r '.[] | "- " + (.question // "")' 2>/dev/null) \
    || exit 0
  ctx="[deferred-question] Deferred answer mode is on for this home, so the captain did not see a blocking prompt and has NOT answered. Record $id holds:
$texts
Do not act on any option as if chosen. Keep supervising, restate the question in plain chat, and when the captain answers in plain chat, run bin/fm-deferred-question.sh resolve $id."
  out=$(jq -n --argjson payload "$payload" --argjson answers "$answers" --arg reason "deferred question $id" --arg ctx "$ctx" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
      permissionDecisionReason: $reason,
      updatedInput: ($payload.tool_input + {answers: $answers}),
      additionalContext: $ctx}}' 2>/dev/null) \
    || exit 0
  printf '%s\n' "$out" || exit 0
  record=""
  exit 0
}

cmd_prompt() {
  local payload prompt pending f lines ctx at count
  payload=$(cat 2>/dev/null || true)
  pending=$(pending_files)
  [ -n "$pending" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  in_primary_scope || exit 0
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null) || prompt=""
  # Operational inputs (session start, watcher, away supervisor, launch brief)
  # all begin with U+2063; none of them is the captain writing.
  case "$prompt" in
    $'\xE2\x81\xA3'*) exit 0 ;;
  esac
  lines=""
  count=0
  at=$(now_iso)
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    lines="$lines$(jq -r '"- " + .id + " (asked " + .recorded_at + "): " + ([.questions[]?.question] | join(" | "))' "$f" 2>/dev/null)
"
    jq --arg at "$at" '.surfaced_at = $at | .surfaced_count = ((.surfaced_count // 0) + 1)' "$f" 2>/dev/null \
      | write_atomic "$f"
    count=$((count + 1))
  done <<EOF
$pending
EOF
  [ "$count" -gt 0 ] || exit 0
  ctx="[deferred-question] $count question(s) were deferred while the captain was away and are still unanswered:
${lines}This prompt is not proof the captain has returned. Restate each question in plain chat. Run bin/fm-deferred-question.sh resolve <id> only after the captain answers in plain chat. Do not call AskUserQuestion for a deferred question."
  jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}' 2>/dev/null
  exit 0
}

cmd_list() {
  local pending f
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
  pending=$(pending_files)
  if [ -z "$pending" ]; then
    echo "no pending deferred questions"
    exit 0
  fi
  while IFS= read -r f; do
    jq -r '.id + "\tasked " + .recorded_at + "\tresurfaced " + ((.surfaced_count // 0) | tostring) + "x\n" + ([.questions[]? | "  - " + (.question // "")] | join("\n"))' "$f" 2>/dev/null
  done <<EOF
$pending
EOF
}

cmd_resolve() {
  local id f rc=0
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
  [ "$#" -gt 0 ] || { echo "error: resolve needs <id>... or --all" >&2; exit 2; }
  if [ "$1" = --all ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if resolve_file "$f" manual; then
        echo "resolved $(basename "$f" .json)"
      else
        echo "error: could not resolve $(basename "$f" .json)" >&2
        rc=1
      fi
    done <<EOF
$(pending_files)
EOF
    exit "$rc"
  fi
  for id in "$@"; do
    case "$id" in
      */*|.*|'') echo "error: invalid id: $id" >&2; rc=2; continue ;;
    esac
    f="$STORE/$id.json"
    if [ ! -f "$f" ]; then
      echo "error: no pending deferred question: $id" >&2
      rc=1
      continue
    fi
    if resolve_file "$f" manual; then
      echo "resolved $id"
    else
      echo "error: could not resolve $id" >&2
      rc=1
    fi
  done
  exit "$rc"
}

case "${1:-}" in
  pretool) shift; [ "${1:-}" != --claude ] || shift; cmd_pretool ;;
  prompt) shift; [ "${1:-}" != --claude ] || shift; cmd_prompt ;;
  list) shift; cmd_list ;;
  resolve) shift; cmd_resolve "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
