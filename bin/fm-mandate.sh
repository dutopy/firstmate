#!/usr/bin/env bash
# Own the home's standing-mandate records: time-bounded, scoped authority the
# captain granted for a named set of actions, stored one record per mandate
# under state/mandates/<id>.mandate.
#
# A mandate never creates authority on its own and is never inferred: when no
# mandate is cited, every caller behaves exactly as it did without this script.
# It only lets a caller that relies on a mandate prove, at the moment it acts,
# that the mandate is still in force and covers the act. A cited mandate that is
# missing, malformed, revoked, expired, or out of scope refuses, even when every
# other condition of the act (green CI, passing tests) is met, because meeting
# the conditions is not the same as holding the authority.
#
# Record fields (one key=value per line; list keys repeat):
#   id            mandate id, [A-Za-z0-9][A-Za-z0-9._-]*
#   granted_by    who granted it (the captain, or the relaying home's grantor)
#   created_at    UTC ISO-8601 instant the record was written
#   expires_at    ISO-8601 instant WITH an explicit timezone (Z, +HH:MM, or
#                 +HHMM); the mandate grants nothing at or after this instant
#   action        an allowed action, for example merge or deliver (repeats)
#   repo          repository glob matched against owner/repo or the forge path,
#                 with or without the host prefix (repeats; at least one)
#   branch        base-branch glob (repeats; none means any base branch)
#   allow_path    changed-path glob; when any is present every changed path
#                 must match one (repeats)
#   deny_path     changed-path glob no changed path may match (repeats)
#   condition     free-text condition recorded verbatim and relayed with the
#                 mandate; it is not evaluated here (repeats)
#   relayed_via   optional free text naming the home that relayed the mandate
#   revoked_at    UTC instant of revocation, present only once revoked
#   revoked_by    who revoked it
# Globs are shell case patterns, so `*` also matches `/`: `ui/*` covers every
# path under ui/.
# Expiry is computed from expires_at at every check against the live UTC clock;
# no derived value is stored or trusted.
#
# Usage:
#   fm-mandate.sh grant --id <id> --granted-by <who> --expires-at <iso-with-tz>
#                       --action <action>... --repo <glob>... [--branch <glob>]...
#                       [--allow-path <glob>]... [--deny-path <glob>]...
#                       [--condition <text>]... [--relayed-via <text>]
#   fm-mandate.sh list [--all]
#   fm-mandate.sh show <id>
#   fm-mandate.sh revoke <id> --by <who>
#   fm-mandate.sh check <id> --action <action> --repo <repo-path>
#                       [--host <host>] [--branch <base-branch>]
#                       [--file <path>]... [--files-from <file|->]
#   fm-mandate.sh relay <id> [--send <target>]
#
# grant refuses an existing id, a missing timezone, an unparseable instant, and
# an instant that is not in the future. list prints active mandates (--all adds
# expired and revoked ones) as `<id> <status> expires_at=<iso> actions=<a,b>`.
# check exits 0 printing `mandate <id> in force until <iso>` only when the
# record is in force and covers the action, repository, base branch, and every
# changed path; otherwise it exits 1 with one `refused:` line per failed rule.
# A path rule with no changed-path list supplied refuses, because coverage
# cannot be proven. relay prints a self-contained relay text that always states
# expires_at verbatim, its UTC instant, and the exact grant command the
# receiving home runs to record the identical mandate; it refuses a mandate that
# is not in force. With --send, that text is delivered through bin/fm-send.sh to
# <target>, which requires FM_HOME as fm-send does.
# Exit codes: 0 success, 1 refused or not found, 2 usage error.

# shellcheck source=bin/fm-cli-lib.sh
fm_cli_dir=${BASH_SOURCE[0]%/*}
[ "$fm_cli_dir" != "${BASH_SOURCE[0]}" ] || fm_cli_dir=.
. "$fm_cli_dir/fm-cli-lib.sh" 2>/dev/null || true
unset fm_cli_dir
if command -v fm_cli_help >/dev/null 2>&1; then fm_cli_help "$@"; fi

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_RESOLVED="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME_RESOLVED/state}"
MANDATE_DIR="$STATE/mandates"

usage_error() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

mandate_id_valid() {
  case "$1" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# A value is stored on one line, so a newline would forge another field.
single_line() {
  case "$1" in
    *$'\n'* | *$'\r'*) return 1 ;;
  esac
  return 0
}

# Civil date to days since 1970-01-01 (proleptic Gregorian).
days_from_civil() {  # <y> <m> <d>
  local y=$1 m=$2 d=$3 era yoe doy doe mp
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400))
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then mp=$((m - 3)); else mp=$((m + 9)); fi
  doy=$(((153 * mp + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s\n' $((era * 146097 + doe - 719468))
}

# ISO-8601 instant with an explicit timezone to epoch seconds. Prints nothing and
# returns 1 when the value has no timezone or is not a real instant.
iso_to_epoch() {  # <iso>
  local v=$1 y mo d h mi s tz sign th tm dim
  if [[ "$v" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(:([0-9]{2}))?(Z|[+-][0-9]{2}:?[0-9]{2})$ ]]; then
    y=$((10#${BASH_REMATCH[1]}))
    mo=$((10#${BASH_REMATCH[2]}))
    d=$((10#${BASH_REMATCH[3]}))
    h=$((10#${BASH_REMATCH[4]}))
    mi=$((10#${BASH_REMATCH[5]}))
    s=${BASH_REMATCH[7]:-00}
    s=$((10#$s))
    tz=${BASH_REMATCH[8]}
  else
    return 1
  fi
  [ "$y" -ge 1970 ] && [ "$mo" -ge 1 ] && [ "$mo" -le 12 ] || return 1
  case "$mo" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) dim=31 ;;
    4 | 6 | 9 | 11) dim=30 ;;
    *)
      if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
        dim=29
      else
        dim=28
      fi
      ;;
  esac
  [ "$d" -ge 1 ] && [ "$d" -le "$dim" ] || return 1
  [ "$h" -le 23 ] && [ "$mi" -le 59 ] && [ "$s" -le 59 ] || return 1
  local offset=0
  if [ "$tz" != Z ]; then
    sign=${tz:0:1}
    tz=${tz:1}
    tz=${tz/:/}
    th=$((10#${tz:0:2}))
    tm=$((10#${tz:2:2}))
    [ "$th" -le 23 ] && [ "$tm" -le 59 ] || return 1
    offset=$((th * 3600 + tm * 60))
    [ "$sign" = - ] && offset=$((-offset))
  fi
  printf '%s\n' $(($(days_from_civil "$y" "$mo" "$d") * 86400 + h * 3600 + mi * 60 + s - offset))
}

now_epoch() {
  date -u +%s
}

epoch_to_utc() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '@%s\n' "$1"
}

mandate_path() {
  printf '%s/%s.mandate\n' "$MANDATE_DIR" "$1"
}

# Load one record into M_* variables. Returns 1 when absent, 3 when malformed.
M_ID='' M_GRANTED_BY='' M_EXPIRES_AT='' M_REVOKED_AT='' M_REVOKED_BY=''
M_ACTIONS=() M_REPOS=() M_BRANCHES=() M_ALLOW=() M_DENY=() M_CONDITIONS=()
load_mandate() {  # <id>
  local file line key value
  file=$(mandate_path "$1")
  [ -f "$file" ] || return 1
  M_ID='' M_GRANTED_BY='' M_EXPIRES_AT='' M_REVOKED_AT='' M_REVOKED_BY=''
  M_ACTIONS=() M_REPOS=() M_BRANCHES=() M_ALLOW=() M_DENY=() M_CONDITIONS=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *=*) ;;
      *) return 3 ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      id) M_ID=$value ;;
      granted_by) M_GRANTED_BY=$value ;;
      created_at | relayed_via) ;;  # recorded for show; no check reads them
      expires_at) M_EXPIRES_AT=$value ;;
      revoked_at) M_REVOKED_AT=$value ;;
      revoked_by) M_REVOKED_BY=$value ;;
      action) M_ACTIONS+=("$value") ;;
      repo) M_REPOS+=("$value") ;;
      branch) M_BRANCHES+=("$value") ;;
      allow_path) M_ALLOW+=("$value") ;;
      deny_path) M_DENY+=("$value") ;;
      condition) M_CONDITIONS+=("$value") ;;
      *) return 3 ;;
    esac
  done < "$file"
  [ "$M_ID" = "$1" ] && [ -n "$M_GRANTED_BY" ] && [ -n "$M_EXPIRES_AT" ] \
    && [ "${#M_ACTIONS[@]}" -gt 0 ] && [ "${#M_REPOS[@]}" -gt 0 ] || return 3
  iso_to_epoch "$M_EXPIRES_AT" >/dev/null || return 3
}

load_or_refuse() {  # <id>
  local rc=0
  load_mandate "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) printf 'refused: mandate %s does not exist in %s; no standing authority applies\n' "$1" "$MANDATE_DIR" >&2 ;;
    *) printf 'refused: mandate %s is malformed and grants nothing; ask the captain to grant it again\n' "$1" >&2 ;;
  esac
  exit 1
}

# Prints active, expired, or revoked for the loaded record.
mandate_status() {
  local exp
  if [ -n "$M_REVOKED_AT" ]; then
    printf 'revoked\n'
    return 0
  fi
  exp=$(iso_to_epoch "$M_EXPIRES_AT")
  if [ "$(now_epoch)" -ge "$exp" ]; then
    printf 'expired\n'
  else
    printf 'active\n'
  fi
}

join_csv() {
  local IFS=,
  printf '%s\n' "$*"
}

cmd_grant() {
  local id='' by='' exp='' via='' exp_epoch file tmp v
  local actions=() repos=() branches=() allow=() deny=() conditions=()
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage_error "$1 requires a value"
    v=$2
    single_line "$v" || usage_error "$1 value must be a single line"
    case "$1" in
      --id) id=$v ;;
      --granted-by) by=$v ;;
      --expires-at) exp=$v ;;
      --relayed-via) via=$v ;;
      --action)
        case "$v" in
          '' | [!a-z]* | *[!a-z-]*) usage_error "invalid action: $v" ;;
        esac
        actions+=("$v")
        ;;
      --repo) [ -n "$v" ] || usage_error "--repo must not be empty"; repos+=("$v") ;;
      --branch) [ -n "$v" ] || usage_error "--branch must not be empty"; branches+=("$v") ;;
      --allow-path) [ -n "$v" ] || usage_error "--allow-path must not be empty"; allow+=("$v") ;;
      --deny-path) [ -n "$v" ] || usage_error "--deny-path must not be empty"; deny+=("$v") ;;
      --condition) [ -n "$v" ] || usage_error "--condition must not be empty"; conditions+=("$v") ;;
      *) usage_error "unknown grant option: $1" ;;
    esac
    shift 2
  done
  mandate_id_valid "$id" || usage_error "grant requires a valid --id"
  [ -n "$by" ] || usage_error "grant requires --granted-by"
  [ -n "$exp" ] || usage_error "grant requires --expires-at: a mandate without an expiry is never recorded"
  [ "${#actions[@]}" -gt 0 ] || usage_error "grant requires at least one --action"
  [ "${#repos[@]}" -gt 0 ] || usage_error "grant requires at least one --repo"
  if ! exp_epoch=$(iso_to_epoch "$exp"); then
    usage_error "--expires-at must be an ISO-8601 instant with an explicit timezone, for example 2026-11-01T07:00:00+01:00; got: $exp"
  fi
  if [ "$exp_epoch" -le "$(now_epoch)" ]; then
    printf 'refused: --expires-at %s is not in the future; nothing was recorded\n' "$exp" >&2
    exit 1
  fi
  file=$(mandate_path "$id")
  mkdir -p "$MANDATE_DIR"
  chmod 700 "$MANDATE_DIR" 2>/dev/null || true
  tmp="$MANDATE_DIR/.$id.mandate.$$"
  (
    umask 077
    {
      printf 'id=%s\n' "$id"
      printf 'granted_by=%s\n' "$by"
      printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'expires_at=%s\n' "$exp"
      [ -z "$via" ] || printf 'relayed_via=%s\n' "$via"
      for v in "${actions[@]}"; do printf 'action=%s\n' "$v"; done
      for v in "${repos[@]}"; do printf 'repo=%s\n' "$v"; done
      for v in ${branches[@]+"${branches[@]}"}; do printf 'branch=%s\n' "$v"; done
      for v in ${allow[@]+"${allow[@]}"}; do printf 'allow_path=%s\n' "$v"; done
      for v in ${deny[@]+"${deny[@]}"}; do printf 'deny_path=%s\n' "$v"; done
      for v in ${conditions[@]+"${conditions[@]}"}; do printf 'condition=%s\n' "$v"; done
    } > "$tmp"
  )
  # ln is an exclusive create, so two grants of one id cannot both win.
  if ! ln "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    printf 'refused: mandate %s already exists; revoke it or choose another id\n' "$id" >&2
    exit 1
  fi
  rm -f "$tmp"
  printf 'granted: mandate %s until %s (%s)\n' "$id" "$exp" "$(epoch_to_utc "$exp_epoch")"
}

cmd_list() {
  local all=false file id status
  case "${1:-}" in
    '') ;;
    --all) all=true ;;
    *) usage_error "unknown list option: $1" ;;
  esac
  [ -d "$MANDATE_DIR" ] || return 0
  for file in "$MANDATE_DIR"/*.mandate; do
    [ -f "$file" ] || continue
    id=${file##*/}
    id=${id%.mandate}
    if ! load_mandate "$id"; then
      printf '%s malformed\n' "$id"
      continue
    fi
    status=$(mandate_status)
    [ "$all" = true ] || [ "$status" = active ] || continue
    printf '%s %s expires_at=%s actions=%s\n' "$id" "$status" "$M_EXPIRES_AT" "$(join_csv "${M_ACTIONS[@]}")"
  done
}

cmd_show() {
  if [ "$#" -ne 1 ] || ! mandate_id_valid "$1"; then
    usage_error "show requires one mandate id"
  fi
  load_or_refuse "$1"
  printf 'status=%s\n' "$(mandate_status)"
  cat "$(mandate_path "$1")"
}

cmd_revoke() {
  local id=${1:-} by='' file tmp
  mandate_id_valid "$id" || usage_error "revoke requires a mandate id"
  shift
  [ "${1:-}" = --by ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ] || usage_error "revoke requires --by <who>"
  by=$2
  single_line "$by" || usage_error "--by value must be a single line"
  load_or_refuse "$id"
  if [ -n "$M_REVOKED_AT" ]; then
    printf 'revoked: mandate %s was already revoked at %s\n' "$id" "$M_REVOKED_AT"
    return 0
  fi
  file=$(mandate_path "$id")
  tmp="$MANDATE_DIR/.$id.revoke.$$"
  (
    umask 077
    { cat "$file"; printf 'revoked_at=%s\nrevoked_by=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$by"; } > "$tmp"
  )
  mv -f "$tmp" "$file"
  printf 'revoked: mandate %s\n' "$id"
}

any_glob_matches() {  # <value> <glob>...
  local value=$1 pat
  shift
  for pat in "$@"; do
    # shellcheck disable=SC2254
    case "$value" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

cmd_check() {
  local id=${1:-} action='' repo='' host='' branch='' files_from='' path line
  local files=() refusals=() status exp now
  mandate_id_valid "$id" || usage_error "check requires a mandate id"
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage_error "$1 requires a value"
    case "$1" in
      --action) action=$2 ;;
      --repo) repo=$2 ;;
      --host) host=$2 ;;
      --branch) branch=$2 ;;
      --file) files+=("$2") ;;
      --files-from) files_from=$2 ;;
      *) usage_error "unknown check option: $1" ;;
    esac
    shift 2
  done
  [ -n "$action" ] || usage_error "check requires --action"
  [ -n "$repo" ] || usage_error "check requires --repo"
  if [ -n "$files_from" ]; then
    [ "$files_from" = - ] || [ -r "$files_from" ] || usage_error "cannot read --files-from $files_from"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] || files+=("$line")
    done < <(if [ "$files_from" = - ]; then cat; else cat "$files_from"; fi)
  fi
  load_or_refuse "$id"
  status=$(mandate_status)
  now=$(now_epoch)
  exp=$(iso_to_epoch "$M_EXPIRES_AT")
  case "$status" in
    revoked)
      refusals+=("mandate $id was revoked at $M_REVOKED_AT by $M_REVOKED_BY")
      ;;
    expired)
      refusals+=("mandate $id expired at $M_EXPIRES_AT ($(epoch_to_utc "$exp")); it is now $(epoch_to_utc "$now"), so its authority has lapsed even if its conditions still hold")
      ;;
  esac
  any_glob_matches "$action" "${M_ACTIONS[@]}" \
    || refusals+=("action $action is not allowed by mandate $id (allowed: $(join_csv "${M_ACTIONS[@]}"))")
  if ! any_glob_matches "$repo" "${M_REPOS[@]}" \
    && { [ -z "$host" ] || ! any_glob_matches "$host/$repo" "${M_REPOS[@]}"; }; then
    refusals+=("repository $repo is outside mandate $id (scope: $(join_csv "${M_REPOS[@]}"))")
  fi
  if [ "${#M_BRANCHES[@]}" -gt 0 ]; then
    if [ -z "$branch" ]; then
      refusals+=("mandate $id limits base branches but no base branch was supplied")
    elif ! any_glob_matches "$branch" "${M_BRANCHES[@]}"; then
      refusals+=("base branch $branch is outside mandate $id (scope: $(join_csv "${M_BRANCHES[@]}"))")
    fi
  fi
  if [ "${#M_ALLOW[@]}" -gt 0 ] || [ "${#M_DENY[@]}" -gt 0 ]; then
    if [ "${#files[@]}" -eq 0 ]; then
      refusals+=("mandate $id has path rules but no changed-path list was supplied, so coverage cannot be proven")
    fi
    for path in ${files[@]+"${files[@]}"}; do
      if [ "${#M_DENY[@]}" -gt 0 ] && any_glob_matches "$path" "${M_DENY[@]}"; then
        refusals+=("changed path $path is excluded by mandate $id (deny: $(join_csv "${M_DENY[@]}"))")
      elif [ "${#M_ALLOW[@]}" -gt 0 ] && ! any_glob_matches "$path" "${M_ALLOW[@]}"; then
        refusals+=("changed path $path is outside mandate $id (allow: $(join_csv "${M_ALLOW[@]}"))")
      fi
    done
  fi
  if [ "${#refusals[@]}" -gt 0 ]; then
    for line in "${refusals[@]}"; do
      printf 'refused: %s\n' "$line" >&2
    done
    exit 1
  fi
  printf 'mandate %s in force until %s (%s)\n' "$id" "$M_EXPIRES_AT" "$(epoch_to_utc "$exp")"
}

relay_text() {
  local v cmd home
  home=${FM_HOME_RESOLVED##*/}
  cmd="bin/fm-mandate.sh grant --id $(printf '%q' "$M_ID") --granted-by $(printf '%q' "$M_GRANTED_BY") --expires-at $(printf '%q' "$M_EXPIRES_AT")"
  for v in "${M_ACTIONS[@]}"; do cmd="$cmd --action $(printf '%q' "$v")"; done
  for v in "${M_REPOS[@]}"; do cmd="$cmd --repo $(printf '%q' "$v")"; done
  for v in ${M_BRANCHES[@]+"${M_BRANCHES[@]}"}; do cmd="$cmd --branch $(printf '%q' "$v")"; done
  for v in ${M_ALLOW[@]+"${M_ALLOW[@]}"}; do cmd="$cmd --allow-path $(printf '%q' "$v")"; done
  for v in ${M_DENY[@]+"${M_DENY[@]}"}; do cmd="$cmd --deny-path $(printf '%q' "$v")"; done
  for v in ${M_CONDITIONS[@]+"${M_CONDITIONS[@]}"}; do cmd="$cmd --condition $(printf '%q' "$v")"; done
  cmd="$cmd --relayed-via $(printf '%q' "$home")"
  printf 'Standing mandate %s, granted by %s.\n' "$M_ID" "$M_GRANTED_BY"
  printf 'expires_at: %s (%s). At and after that instant it grants nothing, even if every condition still holds.\n' \
    "$M_EXPIRES_AT" "$(epoch_to_utc "$(iso_to_epoch "$M_EXPIRES_AT")")"
  printf 'actions: %s\n' "$(join_csv "${M_ACTIONS[@]}")"
  printf 'repositories: %s\n' "$(join_csv "${M_REPOS[@]}")"
  [ "${#M_BRANCHES[@]}" -eq 0 ] || printf 'base branches: %s\n' "$(join_csv "${M_BRANCHES[@]}")"
  [ "${#M_ALLOW[@]}" -eq 0 ] || printf 'only these paths: %s\n' "$(join_csv "${M_ALLOW[@]}")"
  [ "${#M_DENY[@]}" -eq 0 ] || printf 'never these paths: %s\n' "$(join_csv "${M_DENY[@]}")"
  for v in ${M_CONDITIONS[@]+"${M_CONDITIONS[@]}"}; do printf 'condition: %s\n' "$v"; done
  printf 'Record it in your own home before relying on it:\n  %s\n' "$cmd"
  printf 'Cite it on every merge that relies on it: bin/fm-pr-merge.sh <task-id> <pr-url> --mandate %s\n' "$M_ID"
}

cmd_relay() {
  local id=${1:-} target='' text status
  mandate_id_valid "$id" || usage_error "relay requires a mandate id"
  shift
  if [ "$#" -gt 0 ]; then
    [ "$1" = --send ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ] || usage_error "relay accepts only --send <target>"
    target=$2
  fi
  load_or_refuse "$id"
  status=$(mandate_status)
  if [ "$status" != active ]; then
    printf 'refused: mandate %s is %s and cannot be relayed\n' "$id" "$status" >&2
    exit 1
  fi
  text=$(relay_text)
  if [ -z "$target" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  "$SCRIPT_DIR/fm-send.sh" "$target" "$text"
}

case "${1:-}" in
  grant) shift; cmd_grant "$@" ;;
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  revoke) shift; cmd_revoke "$@" ;;
  check) shift; cmd_check "$@" ;;
  relay) shift; cmd_relay "$@" ;;
  *) usage_error "expected grant, list, show, revoke, check, or relay" ;;
esac
