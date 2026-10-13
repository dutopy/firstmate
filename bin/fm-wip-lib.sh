#!/usr/bin/env bash
# Shared helpers for the WIP checkpoint producer and the anti-drift check.
#
# ONE owner for where WIP state lives and how it is read and written. Sourced,
# never executed. A worktree's WIP state is keyed by the hash of its real path:
#   $STATE/wip/<key>.git     the shadow bare repo (its own index, refs, objects)
#   $STATE/wip/<key>/info    path, task, label, lineage number, deny-list hash
#   $STATE/wip/<key>/ckpt    last attempt, last checkpoint, tree, commit
#   $STATE/wip/<key>/push    last push, last verified, pushed commit, result
# Each file is KEY=VALUE lines written atomically. A missing key reads empty,
# which every caller treats as unknown rather than as zero.

wip_now() {
  case "${FM_WIP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_WIP_NOW" ;;
  esac
}

wip_hash() {  # stdin -> hex digest
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print substr($1,1,40)}'
  else sha256sum | awk '{print substr($1,1,40)}'; fi
}

# wip_real_path <dir>: physical path, empty when absent.
wip_real_path() {
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

wip_key() {  # <real-worktree-path>
  printf '%s' "$1" | wip_hash
}

wip_dir() { printf '%s/wip/%s\n' "$STATE" "$1"; }
wip_shadow() { printf '%s/wip/%s.git\n' "$STATE" "$1"; }

# wip_kv_get <file> <key>
wip_kv_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# wip_kv_set <file> <key> <value>: replace or append one key atomically.
wip_kv_set() {
  local file=$1 key=$2 value=$3 tmp
  mkdir -p "$(dirname "$file")" || return 1
  tmp=$(mktemp "$file.XXXXXX") || return 1
  { [ -f "$file" ] && grep -v "^$key=" "$file"; printf '%s=%s\n' "$key" "$value"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

# A pool slot is reused by later tasks, and WIP state is keyed by the slot's
# path. When the task recorded for a key differs from the current owner, the
# previous task's cadence, milestone, dirty and push records must not carry
# over: reset them and record the new owner at once.
wip_reset_if_task_changed() {  # <kdir> <current-task>
  local kdir=$1 task=$2 recorded
  [ -f "$kdir/info" ] || return 0
  recorded=$(wip_kv_get "$kdir/info" task)
  [ "$recorded" != "$task" ] || return 0
  rm -f "$kdir/ms" "$kdir/ckpt" "$kdir/dirty" "$kdir/push"
  wip_kv_set "$kdir/info" task "$task"
}

# Every git read against a source worktree must never take an optional lock or
# refresh the index: a validation run may own that branch.
wip_src_git() {  # <worktree> <git args...>
  local wt=$1
  shift
  GIT_OPTIONAL_LOCKS=0 git -C "$wt" "$@"
}

# --- anti-drift cache readers (no git, no network, no subprocess) -----------
# bin/fm-antidrift-check.sh refresh publishes state/.antidrift atomically:
#   fm-antidrift-v1 / epoch=<n> / line=<one line, empty when nothing is wrong>
# The watcher's heartbeat reads only that file through the helpers below, so the
# heartbeat never waits on git or the forge. A line is news only while it
# differs from the last one reported; a clean cache re-arms the next report.

antidrift_cached_line() {  # prints the cached line, empty when none
  local f="$STATE/.antidrift" l
  [ -f "$f" ] || return 0
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in line=*) printf '%s\n' "${l#line=}"; return 0 ;; esac
  done < "$f"
}

antidrift_news_line() {  # prints the cached line only when it is news
  local line reported=''
  line=$(antidrift_cached_line)
  if [ -z "$line" ]; then
    [ ! -e "$STATE/.antidrift-reported" ] || rm -f "$STATE/.antidrift-reported"
    return 0
  fi
  [ ! -f "$STATE/.antidrift-reported" ] || IFS= read -r reported < "$STATE/.antidrift-reported" || true
  [ "$line" = "$reported" ] || printf '%s\n' "$line"
}

antidrift_mark_reported() {  # <line>
  local tmp
  tmp=$(mktemp "$STATE/.antidrift-reported.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$STATE/.antidrift-reported"
}

# 0 when the producer is due: no next-due record, or its epoch has passed.
antidrift_refresh_due() {
  local due
  [ -f "$STATE/.antidrift-next" ] || return 0
  IFS= read -r due < "$STATE/.antidrift-next" || return 0
  case "$due" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(wip_now)" -ge "$due" ]
}
