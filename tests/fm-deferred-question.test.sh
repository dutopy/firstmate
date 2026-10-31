#!/usr/bin/env bash
# Behavior tests for the opt-in deferred-answer mode for Claude primary
# AskUserQuestion calls (bin/fm-deferred-question.sh): default-off inertness,
# the PreToolUse deferred allow shape, durable records, notification commands,
# UserPromptSubmit re-surfacing, identical-call reuse, list/resolve, scope, and
# the tracked .claude/settings.json registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DQ="$ROOT/bin/fm-deferred-question.sh"
TMP_ROOT=$(fm_test_tmproot fm-deferred-question-tests)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

ASK='{"session_id":"s1","tool_name":"AskUserQuestion","tool_use_id":"toolu_01AB/../x","tool_input":{"questions":[{"question":"Merge PR 12?","header":"Merge","options":[{"label":"Yes","description":"y"},{"label":"No","description":"n"}],"multiSelect":false}]}}'
ASK2='{"session_id":"s1","tool_name":"AskUserQuestion","tool_use_id":"toolu_02CD","tool_input":{"questions":[{"question":"Release now?","header":"Release","options":[{"label":"Yes","description":"y"},{"label":"Later","description":"l"}],"multiSelect":false}]}}'
ASK_BOTH='{"session_id":"s1","tool_name":"AskUserQuestion","tool_use_id":"toolu_03EF/../y","tool_input":{"questions":[{"question":"Merge PR 12?","header":"Merge","options":[{"label":"Yes","description":"y"},{"label":"No","description":"n"}],"multiSelect":false},{"question":"Release now?","header":"Release","options":[{"label":"Yes","description":"y"},{"label":"Later","description":"l"}],"multiSelect":false}]}}'

new_home() {  # <name> -> prints home path
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/bin" "$h/state" "$h/config"
  printf '# fixture\n' > "$h/AGENTS.md"
  git -C "$h" init -q
  printf '%s\n' "$h"
}

run_dq() {  # <home> <stdin> <args...>
  local h=$1 input=$2 rc=0
  shift 2
  : > "$OUT"; : > "$ERR"
  printf '%s' "$input" | env -u FM_DEFERRED_QUESTIONS FM_ROOT_OVERRIDE="$h" FM_HOME="$h" \
    "$DQ" "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

pending_count() { find "$1/state/deferred-questions" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
resolved_count() { find "$1/state/deferred-questions/resolved" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

test_default_off_is_inert() {
  local h
  h=$(new_home off)
  run_dq "$h" "$ASK" pretool --claude || fail "default-off pretool must exit 0"
  [ ! -s "$OUT" ] || fail "default-off pretool wrote stdout: $(cat "$OUT")"
  [ ! -d "$h/state/deferred-questions" ] || fail "default-off pretool created the store"
  : > "$OUT"
  printf '%s' "$ASK" | env FM_DEFERRED_QUESTIONS=off FM_ROOT_OVERRIDE="$h" FM_HOME="$h" "$DQ" pretool --claude > "$OUT" 2>&1
  touch "$h/config/deferred-questions"
  printf '%s' "$ASK" | env FM_DEFERRED_QUESTIONS=off FM_ROOT_OVERRIDE="$h" FM_HOME="$h" "$DQ" pretool --claude > "$OUT" 2>&1
  [ ! -s "$OUT" ] || fail "FM_DEFERRED_QUESTIONS=off must override a present flag: $(cat "$OUT")"
  run_dq "$h" '' prompt --claude || fail "prompt with no records must exit 0"
  [ ! -s "$OUT" ] || fail "prompt with no records wrote stdout"
  pass "mode is off by default, the env override disables a present flag, and no records means silence"
}

test_env_override_enables_without_flag() {
  local h
  h=$(new_home envon)
  : > "$OUT"
  printf '%s' "$ASK" | env FM_DEFERRED_QUESTIONS=1 FM_ROOT_OVERRIDE="$h" FM_HOME="$h" "$DQ" pretool --claude > "$OUT" 2> "$ERR"
  jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUT" >/dev/null \
    || fail "FM_DEFERRED_QUESTIONS=1 must enable deferral: $(cat "$OUT")"
  pass "FM_DEFERRED_QUESTIONS=1 enables the mode without the config flag"
}

test_defer_shape_and_record() {
  local h rec
  h=$(new_home defer)
  touch "$h/config/deferred-questions"
  run_dq "$h" "$ASK" pretool --claude || fail "deferral must exit 0, got: $(cat "$ERR")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "allow"' "$OUT" >/dev/null \
    || fail "deferral must be a PreToolUse allow: $(cat "$OUT")"
  jq -e --argjson in "$ASK" '.hookSpecificOutput.updatedInput.questions == $in.tool_input.questions' "$OUT" >/dev/null \
    || fail "updatedInput must echo the original questions unchanged"
  jq -e '.hookSpecificOutput.updatedInput.answers["Merge PR 12?"] | startswith("DEFERRED:")' "$OUT" >/dev/null \
    || fail "every question must carry a DEFERRED answer: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.additionalContext | contains("has NOT answered") and contains("fm-deferred-question.sh resolve")' "$OUT" >/dev/null \
    || fail "additionalContext must say the captain has not answered and name resolve"
  [ "$(pending_count "$h")" -eq 1 ] || fail "deferral must write exactly one pending record"
  rec=$(find "$h/state/deferred-questions" -maxdepth 1 -name '*.json')
  case "$(basename "$rec")" in
    *..*|*/*) fail "record id must be sanitized: $rec" ;;
  esac
  jq -e '.questions[0].question == "Merge PR 12?" and .surfaced_at == null and .session_id == "s1"' "$rec" >/dev/null \
    || fail "record must hold the questions and start un-surfaced: $(cat "$rec")"
  find "$h/state/deferred-questions" -name '*.tmp.*' | grep -q . && fail "atomic write left a temp file"
  pass "deferral allows with echoed questions plus DEFERRED answers, adds context, and writes one sanitized record"
}

test_failed_delivery_rolls_back_only_new_records() {
  local h mode rc
  for mode in closed pipe; do
    h=$(new_home "delivery-$mode")
    touch "$h/config/deferred-questions"
    rc=0
    if [ "$mode" = closed ]; then
      printf '%s' "$ASK" | env -u FM_DEFERRED_QUESTIONS FM_ROOT_OVERRIDE="$h" FM_HOME="$h" \
        "$DQ" pretool --claude >&- 2> "$ERR"
      rc=${PIPESTATUS[1]}
    else
      printf '%s' "$ASK" | env -u FM_DEFERRED_QUESTIONS FM_ROOT_OVERRIDE="$h" FM_HOME="$h" \
        "$DQ" pretool --claude 2> "$ERR" | :
      rc=${PIPESTATUS[1]}
    fi
    [ "$rc" -eq 0 ] || fail "$mode stdout failure must exit 0, got $rc"
    [ "$(pending_count "$h")" -eq 0 ] || fail "$mode stdout failure left a new pending record"
    run_dq "$h" "$ASK" pretool --claude || fail "seed deferral failed"
    cp "$h"/state/deferred-questions/*.json "$TMP_ROOT/saved-record.json"
    if [ "$mode" = closed ]; then
      printf '%s' "$ASK" | env -u FM_DEFERRED_QUESTIONS FM_ROOT_OVERRIDE="$h" FM_HOME="$h" \
        "$DQ" pretool --claude >&- 2> "$ERR"
      rc=${PIPESTATUS[1]}
    else
      printf '%s' "$ASK" | env -u FM_DEFERRED_QUESTIONS FM_ROOT_OVERRIDE="$h" FM_HOME="$h" \
        "$DQ" pretool --claude 2> "$ERR" | :
      rc=${PIPESTATUS[1]}
    fi
    [ "$rc" -eq 0 ] || fail "$mode stdout failure on reuse must exit 0, got $rc"
    [ "$(pending_count "$h")" -eq 1 ] || fail "$mode stdout failure removed a reused record"
    cmp -s "$TMP_ROOT/saved-record.json" "$h"/state/deferred-questions/*.json \
      || fail "$mode stdout failure changed a reused record"
  done
  pass "failed delivery exits 0, rolls back new records, and preserves reused records"
}

test_other_tools_and_bad_input_are_inert() {
  local h
  h=$(new_home inert)
  touch "$h/config/deferred-questions"
  run_dq "$h" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' pretool --claude || fail "non-AskUserQuestion must exit 0"
  [ ! -s "$OUT" ] || fail "non-AskUserQuestion wrote stdout"
  run_dq "$h" 'not json' pretool --claude || fail "malformed stdin must exit 0"
  [ ! -s "$OUT" ] || fail "malformed stdin wrote stdout"
  run_dq "$h" '{"tool_name":"AskUserQuestion","tool_input":{}}' pretool --claude || fail "empty questions must exit 0"
  [ ! -s "$OUT" ] || fail "empty questions wrote stdout"
  [ "$(pending_count "$h")" -eq 0 ] || fail "inert paths must not write records"
  pass "other tools, malformed stdin, and empty questions leave the ordinary prompt untouched"
}

test_task_worktree_is_inert() {
  local h wt
  h=$(new_home scope)
  fm_git_identity
  git -C "$h" commit -q --allow-empty -m init
  wt="$TMP_ROOT/scope-wt"
  git -C "$h" worktree add -q "$wt" 2>/dev/null || fail "could not create a linked worktree fixture"
  mkdir -p "$wt/bin" "$wt/state" "$wt/config"
  printf '# fixture\n' > "$wt/AGENTS.md"
  touch "$wt/config/deferred-questions"
  run_dq "$wt" "$ASK" pretool --claude || fail "task worktree pretool must exit 0"
  [ ! -s "$OUT" ] || fail "a linked task worktree must stay inert: $(cat "$OUT")"
  pass "a linked task worktree (crewmate shape) stays inert even with the flag present"
}

test_notification_command_runs_detached() {
  local h i
  h=$(new_home notify)
  {
    printf '# comment line\n'
    # shellcheck disable=SC2016 # $1 must reach the notifier unexpanded.
    printf 'command:cat > %q; printf %%s "$1" > %q\n' "$TMP_ROOT/notify.json" "$TMP_ROOT/notify.txt"
    printf 'command:exit 7\n'
  } > "$h/config/deferred-questions"
  run_dq "$h" "$ASK" pretool --claude || fail "pretool with notifier must exit 0"
  jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUT" >/dev/null || fail "a failing notifier must not affect the decision"
  i=0
  while [ ! -s "$TMP_ROOT/notify.txt" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q 'Merge PR 12?' "$TMP_ROOT/notify.txt" || fail "notifier must receive the summary as \$1"
  i=0
  while ! jq -e '.questions[0].question == "Merge PR 12?"' "$TMP_ROOT/notify.json" >/dev/null 2>&1 && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  jq -e '.questions[0].question == "Merge PR 12?"' "$TMP_ROOT/notify.json" >/dev/null || fail "notifier must receive the record on stdin"
  pass "each command: line runs with the summary on \$1 and the record on stdin, and a failing one is harmless"
}

test_prompt_resurfaces_and_skips_operational_input() {
  local h op
  h=$(new_home prompt)
  touch "$h/config/deferred-questions"
  run_dq "$h" "$ASK" pretool --claude || fail "seed deferral failed"
  op=$(printf '\342\201\243FIRSTMATE_OP: v1 watcher: wake')
  run_dq "$h" "$(jq -nc --arg p "$op" '{prompt: $p}')" prompt --claude || fail "operational prompt must exit 0"
  [ ! -s "$OUT" ] || fail "an operational input must not re-surface questions: $(cat "$OUT")"
  jq -e '.surfaced_at == null' "$h"/state/deferred-questions/*.json >/dev/null || fail "an operational input must not mark records surfaced"
  run_dq "$h" '{"prompt":"back now"}' prompt --claude || fail "captain prompt must exit 0"
  jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | contains("Merge PR 12?"))' "$OUT" >/dev/null \
    || fail "a captain prompt must re-surface the pending question: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.additionalContext | contains("not proof the captain has returned") and contains("plain chat") and contains("fm-deferred-question.sh resolve") and (contains("live prompt") | not)' "$OUT" >/dev/null \
    || fail "re-surface context must restate in plain chat and must not send the question live: $(cat "$OUT")"
  jq -e '.surfaced_at != null and .surfaced_count == 1' "$h"/state/deferred-questions/*.json >/dev/null || fail "re-surfacing must mark the record"
  rm -f "$h/config/deferred-questions"
  run_dq "$h" '{"prompt":"again"}' prompt --claude || fail "second captain prompt must exit 0"
  jq -e '.hookSpecificOutput.additionalContext | contains("Merge PR 12?")' "$OUT" >/dev/null \
    || fail "pending records must still re-surface after the mode is turned off"
  jq -e '.surfaced_count == 2' "$h"/state/deferred-questions/*.json >/dev/null || fail "surfaced_count must increase per captain prompt"
  pass "captain prompts re-surface pending questions (even after opt-out) while operational inputs never do"
}

test_plain_prompt_never_reopens_blocking_prompt() {
  local h
  h=$(new_home plain)
  touch "$h/config/deferred-questions"
  run_dq "$h" "$ASK" pretool --claude || fail "seed deferral failed"
  run_dq "$h" "$ASK" pretool --claude || fail "identical call before any prompt must exit 0"
  jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUT" >/dev/null \
    || fail "an identical call before any prompt must still defer: $(cat "$OUT")"
  [ "$(pending_count "$h")" -eq 1 ] || fail "an identical call before any prompt must reuse the pending record"
  run_dq "$h" '{"prompt":"scheduled task: nightly report"}' prompt --claude || fail "unprefixed prompt failed"
  run_dq "$h" "$ASK" pretool --claude || fail "pretool after an unprefixed prompt must exit 0"
  jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUT" >/dev/null \
    || fail "an unprefixed prompt must not hand the next call to the blocking prompt: $(cat "$OUT")"
  [ -s "$OUT" ] || fail "an unprefixed prompt must not empty the next pretool stdout"
  [ "$(pending_count "$h")" -eq 1 ] || fail "an identical call must reuse the pending record"
  [ "$(resolved_count "$h")" -eq 0 ] || fail "a repeated call must never resolve a record"
  pass "a plain captain prompt never reopens the blocking prompt and an identical call reuses its record"
}

test_partial_reask_leaves_other_questions_pending() {
  local h
  h=$(new_home partial)
  touch "$h/config/deferred-questions"
  run_dq "$h" "$ASK_BOTH" pretool --claude || fail "seed multi-question deferral failed"
  run_dq "$h" '{"prompt":"here"}' prompt --claude || fail "captain prompt failed"
  run_dq "$h" "$ASK" pretool --claude || fail "partial re-ask must exit 0"
  jq -e '.hookSpecificOutput.permissionDecision == "allow"' "$OUT" >/dev/null \
    || fail "a partial re-ask must still defer: $(cat "$OUT")"
  [ "$(resolved_count "$h")" -eq 0 ] || fail "a partial re-ask must not resolve any record"
  grep -l 'Release now?' "$h"/state/deferred-questions/*.json >/dev/null \
    || fail "the question that was not re-asked must stay pending"
  pass "a re-ask of one question never resolves the record holding another"
}

test_resolve_all_propagates_failure() {
  local h rc=0
  h=$(new_home resolvefail)
  touch "$h/config/deferred-questions"
  run_dq "$h" "$ASK" pretool --claude || fail "seed deferral failed"
  : > "$h/state/deferred-questions/resolved"
  run_dq "$h" '' resolve --all || rc=$?
  [ "$rc" -ne 0 ] || fail "resolve --all must exit non-zero when the write fails"
  grep -q 'error:' "$ERR" || fail "resolve --all must report the write failure: $(cat "$ERR")"
  [ "$(pending_count "$h")" -eq 1 ] || fail "a failed resolve --all must leave the record pending"
  pass "resolve --all reports a failed write instead of exiting 0"
}

test_list_and_resolve() {
  local h id rc=0
  h=$(new_home resolve)
  touch "$h/config/deferred-questions"
  run_dq "$h" "$ASK" pretool --claude || fail "seed 1 failed"
  run_dq "$h" "$ASK2" pretool --claude || fail "seed 2 failed"
  run_dq "$h" '' list || fail "list must exit 0"
  grep -q 'Merge PR 12?' "$OUT" || fail "list must show the first question: $(cat "$OUT")"
  grep -q 'Release now?' "$OUT" || fail "list must show the second question: $(cat "$OUT")"
  id=$(basename "$(grep -l 'Merge PR 12?' "$h"/state/deferred-questions/*.json)" .json)
  run_dq "$h" '' resolve "$id" || fail "resolve must exit 0: $(cat "$ERR")"
  [ "$(pending_count "$h")" -eq 1 ] || fail "resolve must leave exactly one pending record"
  [ "$(resolved_count "$h")" -eq 1 ] || fail "resolve must move exactly one record"
  run_dq "$h" '' resolve "$id" || rc=$?
  [ "$rc" -eq 1 ] || fail "resolving a missing id must exit 1, got $rc"
  rc=0; run_dq "$h" '' resolve ../x || rc=$?
  [ "$rc" -eq 2 ] || fail "a path-shaped id must be refused with exit 2, got $rc"
  run_dq "$h" '' resolve --all || fail "resolve --all must exit 0"
  [ "$(pending_count "$h")" -eq 0 ] || fail "resolve --all must clear pending records"
  run_dq "$h" '' list || fail "empty list must exit 0"
  grep -q 'no pending' "$OUT" || fail "empty list must say so"
  pass "list shows pending questions and resolve moves them by id or --all, refusing bad ids"
}

test_tracked_settings_registration() {
  local s="$ROOT/.claude/settings.json"
  jq -e '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[] | select(.command | contains("fm-deferred-question.sh pretool --claude"))' "$s" >/dev/null \
    || fail "tracked settings must register the AskUserQuestion PreToolUse hook"
  jq -e '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-deferred-question.sh prompt --claude"))' "$s" >/dev/null \
    || fail "tracked settings must register the UserPromptSubmit re-surface hook"
  pass "tracked .claude/settings.json registers both deferred-question hooks"
}

test_default_off_is_inert
test_env_override_enables_without_flag
test_defer_shape_and_record
test_failed_delivery_rolls_back_only_new_records
test_other_tools_and_bad_input_are_inert
test_task_worktree_is_inert
test_notification_command_runs_detached
test_prompt_resurfaces_and_skips_operational_input
test_plain_prompt_never_reopens_blocking_prompt
test_partial_reask_leaves_other_questions_pending
test_resolve_all_propagates_failure
test_list_and_resolve
test_tracked_settings_registration
