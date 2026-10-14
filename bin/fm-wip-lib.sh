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
# refresh the index (a validation run may own that branch), and is bounded: one
# blocked git must not hold the producer lock and silence the guard. A read that
# times out is recorded in $WIP_TIMEOUT_MARK (when the caller set one) so the
# caller reports the worktree as unknown instead of reading the empty output as clean.
wip_src_git() {  # <worktree> <git args...>
  local wt=$1 rc=0 bound=${FM_WIP_GIT_TIMEOUT:-15}
  shift
  case "$bound" in ''|*[!0-9]*|0) bound=15 ;; esac
  if command -v fm_run_timed >/dev/null 2>&1; then
    GIT_OPTIONAL_LOCKS=0 fm_run_timed "$bound" git -C "$wt" "$@" || rc=$?
    if [ "$rc" -eq 124 ] && [ -n "${WIP_TIMEOUT_MARK:-}" ]; then printf '%s\n' "$wt" >> "$WIP_TIMEOUT_MARK"; fi
    return "$rc"
  fi
  GIT_OPTIONAL_LOCKS=0 git -C "$wt" "$@"
}

# True for a real GitHub host URL only (https, ssh and scp forms), never a name
# that merely contains the string (notgithub.com, github.com.evil.example).
wip_is_github_url() {  # <url>
  case "$1" in
    https://github.com/*|http://github.com/*|https://*@github.com/*|http://*@github.com/*) return 0 ;;
    git@github.com:*|ssh://git@github.com/*|ssh://git@github.com:*/*|ssh://github.com/*) return 0 ;;
  esac
  return 1
}

# wip_target <project>: "<owner>/<name>" or "none" from config/wip-remotes,
# empty when the project has no line. One owner for this parse.
wip_target() {  # uses $CONFIG
  awk -v p="$1" '$1 == p && ($2 == "none" || $2 ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) { print $2; exit }' "$CONFIG/wip-remotes" 2>/dev/null
}

# Ownership of a task worktree. A Treehouse pool slot is proven only by its
# owner claim naming this task. A worktree outside any pool (for example an Orca
# copy) has no claim to read; its authority is record exclusivity, which the
# inventory enforces (two records for one path are refused). Anything that
# cannot be read is refused. Sets WIP_SLOT_REASON on refusal.
wip_slot_proven() {  # <worktree> <task>
  local slot parent pool
  # shellcheck disable=SC2034 # Output variable, read by the sourcing caller.
  WIP_SLOT_REASON=unreadable
  slot=$(wip_real_path "$1") || return 1
  parent=$(dirname "$slot"); pool=$(dirname "$parent")
  if [ -e "$parent/.fm-slot-owner" ] || [ -L "$parent/.fm-slot-owner" ] || [ -f "$pool/treehouse-state.json" ]; then
    fm_treehouse_slot_owner_state "$slot" "$2"
    case "${FM_TREEHOUSE_SLOT_OWNER:-unsafe}" in
      mine) return 0 ;;
      other) WIP_SLOT_REASON=other ;;
      absent) WIP_SLOT_REASON=absent ;;
      *) WIP_SLOT_REASON=unsafe ;;
    esac
    return 1
  fi
  WIP_SLOT_REASON=non-pool
  return 0
}

# --- anti-drift cache readers (no git, no network, no subprocess) -----------
# bin/fm-antidrift-check.sh refresh publishes state/.antidrift atomically:
#   fm-antidrift-v1 / epoch=<n> / line=<one line, empty when nothing is wrong> / sig=<digest of the uncapped composition>
# The watcher reads only that file through the helpers below, so neither the
# heartbeat nor the check cadence ever waits on git or the forge. A line is news
# while its line or digest differs from the last one reported, and an unchanged
# alarm is announced again after a reminder interval so an ignored alarm does
# not go quiet. A clean cache re-arms the next report. A cache that stopped being
# refreshed is itself news (a stale producer is never read as clean).

ANTIDRIFT_REMIND_SECS=21600
AD_LINE=''
AD_SIG=''

# antidrift_cache_read: sets AD_LINE and AD_SIG from the cache (no subshell).
antidrift_cache_read() {
  local f="$STATE/.antidrift" l ep='' tick lim now
  AD_LINE=''; AD_SIG=''
  if [ -f "$f" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in
        epoch=*) ep=${l#epoch=} ;;
        line=*) AD_LINE=${l#line=} ;;
        sig=*) AD_SIG=${l#sig=} ;;
      esac
    done < "$f"
  else
    [ -f "$STATE/.antidrift-first" ] || return 0
    IFS= read -r ep < "$STATE/.antidrift-first" || ep=''
  fi
  tick=${FM_CHECK_INTERVAL:-300}
  case "$tick" in ''|*[!0-9]*|0) tick=300 ;; esac
  lim=$((tick * 3)); [ "$lim" -ge 900 ] || lim=900
  case "$ep" in
    ''|*[!0-9]*) ;;
    *)
      now=$(wip_now)
      if [ $((now - ep)) -gt "$lim" ]; then
        AD_LINE='antidrift: unknown: producer-stale'
        AD_SIG=stale
      fi
      ;;
  esac
}

# antidrift_news_check: 0 when the cached line is news (AD_LINE/AD_SIG then hold it).
antidrift_news_check() {
  local r_line='' r_sig='' r_ep='' now
  antidrift_cache_read
  if [ -z "$AD_LINE" ]; then
    [ ! -e "$STATE/.antidrift-reported" ] || rm -f "$STATE/.antidrift-reported"
    return 1
  fi
  if [ -f "$STATE/.antidrift-reported" ]; then
    { IFS= read -r r_line; IFS= read -r r_sig; IFS= read -r r_ep; } < "$STATE/.antidrift-reported" || true
  fi
  if [ "$AD_LINE" = "$r_line" ] && [ "$AD_SIG" = "$r_sig" ]; then
    case "$r_ep" in
      ''|*[!0-9]*) return 1 ;;
    esac
    now=$(wip_now)
    [ $((now - r_ep)) -ge "$ANTIDRIFT_REMIND_SECS" ] || return 1
  fi
  return 0
}

antidrift_news_line() {  # prints the cached line only when it is news
  if antidrift_news_check; then printf '%s\n' "$AD_LINE"; fi
}

antidrift_mark_reported() {  # <line> [sig]
  local tmp sig=${2-$AD_SIG}
  tmp=$(mktemp "$STATE/.antidrift-reported.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$1" "$sig" "$(wip_now)" > "$tmp" && mv -f "$tmp" "$STATE/.antidrift-reported"
}

# 0 when the producer is due. Due means the next-due epoch is absent, malformed or
# passed. A producer that was launched and has not published since (it died or is
# stuck) is not relaunched sooner than one tick, so a dead producer costs one
# launch per tick, not one per poll.
antidrift_refresh_due() {
  local due='' kick='' ep='' tick now l
  now=$(wip_now)
  tick=${FM_CHECK_INTERVAL:-300}
  case "$tick" in ''|*[!0-9]*|0) tick=300 ;; esac
  if [ -f "$STATE/.antidrift-next" ]; then
    IFS= read -r due < "$STATE/.antidrift-next" || due=''
    case "$due" in ''|*[!0-9]*) due='' ;; esac
    if [ -n "$due" ] && [ "$now" -lt "$due" ]; then return 1; fi
  fi
  [ -f "$STATE/.antidrift-kick" ] || return 0
  IFS= read -r kick < "$STATE/.antidrift-kick" || kick=''
  case "$kick" in ''|*[!0-9]*) return 0 ;; esac
  if [ -f "$STATE/.antidrift" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in epoch=*) ep=${l#epoch=} ;; esac
    done < "$STATE/.antidrift"
  fi
  case "$ep" in ''|*[!0-9]*) ep=0 ;; esac
  # published since the last launch: the producer is healthy, launch when due
  [ "$ep" -lt "$kick" ] || return 0
  [ $((now - kick)) -ge "$tick" ]
}
