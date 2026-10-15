#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# Both a merge performed by this home and a merge detected by its existing poll
# use this operation, so neither outcome depends on an agent remembering it.
# This operation publishes the poll's local actionable row; the watcher
# immediately delivers that row as observation handling, not a second outcome
# path.
#
# The destination is the home's role, never the caller's choice:
#   - a secondmate home reports upward on its parent channel, resolved and
#     appended through bin/fm-parent-channel-lib.sh in the same
#     "<state> [key=<slug>]: <note>" shape the charter contract defines;
#   - a main home reports to the captain through the durable wake queue.
# A poll observed in a secondmate home also receives a local durable wake after
# the upward write, so the mate can handle its own poll observation.
# No new state file and no new transport are involved.
#
# Normal operation deduplicates the task's latest canonical PR identity through
# the merge-notification marker owned by bin/fm-pr-lib.sh. Main-home wake keys
# also include that PR identity so distinct PRs for a reused task remain
# distinct in queue presentation. The outcome is published before the marker
# is committed, so a failed commit stays eligible for at-least-once retry and
# may rarely duplicate rather than leave a merge silent.
# Explicit automatic attempts additionally write data/auto-merge-journal.tsv:
# URL, bound PR head, measured lines, measured files, forge merged_at UTC, tab-
# separated without a header. Only accepted v2 authority evidence qualifies;
# attended/external outcomes never create a row. A fresh forge read must prove
# merged=true at that exact head. The journal is atomically replaced under its
# home-wide lock before the notification marker; poll recovery uses this same
# writer and rejects conflicting receipts instead of duplicating a row.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-merge-authority-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-merge-authority-lib.sh"

fm_merge_outcome_journal() {  # <home> <state> <id> <url> <provider> <host> <path> <number>
  local home=$1 state=$2 id=$3 url=$4 provider=$5 host=$6 path=$7 number=$8
  local record="$state/$id.merge-authority" version='' proof encoded live row
  local data="$home/data" journal lock device tmp='' status=0
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  IFS= read -r version < "$record" || return 1
  [ "$version" = fm-merge-authority-v2 ] || return 0
  fm_merge_authority_read "$state" "$id" "$provider" "$host" "$path" "$number" || return 1
  proof=$FM_MERGE_AUTHORITY_AUTOMATIC
  [ -n "$proof" ] || return 1
  encoded=$(gh-axi api GET "/repos/$path/pulls/$number" --full \
    --jq '. | tojson | @base64 | @json') || return 1
  live=$(fm_pr_base64_decode "$encoded") || return 1
  row=$(printf '%s\n' "$live" | jq -er --argjson proof "$proof" --arg url "$url" '
    select(.merged == true and .head.sha == $proof.head and $proof.url == $url)
    | select(.merged_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    | [$url, $proof.head, $proof.lines, $proof.files, .merged_at] | @tsv
    ') || return 1
  [ -d "$data" ] && [ ! -L "$data" ] || return 1
  device=$(fm_pr_file_device "$data") || return 1
  journal="$data/auto-merge-journal.tsv"
  lock="$data/.auto-merge-journal.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_pr_regular_destination_on_device_or_absent "$journal" "$device"; then
    status=1
  elif [ -f "$journal" ] && grep -qxF "$row" "$journal"; then
    fm_lock_release "$lock"
    return 0
  elif [ -f "$journal" ] && awk -F '\t' -v url="$url" '$1 == url {found=1} END {exit !found}' "$journal"; then
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    tmp=$(mktemp "$data/.auto-merge-journal.XXXXXX") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    if [ -f "$journal" ]; then cat "$journal" > "$tmp" || status=1; fi
    printf '%s\n' "$row" >> "$tmp" && chmod 0600 "$tmp" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_regular_destination_on_device_or_absent "$journal" "$device" \
      && mv -f -- "$tmp" "$journal" || status=1
  fi
  [ -z "$tmp" ] || [ ! -f "$tmp" ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || status=1
  return "$status"
}

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> says who observed the merge, because that decides whether the
# existing poll path also needs a local wake:
#   self - this home performed the merge.
#   poll - this home's merge poll detected the merge, so the canonical outcome
#          also wakes this home after any upward hop needed by a secondmate.
# Optional <authority> is yolo, away-grant, attended, or external. Yolo,
# away-grant, and external are appended to the ledger line; attended remains
# untagged. The merge entrypoint supplies its authority after forge acceptance,
# while the poll supplies the persisted identity-bound value or external when
# no matching record proves that this home authorized the merge.
#
# Returns 0 when the outcome is recorded (or already was), 2 on an invalid
# request, 3 when this home's own role or parent binding cannot be read well
# enough to say where the outcome belongs, and 1 on any other failure to
# record. A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local self_rc=0 destination='' line lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    yolo|away-grant|external) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  if destination=$(fm_parent_channel_destination "$home" "$state"); then
    line="done [key=merged-$id]: merged $id $FM_PR_URL$suffix"
  else
    self_rc=$?
    [ "$self_rc" -eq 1 ] || return 3
    destination=''
  fi

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_merge_outcome_journal "$home" "$state" "$id" "$url" \
      "$provider" "$host" "$path" "$number"; then
    fm_lock_release "$lock"
    return 1
  fi
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ -n "$destination" ]; then
    fm_parent_channel_append_once "$destination" "$line" || status=1
  fi
  if [ "$status" -eq 0 ] && { [ "$origin" = poll ] || [ -z "$destination" ]; }; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}
