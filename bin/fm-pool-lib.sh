#!/usr/bin/env bash
# fm-pool-lib.sh - read-only effective Treehouse pool capacity.
#
# Sourced, never executed. This is the single owner for answering, for one
# project: the EFFECTIVE maximum, how many materialized slots are occupied,
# available, or unknown, and whether the pool is saturated. It never allocates,
# returns, prunes, leases, or edits Treehouse state.
#
# The maximum is `max_trees` from the PRIMARY checkout's treehouse.toml, or
# ~/.config/treehouse/config.toml when the repository file is absent, with
# default 16 when neither file exists or the selected file omits the key. The inventory is
# `treehouse status --json` run from the project's top level with
# TREEHOUSE_NO_UPDATE_CHECK=1, so the read never reaches the network.
#
# Status classification:
#   available  - Treehouse reports the slot as available
#   occupied   - in-use, leased, or dirty (the parent pool-saturation metric's
#                "occupied-or-dirty")
#   unknown    - any other status, a malformed entry, or an unreadable read
# Unknown is never folded into available. A discarded, unreadable, malformed,
# or incomplete inventory reports available=unknown rather than available=0.
#
# Saturation is occupancy against the effective maximum, the same ratio the
# pool-watch owner alerts on: >=80% is saturated, and full means no slot is
# available and the materialized count has reached the maximum, so Treehouse
# can neither hand out a copy nor create one.
#
# Output contract, set by fm_treehouse_pool_capacity:
#   FM_POOL_PROJECT       resolved project top level
#   FM_POOL_CONFIG        selected config path (may not exist)
#   FM_POOL_MAX           integer or unknown
#   FM_POOL_OCCUPIED      integer or unknown
#   FM_POOL_AVAILABLE     integer or unknown
#   FM_POOL_UNKNOWN       integer or unknown
#   FM_POOL_ENTRIES       integer or unknown
#   FM_POOL_SATURATION    "<n>%" or unknown
#   FM_POOL_STATE         ok | saturated | full | unknown
#   FM_POOL_DETAIL        bounded reason when an unknown state is not obvious
#   FM_POOL_OBSERVED_AT   UTC timestamp of the status read
#   FM_POOL_READ_SECONDS  whole seconds the read took (monotonic shell clock)
#
# fm_treehouse_pool_capacity returns 0 for a complete inventory (ok, saturated,
# or full) and 1 for unknown, but always leaves every field above set.

FM_POOL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_POOL_LIB_DIR/fm-timeout-lib.sh"

# Treehouse's documented default when neither config exists or the selected
# config omits max_trees (the value `treehouse init` writes).
FM_POOL_DEFAULT_MAX_TREES=16
# A read-only inventory must not hold dispatch open on a wedged provider.
FM_POOL_READ_TIMEOUT=10

fm_pool_utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown\n'
}

fm_pool_capacity_reset() {
  FM_POOL_PROJECT=
  FM_POOL_CONFIG=
  FM_POOL_MAX=unknown
  FM_POOL_OCCUPIED=unknown
  FM_POOL_AVAILABLE=unknown
  FM_POOL_UNKNOWN=unknown
  FM_POOL_ENTRIES=unknown
  FM_POOL_SATURATION=unknown
  FM_POOL_STATE=unknown
  FM_POOL_DETAIL=
  FM_POOL_OBSERVED_AT=
  FM_POOL_READ_SECONDS=0
}

# The config Treehouse reads: the primary checkout root, not a linked
# worktree's own top level (an uncommitted worktree-local treehouse.toml is
# ignored by Treehouse, as verified against v3.1.0). For a primary checkout the
# common git dir is <root>/.git, so its parent is that root.
fm_pool_config_path() {  # <project-dir>
  local project=$1 common root
  [ -d "$project" ] || return 1
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  root=$(dirname "$common")
  [ -n "$root" ] || return 1
  # A linked worktree's common dir is <primary>/.git, whose parent is the
  # primary checkout Treehouse reads. A submodule or an unusual common dir
  # falls back to the checkout's own top level.
  case "$common" in
    */.git) ;;
    *) root=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || return 1 ;;
  esac
  if [ -e "$root/treehouse.toml" ] || [ -L "$root/treehouse.toml" ]; then
    printf '%s/treehouse.toml\n' "$root"
  else
    printf '%s/.config/treehouse/config.toml\n' "$HOME"
  fi
}

# Print the effective integer maximum, or return 1 when the config exists but
# cannot yield one. A missing file or absent key is Treehouse's default.
fm_pool_max_trees() {  # <config-path>
  local config=$1 value
  if [ ! -e "$config" ] && [ ! -L "$config" ]; then
    printf '%s\n' "$FM_POOL_DEFAULT_MAX_TREES"
    return 0
  fi
  if [ ! -f "$config" ] || [ ! -r "$config" ]; then
    return 1
  fi
  if ! value=$(awk -v default="$FM_POOL_DEFAULT_MAX_TREES" -v quote="'" '
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*\[/) { in_table = 1; next }
      if (!in_table && line ~ ("^[[:space:]]*(max_trees|\"max_trees\"|" quote "max_trees" quote ")[[:space:]]*=")) {
        seen++
        sub(/#.*/, "", line)
        sub(/^[^=]*=/, "", line)
        gsub(/[[:space:]]/, "", line)
        value = line
      }
    }
    END {
      if (seen == 0) { print default; exit 0 }
      if (seen > 1) { exit 1 }
      if (value !~ /^\+?[0-9][0-9_]*$/) { exit 1 }
      gsub(/_/, "", value)
      if (value + 0 < 1) { exit 1 }
      print value + 0
    }
  ' "$config" 2>/dev/null); then
    return 1
  fi
  printf '%s\n' "$value"
}

fm_pool_capacity_unknown() {  # <detail>
  FM_POOL_DETAIL=$1
  FM_POOL_STATE=unknown
  [ -n "$FM_POOL_OBSERVED_AT" ] || FM_POOL_OBSERVED_AT=$(fm_pool_utc_now)
  return 1
}

fm_treehouse_pool_capacity() {  # <project-dir>
  local project=$1 top config max status_out status_err status_rc counts
  local entries occupied available unknown started detail part invalid

  fm_pool_capacity_reset
  started=${SECONDS:-0}
  if [ -z "$project" ] || [ ! -d "$project" ]; then
    fm_pool_capacity_unknown "project directory is not readable: ${project:-<empty>}"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi
  if ! top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null); then
    fm_pool_capacity_unknown "not a git repository: $project"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi
  FM_POOL_PROJECT=$top

  config=
  config=$(fm_pool_config_path "$project" 2>/dev/null) || config=
  if [ -n "$config" ]; then
    # shellcheck disable=SC2034 # Output global, read by callers.
    FM_POOL_CONFIG=$config
    if max=$(fm_pool_max_trees "$config" 2>/dev/null); then
      FM_POOL_MAX=$max
    else
      FM_POOL_MAX=unknown
      detail="max_trees is unreadable or invalid in $config"
      FM_POOL_DETAIL=$detail
    fi
  else
    FM_POOL_MAX=unknown
    detail="could not resolve the primary checkout's treehouse.toml for $project"
    FM_POOL_DETAIL=$detail
  fi

  if ! command -v treehouse >/dev/null 2>&1; then
    fm_pool_capacity_unknown "treehouse is not installed${detail:+; $detail}"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    fm_pool_capacity_unknown "jq is required to read treehouse status --json${detail:+; $detail}"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi

  if ! status_err=$(mktemp "${TMPDIR:-/tmp}/fm-pool-status.XXXXXX" 2>/dev/null); then
    fm_pool_capacity_unknown "could not create a temporary file for treehouse status${detail:+; $detail}"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi
  if status_out=$( ( CDPATH='' cd -- "$top" && TREEHOUSE_NO_UPDATE_CHECK=1 \
    fm_run_timed "$FM_POOL_READ_TIMEOUT" treehouse status --json ) 2>"$status_err"); then
    status_rc=0
  else
    status_rc=$?
  fi
  if [ "$status_rc" -ne 0 ]; then
    detail="treehouse status failed (exit $status_rc)"
    if [ -s "$status_err" ]; then
      detail="$detail: $(head -c 200 "$status_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    fi
    rm -f -- "$status_err" 2>/dev/null || true
    fm_pool_capacity_unknown "$detail"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi
  rm -f -- "$status_err" 2>/dev/null || true

  if ! counts=$(printf '%s' "$status_out" | jq -er '
    if type != "array" then error("not an array") else
      reduce .[] as $entry
        ({entries: 0, occupied: 0, available: 0, unknown: 0};
         .entries += 1
         | if ($entry | type) != "object" then .unknown += 1
           elif $entry.status == "available" then .available += 1
           elif ($entry.status == "in-use" or $entry.status == "leased" or $entry.status == "dirty") then .occupied += 1
           else .unknown += 1
           end)
      | "\(.entries) \(.occupied) \(.available) \(.unknown)"
    end
  ' 2>/dev/null); then
    fm_pool_capacity_unknown "treehouse status --json was not a valid slot inventory"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi

  entries='' occupied='' available='' unknown=''
  if ! read -r entries occupied available unknown <<EOF
$counts
EOF
  then
    fm_pool_capacity_unknown "treehouse status --json returned no slot counts"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi
  invalid=0
  for part in "$entries" "$occupied" "$available" "$unknown"; do
    case "$part" in ''|*[!0-9]*) invalid=1 ;; esac
  done
  if [ "$invalid" -eq 0 ] && [ "$entries" -ne $((occupied + available + unknown)) ]; then
    invalid=1
  fi
  if [ "$invalid" -ne 0 ]; then
    fm_pool_capacity_unknown "treehouse status --json returned inconsistent slot counts"
    FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
    return 1
  fi

  FM_POOL_ENTRIES=$entries
  FM_POOL_OCCUPIED=$occupied
  FM_POOL_AVAILABLE=$available
  FM_POOL_UNKNOWN=$unknown
  if [ "$FM_POOL_MAX" != unknown ]; then
    FM_POOL_SATURATION="$((occupied * 100 / FM_POOL_MAX))%"
  fi

  if [ "$FM_POOL_MAX" = unknown ]; then
    fm_pool_capacity_unknown "${FM_POOL_DETAIL:-max_trees is unknown}"
  elif [ "$unknown" -gt 0 ]; then
    fm_pool_capacity_unknown "$unknown slot(s) report an unrecognized status; they are counted as unknown, never available"
  elif [ "$available" -eq 0 ] && [ "$entries" -ge "$FM_POOL_MAX" ]; then
    FM_POOL_STATE=full
  elif [ $((occupied * 100)) -ge $((FM_POOL_MAX * 80)) ]; then
    FM_POOL_STATE=saturated
  else
    FM_POOL_STATE=ok
  fi

  FM_POOL_OBSERVED_AT=$(fm_pool_utc_now)
  FM_POOL_READ_SECONDS=$(( ${SECONDS:-0} - started ))
  [ "$FM_POOL_STATE" != unknown ]
}

fm_pool_capacity_line() {
  printf 'treehouse-pool: project=%s max=%s occupied=%s available=%s unknown=%s entries=%s saturation=%s state=%s observed_at=%s read_s=%s\n' \
    "${FM_POOL_PROJECT:-unknown}" \
    "${FM_POOL_MAX:-unknown}" \
    "${FM_POOL_OCCUPIED:-unknown}" \
    "${FM_POOL_AVAILABLE:-unknown}" \
    "${FM_POOL_UNKNOWN:-unknown}" \
    "${FM_POOL_ENTRIES:-unknown}" \
    "${FM_POOL_SATURATION:-unknown}" \
    "${FM_POOL_STATE:-unknown}" \
    "${FM_POOL_OBSERVED_AT:-unknown}" \
    "${FM_POOL_READ_SECONDS:-unknown}"
}

fm_pool_capacity_action() {
  case "${FM_POOL_STATE:-unknown}" in
    saturated)
      printf '%s\n' 'new copies may wait or fail: close a finished task (bin/fm-teardown.sh <task-id>) or wait for a running task to finish; this read-only check never changes max_trees.'
      ;;
    full)
      printf '%s\n' 'no copy can be handed out: close a finished task (bin/fm-teardown.sh <task-id>) or wait for a running task to finish; this read-only check never changes max_trees.'
      ;;
    unknown)
      printf '%s\n' "pool capacity is unknown, so availability must not be treated as available: ${FM_POOL_DETAIL:-no detail}"
      ;;
  esac
}
