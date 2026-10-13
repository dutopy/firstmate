#!/usr/bin/env bash
# fm-wip-checkpoint.sh - snapshot a worktree into a private shadow repo and
# publish that WIP lineage to a captain-approved private GitHub remote.
#
# Usage:
#   fm-wip-checkpoint.sh snapshot <worktree> [--task <id>] [--milestone]
#   fm-wip-checkpoint.sh push <worktree> --project <name>
#   fm-wip-checkpoint.sh --help
#
# snapshot records the worktree's eligible files as one commit on a dedicated
# branch (wip/<label>/e<lineage>) of a shadow bare repo under state/wip/. The
# source repository is only READ: files come from
# `git ls-files --cached --others --exclude-standard` run with optional locks
# off, so the source index, refs, objects, HEAD and every .gitignore,
# .git/info/exclude and core.excludesFile rule are untouched and honoured. The
# shadow repo has its own index, so a pipeline that owns the source branch is
# never disturbed. Its history is an orphan lineage of filtered trees: no source
# ancestor is ever reachable from it.
#
# Eligibility: tracked and untracked files, minus the central deny list in
# bin/fm-wip-exclude.txt (plus config/wip-exclude, additive only), minus the
# home-private directories when the worktree belongs to the home's own
# repository, minus the shadow store itself, minus files over the GitHub size
# limit. Changing the deny list starts a new lineage (e<N+1>): published history
# is never rewritten.
#
# With --task, the snapshot happens only when the pool slot's owner claim names
# that task (fm_treehouse_slot_owner_state = mine). A reassigned, unreadable or
# unclaimed slot is refused (exit 3) so a stale record cannot copy a new owner.
#
# push publishes the current lineage to the GitHub repository named for
# <project> in config/wip-remotes (lines: "<project> <owner>/<name>"). A line
# "<project> none" declares local checkpoints only: publication is intentionally
# off for that project (exit 8), which is a posture, not a fault. No entry at
# all means no publication either (exit 4), and that one is reported. Before EVERY push, repository visibility is
# proven fresh (no cache) with gh-axi, and only an explicit "visibility:
# private" answer allows it; public, unknown or unreachable refuses (exit 5).
# Every commit about to leave is checked against the deny list again (exit 6).
# The refspec never carries a leading +, only refs/heads/wip/* is pushed, and a
# rejected push is reported, never forced (exit 7). A successful push writes the
# durable receipt state/wip/<key>/push. Nothing here creates a repository.
#
# Exit: 0 ok, 1 error, 2 usage, 3 ownership not proven, 4 no remote configured,
# 5 private not proven, 6 deny hit, 7 push failed or rejected, 8 publication
# intentionally off.
# Env: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_WIP_NOW (test clock),
# FM_CHECK_TIMEOUT (bound for the visibility read and the push).
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
DENY_FILE="$SCRIPT_DIR/fm-wip-exclude.txt"
WIP_MAX_FILE_BYTES=94371840
WIP_MAX_PASSES=3
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wip-lib.sh
. "$SCRIPT_DIR/fm-wip-lib.sh"

die() { printf 'fm-wip-checkpoint: %s\n' "$1" >&2; exit "${2:-1}"; }

usage_error() { printf 'fm-wip-checkpoint: %s\n' "$1" >&2; exit 2; }

DENY_GLOBS=()
load_deny_globs() {
  local line f
  DENY_GLOBS=()
  for f in "$DENY_FILE" "$CONFIG/wip-exclude"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      DENY_GLOBS+=("$line")
    done < "$f"
  done
}

deny_hash() {
  { cat "$DENY_FILE" 2>/dev/null; cat "$CONFIG/wip-exclude" 2>/dev/null; } | wip_hash
}

# True when <worktree> belongs to the same repository as this home's own
# checkout, whose private directories must never be snapshotted.
is_home_repo_worktree() {  # <worktree>
  local a b
  a=$(wip_src_git "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  a=$(wip_real_path "$(cd "$1" && cd "$a" 2>/dev/null && pwd -P)") || return 1
  b=$(GIT_OPTIONAL_LOCKS=0 git -C "$FM_HOME" rev-parse --git-common-dir 2>/dev/null) || return 1
  b=$(wip_real_path "$(cd "$FM_HOME" && cd "$b" 2>/dev/null && pwd -P)") || return 1
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# Print the pathspec exclusions (one per line) for a snapshot of <worktree>.
exclusion_pathspecs() {  # <real-worktree> <shadow>
  local wt=$1 shadow=$2 g rel store
  for g in ${DENY_GLOBS[@]+"${DENY_GLOBS[@]}"}; do printf ':(exclude,glob)%s\n' "$g"; done
  if is_home_repo_worktree "$wt"; then
    for g in 'data/**' 'state/**' 'config/**' 'projects/**' '.no-mistakes/**' '.env'; do
      printf ':(exclude,glob)%s\n' "$g"
    done
  fi
  # The whole WIP store (shadow repos, info, locks, pass scratch) and the state
  # directory that holds it are never captured, wherever they sit.
  for store in "$(wip_real_path "$STATE/wip")" "$(wip_real_path "$STATE")" "$(dirname "$shadow")"; do
    case "$store" in
      "$wt"/*) rel=${store#"$wt"/}; printf ':(exclude,glob)%s/**\n' "$rel" ;;
    esac
  done
}

SHADOW=
W() { git --git-dir="$SHADOW" -c core.excludesFile=/dev/null "$@"; }
WT_W() { git --git-dir="$SHADOW" --work-tree="$REAL_WT" -c core.excludesFile=/dev/null "$@"; }

REAL_WT=
KEY=
KDIR=
LABEL=
TASK=

resolve_worktree() {  # <path>
  REAL_WT=$(wip_real_path "$1") || die "not a directory: $1" 2
  wip_src_git "$REAL_WT" rev-parse --git-dir >/dev/null 2>&1 || die "not a git worktree: $REAL_WT" 2
  KEY=$(wip_key "$REAL_WT")
  KDIR=$(wip_dir "$KEY")
  SHADOW=$(wip_shadow "$KEY")
}

# One pass: bring the shadow index in line with the worktree's eligible files
# and print the resulting tree id.
shadow_pass() {
  local tmp present had pathspecs=() p
  tmp=$(mktemp -d "$KDIR/pass.XXXXXX") || return 1
  while IFS= read -r p; do pathspecs+=("$p"); done < <(exclusion_pathspecs "$REAL_WT" "$SHADOW")
  wip_src_git "$REAL_WT" ls-files -z --cached --others --exclude-standard -- . \
    ${pathspecs[@]+"${pathspecs[@]}"} 2>/dev/null > "$tmp/eligible.z" || { rm -rf "$tmp"; return 1; }
  : > "$tmp/present.z"
  while IFS= read -r -d '' p; do
    case "$p" in *$'\n'*) continue ;; esac
    if [ -f "$REAL_WT/$p" ] || [ -L "$REAL_WT/$p" ]; then printf '%s\0' "$p" >> "$tmp/present.z"; fi
  done < "$tmp/eligible.z"
  # Drop files over the forge size limit (wc -c reads sizes, not contents).
  if [ -s "$tmp/present.z" ]; then
    : > "$tmp/sized.z"
    (cd "$REAL_WT" && xargs -0 wc -c < "$tmp/present.z" 2>/dev/null) | awk '
      { n = $1; sub(/^[ \t]*[0-9]+ /, ""); if ($0 != "total" && n+0 > '"$WIP_MAX_FILE_BYTES"') print }' > "$tmp/toolarge.txt"
    if [ -s "$tmp/toolarge.txt" ]; then
      while IFS= read -r -d '' p; do
        grep -qxF -- "$p" "$tmp/toolarge.txt" || printf '%s\0' "$p" >> "$tmp/sized.z"
      done < "$tmp/present.z"
      mv -f "$tmp/sized.z" "$tmp/present.z"
    fi
  fi
  tr '\0' '\n' < "$tmp/present.z" | sort -u > "$tmp/present.txt"
  W ls-files -z | tr '\0' '\n' | sort -u > "$tmp/had.txt"
  comm -23 "$tmp/had.txt" "$tmp/present.txt" | tr '\n' '\0' | WT_W update-index --force-remove -z --stdin || { rm -rf "$tmp"; return 1; }
  WT_W update-index --add -z --stdin < "$tmp/present.z" || { rm -rf "$tmp"; return 1; }
  present=$(WT_W write-tree) || { rm -rf "$tmp"; return 1; }
  had=$present
  rm -rf "$tmp"
  printf '%s\n' "$had"
}

action_snapshot() {
  local worktree='' milestone=0 now lock tree prev parent lineage dh stored_dh ref commit best_effort=0 pass head branch
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) TASK=${2:-}; [ -n "$TASK" ] || usage_error "--task needs an id"; shift 2 ;;
      --milestone) milestone=1; shift ;;
      -*) usage_error "unknown option: $1" ;;
      *) [ -z "$worktree" ] || usage_error "one worktree only"; worktree=$1; shift ;;
    esac
  done
  [ -n "$worktree" ] || usage_error "snapshot needs a worktree"
  resolve_worktree "$worktree"
  now=$(wip_now)
  if [ -n "$TASK" ]; then
    fm_treehouse_slot_owner_state "$REAL_WT" "$TASK"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      mine) ;;
      other) die "slot ownership moved to ${FM_TREEHOUSE_SLOT_OWNER_ID:-another task}; snapshot refused" 3 ;;
      absent) die "slot ownership not proven (no claim); snapshot refused" 3 ;;
      *) die "slot ownership unreadable; snapshot refused" 3 ;;
    esac
  fi
  mkdir -p "$KDIR" || die "cannot create $KDIR"
  lock="$KDIR/lock"
  fm_lock_try_acquire "$lock" || die "another snapshot is running for $REAL_WT" 1
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock'" EXIT
  [ -d "$SHADOW" ] || git init -q --bare "$SHADOW" || die "cannot create the shadow repository"
  load_deny_globs
  dh=$(deny_hash)
  stored_dh=$(wip_kv_get "$KDIR/info" deny_hash)
  lineage=$(wip_kv_get "$KDIR/info" lineage)
  case "$lineage" in ''|*[!0-9]*) lineage=1 ;; esac
  if [ -n "$stored_dh" ] && [ "$stored_dh" != "$dh" ]; then lineage=$((lineage + 1)); fi
  LABEL=${TASK:-wt-${KEY:0:12}}
  case "$LABEL" in *[!A-Za-z0-9._-]*) LABEL=wt-${KEY:0:12} ;; esac
  ref="refs/heads/wip/$LABEL/e$lineage"
  wip_kv_set "$KDIR/info" path "$REAL_WT" || die "cannot write WIP info"
  wip_kv_set "$KDIR/info" task "$TASK" || die "cannot write WIP info"
  wip_kv_set "$KDIR/info" deny_hash "$dh" || die "cannot write WIP info"
  wip_kv_set "$KDIR/info" lineage "$lineage" || die "cannot write WIP info"
  wip_kv_set "$KDIR/info" ref "$ref" || die "cannot write WIP info"
  tree=$(shadow_pass) || die "snapshot enumeration failed"
  pass=1
  while [ "$pass" -lt "$WIP_MAX_PASSES" ]; do
    prev=$tree
    tree=$(shadow_pass) || die "snapshot enumeration failed"
    [ "$tree" != "$prev" ] || break
    pass=$((pass + 1))
  done
  [ "$tree" = "${prev:-}" ] || best_effort=1
  wip_kv_set "$KDIR/ckpt" last_attempt "$now"
  parent=$(W rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
  if [ -n "$parent" ] && [ "$(W rev-parse "$parent^{tree}")" = "$tree" ]; then
    wip_kv_set "$KDIR/ckpt" best_effort "$best_effort"
    printf 'unchanged %s\n' "$ref"
    return 0
  fi
  head=$(wip_src_git "$REAL_WT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  branch=$(wip_src_git "$REAL_WT" branch --show-current 2>/dev/null || true)
  commit=$(GIT_AUTHOR_NAME=fm-wip GIT_AUTHOR_EMAIL=wip@firstmate.invalid \
    GIT_COMMITTER_NAME=fm-wip GIT_COMMITTER_EMAIL=wip@firstmate.invalid \
    W commit-tree "$tree" ${parent:+-p "$parent"} \
    -m "wip checkpoint branch=${branch:-detached} head=$head milestone=$milestone best_effort=$best_effort") || die "commit failed"
  W update-ref "$ref" "$commit" || die "cannot update $ref"
  wip_kv_set "$KDIR/ckpt" last_checkpoint "$now"
  wip_kv_set "$KDIR/ckpt" tree "$tree"
  wip_kv_set "$KDIR/ckpt" commit "$commit"
  wip_kv_set "$KDIR/ckpt" best_effort "$best_effort"
  [ -n "$(wip_kv_get "$KDIR/ckpt" first_unpublished)" ] || wip_kv_set "$KDIR/ckpt" first_unpublished "$now"
  printf 'checkpoint %s %s\n' "$ref" "$commit"
}

# --- push ---------------------------------------------------------------

# wip_target <project>: prints "<owner>/<name>" from config/wip-remotes.
wip_target() {
  awk -v p="$1" '$1 == p && ($2 == "none" || $2 ~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/) { print $2; exit }' "$CONFIG/wip-remotes" 2>/dev/null
}

# Fresh visibility proof: only an explicit private answer returns 0.
prove_private() {  # <owner/name>
  local out vis
  out=$(fm_run_timed "$CHECK_TIMEOUT" gh-axi repo view "$1" 2>/dev/null) || return 1
  vis=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*visibility:[[:space:]]*//p' | head -n 1 | tr -d '[:space:]"')
  [ "$vis" = private ]
}

# Re-check every commit that has not left yet against the deny list. Each
# candidate tree is loaded into a throwaway index so the full pathspec matcher
# applies, including to empty files.
range_has_deny_hit() {  # <ref> <already-pushed-commit-or-empty>
  local ref=$1 pushed=$2 c specs=() g range idx hit
  load_deny_globs
  for g in ${DENY_GLOBS[@]+"${DENY_GLOBS[@]}"}; do specs+=(":(glob)$g"); done
  [ "${#specs[@]}" -gt 0 ] || return 1
  if [ -n "$pushed" ] && W cat-file -e "$pushed^{commit}" 2>/dev/null; then range="$pushed..$ref"; else range=$ref; fi
  idx="$KDIR/deny-check.index"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    rm -f "$idx"
    GIT_INDEX_FILE=$idx W read-tree "$c" || return 0
    hit=$(GIT_INDEX_FILE=$idx W ls-files -- "${specs[@]}" | head -n 1)
    rm -f "$idx"
    [ -z "$hit" ] || return 0
  done < <(W rev-list "$range")
  return 1
}

action_push() {
  local worktree='' project='' target ref url pushed now lock rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project) project=${2:-}; shift 2 ;;
      -*) usage_error "unknown option: $1" ;;
      *) [ -z "$worktree" ] || usage_error "one worktree only"; worktree=$1; shift ;;
    esac
  done
  [ -n "$worktree" ] && [ -n "$project" ] || usage_error "push needs a worktree and --project"
  resolve_worktree "$worktree"
  now=$(wip_now)
  [ -d "$SHADOW" ] || die "no WIP lineage exists for $REAL_WT yet" 1
  ref=$(wip_kv_get "$KDIR/info" ref)
  [ -n "$ref" ] || die "no WIP checkpoint to publish" 1
  W rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || die "no WIP checkpoint to publish" 1
  case "$ref" in refs/heads/wip/*) ;; *) die "refusing to publish a ref outside refs/heads/wip/" 7 ;; esac
  target=$(wip_target "$project")
  if [ "$target" = none ]; then
    wip_kv_set "$KDIR/push" result off
    die "publication is intentionally off for $project (config/wip-remotes: none)" 8
  fi
  if [ -z "$target" ]; then
    wip_kv_set "$KDIR/push" result no-remote
    die "no WIP remote configured for $project in config/wip-remotes" 4
  fi
  lock="$KDIR/lock"
  fm_lock_try_acquire "$lock" || die "a snapshot or push is running for $REAL_WT" 1
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lock'" EXIT
  if ! prove_private "$target"; then
    wip_kv_set "$KDIR/push" result private-not-proven
    die "private visibility of $target not proven now; publication refused" 5
  fi
  pushed=$(wip_kv_get "$KDIR/push" pushed_commit)
  if range_has_deny_hit "$ref" "$pushed"; then
    wip_kv_set "$KDIR/push" result deny-hit
    die "a commit to publish names a denied path; publication refused" 6
  fi
  url="https://github.com/$target.git"
  rc=0
  fm_run_timed "$CHECK_TIMEOUT" git --git-dir="$SHADOW" push --quiet "$url" "$ref:$ref" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    wip_kv_set "$KDIR/push" result "push-failed-$rc"
    die "push to $target failed or was rejected (rc=$rc); never forced" 7
  fi
  wip_kv_set "$KDIR/push" last_push "$now"
  wip_kv_set "$KDIR/push" last_verified "$now"
  wip_kv_set "$KDIR/push" pushed_commit "$(W rev-parse "$ref")"
  wip_kv_set "$KDIR/push" result pushed
  wip_kv_set "$KDIR/ckpt" first_unpublished ""
  printf 'pushed %s %s\n' "$target" "$ref"
}

case "${1:-}" in
  snapshot) shift; action_snapshot "$@" ;;
  push) shift; action_push "$@" ;;
  '') usage_error "missing action" ;;
  *) usage_error "unknown action: $1" ;;
esac
