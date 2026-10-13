#!/usr/bin/env bash
# fm-antidrift-check.sh - detect repository drift and trigger the safety net.
#
# Usage:
#   fm-antidrift-check.sh refresh
#   fm-antidrift-check.sh cached
#   fm-antidrift-check.sh --help
#
# refresh is the producer. The watcher starts it detached (the same pattern as
# the home-summary refresh), one instance at a time, and it never blocks a
# heartbeat. It builds this home's inventory, reads each worktree without
# taking git locks, triggers due WIP checkpoints and pushes through
# bin/fm-wip-checkpoint.sh, and publishes ONE coalesced line to state/.antidrift
# plus the next due epoch to state/.antidrift-next. cached prints that line
# when it is news. The watcher's heartbeat reads the same cache through
# bin/fm-wip-lib.sh and raises a `check:` wake; no git or network call ever
# happens on the heartbeat path.
#
# Inventory (this home only, no cross-home reconstruction): the worktree= of
# every state/*.meta, the clones registered in data/projects.md, and this
# home's own repository. `git worktree list` is never used as an inventory, so
# another home's pool copy in a shared git directory is never adopted. A task
# worktree is read or snapshotted only while its pool-slot claim names that
# task; a reassigned, unclaimed or unreadable slot is skipped and alarmed.
#
# Alarms, each a count in the one line. All are literal thresholds:
#   no upstream          a worktree whose branch has no GitHub upstream (scouts excluded)
#   >10 unpushed         commits ahead of the upstream, or of the native pushed head
#   push >4h             last successful push older than 4 hours
#   push age unknown     no native or WIP receipt exists for that branch
#   dirty >30m           uncommitted changes observed continuously for 30 minutes
#   push DISABLED        a remote whose push URL is DISABLED
#   PR >48h              an open PR of the forge login, not registered or with no
#                        presentation receipt (pr_presented in the task metadata)
#   WIP blocked          a checkpoint that could not be published, with the reason
#   slot not proven      a task worktree whose pool-slot claim is not this task's
# Clocks are never inferred. The last push is the native pipeline receipt
# (axi status branch_sync.pipeline.pushed_at with remote.freshness=pipeline_push)
# or the WIP push receipt; otherwise the age is reported as unknown. Dirty
# duration is tracked from the first observation and persisted; an unobserved
# start is unknown, never backdated from file times. A forge that cannot answer
# is reported as unknown and never as clean.
#
# Triggers: a checkpoint at each task milestone (a new done: status line or a
# newly registered PR) and at least every 30 minutes for an active worktree; a
# WIP push as soon as a milestone checkpoint exists, within 90 minutes of the
# oldest unpublished checkpoint, and at least once every 24 hours even with
# nothing new. Nothing here pushes, fetches, rebases, merges, deletes or
# repairs anything outside the WIP store.
# Env: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_WIP_NOW,
# FM_CHECK_INTERVAL (tick), FM_CHECK_TIMEOUT (bound per external call).
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

# shellcheck source=bin/fm-cli-lib.sh
fm_cli_dir=${BASH_SOURCE[0]%/*}
[ "$fm_cli_dir" != "${BASH_SOURCE[0]}" ] || fm_cli_dir=.
. "$fm_cli_dir/fm-cli-lib.sh" 2>/dev/null || true
unset fm_cli_dir
if command -v fm_cli_help >/dev/null 2>&1; then fm_cli_help "$@"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CK="$SCRIPT_DIR/fm-wip-checkpoint.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wip-lib.sh
. "$SCRIPT_DIR/fm-wip-lib.sh"

TICK=${FM_CHECK_INTERVAL:-300}
case "$TICK" in ''|*[!0-9]*|0) TICK=300 ;; esac
CALL_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CALL_TIMEOUT" in ''|*[!0-9]*|0) CALL_TIMEOUT=30 ;; esac
NM_TIMEOUT=8
MAX_LINE=240
UNPUSHED_MAX=10
PUSH_AGE_MAX=14400
DIRTY_MAX=1800
CKPT_EVERY=1800
PUSH_TRIGGER=5400
PUSH_DAILY=82800
PR_MIN_DAYS=2
PR_POLL_SECS=1800

# Inventory arrays (indexed in parallel).
E_PATH=(); E_TASK=(); E_PROJ=(); E_KIND=(); E_MODE=()

NOW=0
NEXT_DUE=0
declare_counts() {
  C_NOUP=(); C_MANY=(); C_PUSH4=(); C_PUSHUNK=(); C_DIRTY=(); C_DISABLED=(); C_PRUNREG=(); C_PRNOPROOF=()
  C_WIPBLOCK=(); C_SLOT=(); UNKNOWN=()
}

home_real() { wip_real_path "$FM_HOME"; }

add_entry() {  # <path> <task> <project> <kind> <mode>
  local real i
  real=$(wip_real_path "$1") || return 0
  GIT_OPTIONAL_LOCKS=0 git -C "$real" rev-parse --git-dir >/dev/null 2>&1 || return 0
  for i in "${!E_PATH[@]}"; do
    if [ "${E_PATH[$i]}" = "$real" ]; then
      # One live path named twice (two task records, or a task and a root) is a
      # reuse collision: neither claim is proven, so the entry is poisoned.
      E_KIND[i]=ambiguous
      return 0
    fi
  done
  E_PATH+=("$real"); E_TASK+=("$2"); E_PROJ+=("$3"); E_KIND+=("$4"); E_MODE+=("$5")
}

meta_get() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

build_inventory() {
  local meta id wt kind project name hreal line mode
  hreal=$(home_real)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    wt=$(meta_get "$meta" worktree); kind=$(meta_get "$meta" kind); project=$(meta_get "$meta" project)
    [ -n "$wt" ] || continue
    case "$kind" in scout) kind=scout ;; *) kind=ship ;; esac
    if [ -n "$project" ] && [ "$(wip_real_path "$project")" = "$hreal" ]; then name=firstmate
    else name=$(basename "${project:-unknown}"); fi
    add_entry "$wt" "$id" "$name" "$kind" ""
  done
  # The registry and the home root belong to a home only while STATE is that
  # home's own state directory; an override points at someone else's state.
  [ "$(wip_real_path "$STATE")" = "$(wip_real_path "$FM_HOME/state")" ] || return 0
  if [ -f "$DATA/projects.md" ]; then
    while IFS= read -r line; do
      case "$line" in '- '*) ;; *) continue ;; esac
      name=${line#- }; name=${name%% *}
      [ -n "$name" ] && [ -d "$FM_HOME/projects/$name" ] || continue
      mode=$(printf '%s\n' "$line" | sed -n 's/^- [^ ]* \[\([a-z-]*\).*/\1/p')
      add_entry "$FM_HOME/projects/$name" "" "$name" project "${mode:-no-mistakes}"
    done < "$DATA/projects.md"
  fi
  add_entry "$FM_HOME" "" firstmate home ""
}

# --- facts ------------------------------------------------------------------

src() { wip_src_git "$@"; }

iso_age_unit_old_enough() {  # "<N><unit> ago" -> 0 when >= PR_MIN_DAYS
  local n unit
  n=${1%% *}; unit=${n##*[0-9]}; n=${n%"$unit"}
  case "$unit" in
    d) [ "${n:-0}" -ge "$PR_MIN_DAYS" ] ;;
    w|mo|y) return 0 ;;
    *) return 1 ;;
  esac
}

field_add() {  # <label> <count> <names...> -> appends to LINE_PARTS
  local label=$1 count=$2 names
  shift 2
  [ "$count" -gt 0 ] || return 0
  names=$(printf '%s\n' "$@" | head -n 2 | paste -sd, -)
  if [ "$count" -gt 2 ]; then names="$names,+$((count - 2))"; fi
  LINE_PARTS+=("$label $count${names:+ ($names)}")
}

entry_label() {  # <index>
  local i=$1 base
  base=$(basename "${E_PATH[$i]}")
  printf '%s' "${E_TASK[$i]:-${E_PROJ[$i]:-$base}}"
}

process_entry() {  # <index>
  local i=$1 wt task proj kind label key kdir branch up gh remote url ahead pushed_head last_push nm_out fresh dirty ident first head
  local ms_off size milestone=0 pr_now pr_seen snap_rc act due=0 last_attempt ckpt_commit last snap_args
  wt=${E_PATH[$i]}; task=${E_TASK[$i]}; proj=${E_PROJ[$i]}; kind=${E_KIND[$i]}
  label=$(entry_label "$i")
  if [ "$kind" = ambiguous ]; then C_SLOT+=("$label"); return 0; fi
  if [ -n "$task" ]; then
    fm_treehouse_slot_owner_state "$wt" "$task"
    if [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ]; then C_SLOT+=("$label:$FM_TREEHOUSE_SLOT_OWNER"); return 0; fi
  fi
  key=$(wip_key "$wt"); kdir=$(wip_dir "$key")
  branch=$(src "$wt" branch --show-current 2>/dev/null)
  head=$(src "$wt" rev-parse HEAD 2>/dev/null)
  # upstream / GitHub upstream
  up=''; gh=0; ahead=''; last_push=''
  if [ -n "$branch" ]; then
    up=$(src "$wt" for-each-ref --format='%(upstream:short)' "refs/heads/$branch" 2>/dev/null)
    if [ -n "$up" ]; then
      remote=$(src "$wt" config "branch.$branch.remote" 2>/dev/null)
      # The configured URL, not the rewritten one: a url.<base>.insteadOf rule
      # must not hide which forge the upstream names.
      url=$(src "$wt" config "remote.$remote.url" 2>/dev/null)
      [ -n "$url" ] || url=$(src "$wt" remote get-url "$remote" 2>/dev/null)
      case "$url" in *github.com[:/]*) gh=1 ;; esac
      ahead=$(src "$wt" rev-list --count "$up..HEAD" 2>/dev/null)
    fi
  elif [ -n "$head" ] && [ -z "$(src "$wt" branch -r --contains HEAD 2>/dev/null | head -n 1)" ]; then
    gh=0   # detached with commits no remote has
  else
    gh=1   # detached and fully contained in a remote: not drift
  fi
  # native push receipt for pipeline-authored branches
  if [ "$kind" = ship ] && [ -n "$branch" ] && command -v no-mistakes >/dev/null 2>&1; then
    nm_out=$(fm_nm_run "$wt" "$NM_TIMEOUT" axi status) || nm_out=''
    pushed_head=$(fm_nm_branch_sync_pipeline_field "$nm_out" pushed_head)
    fresh=$(fm_nm_branch_sync_freshness "$nm_out")
    if [ "$fresh" = pipeline_push ]; then
      last_push=$(fm_nm_branch_sync_pipeline_field "$nm_out" pushed_at)
      case "$last_push" in ''|*[!0-9]*) last_push='' ;; esac
    fi
    if [ -z "$up" ] && [ -n "$pushed_head" ] && [ -n "$(fm_nm_resolve_commit "$wt" "$pushed_head")" ]; then
      ahead=$(src "$wt" rev-list --count "$pushed_head..HEAD" 2>/dev/null)
    fi
  fi
  case "$ahead" in ''|*[!0-9]*) ahead='' ;; esac
  # dirty tracking (persisted, never backdated)
  ident=$(src "$wt" status --porcelain=v1 -z 2>/dev/null | wip_hash)
  dirty=0
  [ -z "$(src "$wt" status --porcelain=v1 2>/dev/null | head -n 1)" ] || dirty=1
  if [ "$dirty" = 1 ]; then
    first=$(wip_kv_get "$kdir/dirty" first_observed)
    if [ -z "$first" ] || [ "$(wip_kv_get "$kdir/dirty" head)" != "$head" ]; then
      wip_kv_set "$kdir/dirty" first_observed "$NOW"; wip_kv_set "$kdir/dirty" head "$head"
      first=$NOW
    fi
    wip_kv_set "$kdir/dirty" ident "$ident"
    if [ $((NOW - first)) -ge "$DIRTY_MAX" ]; then C_DIRTY+=("$label"); fi
  else
    [ ! -e "$kdir/dirty" ] || rm -f "$kdir/dirty"
  fi
  # alarms that need a product (non-scout) worktree
  if [ "$kind" != scout ]; then
    if [ "$gh" = 0 ]; then C_NOUP+=("$label$([ "${E_MODE[$i]}" = local-only ] && printf '[local-only]')"); fi
    if [ -n "$ahead" ] && [ "$ahead" -gt "$UNPUSHED_MAX" ]; then C_MANY+=("$label:$ahead"); fi
    # Push age is a property of produced work: a task's own worktree. A
    # registered checkout or the home root has no native push receipt to read.
    if [ "$kind" = ship ]; then
      if [ -n "$last_push" ]; then
        if [ $((NOW - last_push)) -gt "$PUSH_AGE_MAX" ]; then C_PUSH4+=("$label"); fi
      elif [ "$gh" = 1 ] && [ -n "$branch" ]; then
        C_PUSHUNK+=("$label")
      fi
    fi
  fi
  # --- checkpoint triggers (active task worktrees, or dirty roots) ---
  if [ -n "$task" ]; then
    size=$(wc -c < "$STATE/$task.status" 2>/dev/null | tr -d ' ')
    ms_off=$(wip_kv_get "$kdir/ms" status_off); pr_seen=$(wip_kv_get "$kdir/ms" pr)
    pr_now=$(meta_get "$STATE/$task.meta" pr)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    case "$ms_off" in ''|*[!0-9]*) ms_off=0 ;; esac
    if [ "$size" -gt "$ms_off" ] && tail -c "+$((ms_off + 1))" "$STATE/$task.status" 2>/dev/null | grep -Eq '^(done|failed)[ :[]'; then milestone=1; fi
    [ -z "$pr_now" ] || [ "$pr_now" = "$pr_seen" ] || milestone=1
  fi
  last_attempt=$(wip_kv_get "$kdir/ckpt" last_attempt)
  case "$last_attempt" in ''|*[!0-9]*) last_attempt=0 ;; esac
  if [ -n "$task" ] || [ "$dirty" = 1 ]; then
    if [ "$milestone" = 1 ] || [ $((NOW - last_attempt)) -ge "$CKPT_EVERY" ]; then
      snap_rc=0
      snap_args=("$wt")
      [ -z "$task" ] || snap_args+=(--task "$task")
      [ "$milestone" != 1 ] || snap_args+=(--milestone)
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
        "$CK" snapshot "${snap_args[@]}" >/dev/null 2>&1 || snap_rc=$?
      if [ "$snap_rc" -eq 3 ]; then C_SLOT+=("$label:snapshot-refused"); fi
      if [ "$snap_rc" -ne 0 ] && [ "$snap_rc" -ne 3 ]; then C_WIPBLOCK+=("$label:snapshot"); fi
      if [ "$milestone" = 1 ] && [ "$snap_rc" -eq 0 ] && [ -n "$task" ]; then
        wip_kv_set "$kdir/ms" status_off "$size"; wip_kv_set "$kdir/ms" pr "$pr_now"
      fi
      last_attempt=$NOW
    fi
    act=$((last_attempt + CKPT_EVERY))
    if [ "$NEXT_DUE" -eq 0 ] || [ "$act" -lt "$NEXT_DUE" ]; then NEXT_DUE=$act; fi
  fi
  # --- publication triggers ---
  ckpt_commit=$(wip_kv_get "$kdir/ckpt" commit)
  if [ -n "$ckpt_commit" ]; then
    first=$(wip_kv_get "$kdir/ckpt" first_unpublished)
    if [ -n "$first" ]; then
      if [ "$milestone" = 1 ] || [ $((NOW - first)) -ge "$PUSH_TRIGGER" ]; then due=1; fi
    fi
    last=$(wip_kv_get "$kdir/push" last_verified)
    case "$last" in ''|*[!0-9]*) due=1 ;; *) [ $((NOW - last)) -lt "$PUSH_DAILY" ] || due=1 ;; esac
    if [ "$due" = 1 ]; then
      FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
        "$CK" push "$wt" --project "$proj" >/dev/null 2>&1 || true
    fi
    case "$(wip_kv_get "$kdir/push" result)" in
      no-remote) C_WIPBLOCK+=("$label:sans remote") ;;
      private-not-proven) C_WIPBLOCK+=("$label:privé non prouvé") ;;
      deny-hit) C_WIPBLOCK+=("$label:chemin refusé") ;;
      push-failed-*) C_WIPBLOCK+=("$label:push refusé") ;;
    esac
  fi
}

# --- remotes and PRs --------------------------------------------------------

check_disabled_remotes() {
  local seen='' i wt common r u
  for i in "${!E_PATH[@]}"; do
    wt=${E_PATH[$i]}
    common=$(src "$wt" rev-parse --git-common-dir 2>/dev/null)
    common=$(cd "$wt" && cd "$common" 2>/dev/null && pwd -P) || continue
    case " $seen " in *" $common "*) continue ;; esac
    seen="$seen $common"
    for r in $(src "$wt" remote 2>/dev/null); do
      u=$(src "$wt" remote get-url --push "$r" 2>/dev/null)
      case "$u" in *DISABLED*|*disabled*) C_DISABLED+=("$(entry_label "$i"):$r") ;; esac
    done
  done
}

registered_pr_urls() {
  { cat "$STATE"/*.meta 2>/dev/null; cat "$DATA"/*/contributions.json 2>/dev/null; cat "$DATA/backlog.md" 2>/dev/null; } \
    | grep -Eo 'https://github\.com/[^/ "]+/[^/ "]+/pull/[0-9]+' | sort -u
}

presented_pr_urls() {
  cat "$STATE"/*.meta 2>/dev/null | sed -n 's/^pr_presented=[0-9]*://p' | sort -u
}

check_prs() {
  local seen='' i wt common cache out url age reg pres now_cache
  if ! command -v gh-axi >/dev/null 2>&1; then UNKNOWN+=("PR: gh-axi absent"); return 0; fi
  reg=$(registered_pr_urls); pres=$(presented_pr_urls)
  for i in "${!E_PATH[@]}"; do
    wt=${E_PATH[$i]}
    [ "${E_KIND[$i]}" != scout ] || continue
    [ -z "${E_TASK[$i]}" ] || continue
    common=$(src "$wt" rev-parse --git-common-dir 2>/dev/null)
    common=$(cd "$wt" && cd "$common" 2>/dev/null && pwd -P) || continue
    case " $seen " in *" $common "*) continue ;; esac
    seen="$seen $common"
    src "$wt" config --get-regexp '^remote\..*\.url$' 2>/dev/null | grep -q 'github\.com' || continue
    cache="$STATE/wip/pr-$(printf '%s' "$common" | wip_hash)"
    now_cache=$(wip_kv_get "$cache" polled)
    case "$now_cache" in ''|*[!0-9]*) now_cache=0 ;; esac
    if [ $((NOW - now_cache)) -ge "$PR_POLL_SECS" ]; then
      mkdir -p "$STATE/wip"
      if out=$(cd "$wt" && fm_run_timed "$CALL_TIMEOUT" gh-axi pr list --author @me 2>/dev/null); then
        printf '%s\n' "$out" | sed -n 's/.*"\(https:[^"]*\)",\([^,]*\)$/\1 \2/p' > "$cache.list.tmp" && mv -f "$cache.list.tmp" "$cache.list"
        wip_kv_set "$cache" polled "$NOW"; wip_kv_set "$cache" ok 1
      else
        wip_kv_set "$cache" polled "$NOW"; wip_kv_set "$cache" ok 0
      fi
    fi
    if [ "$(wip_kv_get "$cache" ok)" != 1 ]; then UNKNOWN+=("PR: $(entry_label "$i")"); continue; fi
    while IFS= read -r out; do
      [ -n "$out" ] || continue
      url=${out%% *}; age=${out#* }
      iso_age_unit_old_enough "$age" || continue
      if printf '%s\n' "$pres" | grep -qxF -- "$url"; then continue; fi
      if printf '%s\n' "$reg" | grep -qxF -- "$url"; then C_PRNOPROOF+=("${url##*/pull/}"); else C_PRUNREG+=("${url##*/pull/}"); fi
    done < "$cache.list"
  done
}

compose_line() {
  LINE_PARTS=()
  field_add "sans-upstream" "${#C_NOUP[@]}" ${C_NOUP[@]+"${C_NOUP[@]}"}
  field_add ">10-non-poussés" "${#C_MANY[@]}" ${C_MANY[@]+"${C_MANY[@]}"}
  field_add "push>4h" "${#C_PUSH4[@]}" ${C_PUSH4[@]+"${C_PUSH4[@]}"}
  field_add "âge-push-inconnu" "${#C_PUSHUNK[@]}" ${C_PUSHUNK[@]+"${C_PUSHUNK[@]}"}
  field_add "sale>30m" "${#C_DIRTY[@]}" ${C_DIRTY[@]+"${C_DIRTY[@]}"}
  field_add "push-DISABLED" "${#C_DISABLED[@]}" ${C_DISABLED[@]+"${C_DISABLED[@]}"}
  field_add "PR>48h-non-enregistrée" "${#C_PRUNREG[@]}" ${C_PRUNREG[@]+"${C_PRUNREG[@]}"}
  field_add "PR>48h-sans-preuve-de-présentation" "${#C_PRNOPROOF[@]}" ${C_PRNOPROOF[@]+"${C_PRNOPROOF[@]}"}
  field_add "WIP-bloqué" "${#C_WIPBLOCK[@]}" ${C_WIPBLOCK[@]+"${C_WIPBLOCK[@]}"}
  field_add "propriété-non-prouvée" "${#C_SLOT[@]}" ${C_SLOT[@]+"${C_SLOT[@]}"}
  local body='' p
  for p in ${LINE_PARTS[@]+"${LINE_PARTS[@]}"}; do body="${body:+$body; }$p"; done
  if [ "${#UNKNOWN[@]}" -gt 0 ]; then body="${body:+$body; }inconnu: $(printf '%s\n' "${UNKNOWN[@]}" | head -n 2 | paste -sd, -)"; fi
  [ -n "$body" ] || { printf '\n'; return 0; }
  fm_cap_line_var "antidrift: $body" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}

publish() {  # <line>
  local tmp
  tmp=$(mktemp "$STATE/.antidrift.XXXXXX") || return 1
  printf 'fm-antidrift-v1\nepoch=%s\nline=%s\n' "$NOW" "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE/.antidrift" || { rm -f "$tmp"; return 1; }
  tmp=$(mktemp "$STATE/.antidrift-next.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$STATE/.antidrift-next"
}

action_refresh() {
  local lock="$STATE/.antidrift.lock" i line next
  [ -d "$STATE" ] || exit 0
  fm_lock_try_acquire "$lock" || exit 0
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock'" EXIT
  NOW=$(wip_now)
  declare_counts
  build_inventory
  for i in "${!E_PATH[@]}"; do process_entry "$i"; done
  check_disabled_remotes
  check_prs
  line=$(compose_line)
  next=$((NOW + TICK))
  if [ "$NEXT_DUE" -gt 0 ] && [ "$NEXT_DUE" -lt "$next" ]; then next=$NEXT_DUE; fi
  [ "$next" -gt "$NOW" ] || next=$((NOW + 1))
  publish "$line" "$next" || exit 1
}

case "${1:-}" in
  refresh) action_refresh ;;
  cached) antidrift_news_line ;;
  '') printf 'fm-antidrift-check: missing action\n' >&2; exit 2 ;;
  *) printf 'fm-antidrift-check: unknown action: %s\n' "$1" >&2; exit 2 ;;
esac
