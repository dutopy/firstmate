#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# CLOSE HOOK. `done` and its `close` alias are this home's public task-close
# commands, so a launched task's close also owes its copy return. After
# tasks-axi reports the close, this command runs
# bin/fm-teardown.sh <id> --after-close for that task record. That is the only
# cleanup owner: the close stays authoritative and the hook never changes its
# result, never forces, and preserves a dirty, unlanded, reassigned, ambiguous,
# or captain-held copy. Teardown's record, incarnation, ownership, landed-work,
# and recovery-marker guards all still apply, and the hook is skipped for a
# secondmate record and for a close that landed in a backlog other than this
# home's own. A repeated or concurrent close converges: a missing record is a
# no-op and teardown's locks serialize the rest, so cleanup is never repeated.
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

# `done` and its `close` alias are the public task-close commands. A launched
# task's close also owes its copy return; that runs after the close lands, under
# bin/fm-teardown.sh's guards (see close_return_copy below).
CLOSE_COMMAND=
CLOSE_ID=
case "${1:-}" in
  done|close)
    CLOSE_COMMAND=$1
    CLOSE_ID=${2:-}
    ;;
esac

absolute_dir() {  # <path>
  case "$1" in
    ''|/*) printf '%s\n' "$1" ;;
    *) { CDPATH='' cd -- "$1" 2>/dev/null && pwd -P; } || printf '%s\n' "$1" ;;
  esac
}

CLOSE_HOME=$(absolute_dir "$FM_HOME")
CLOSE_DATA=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
CLOSE_STATE=$(absolute_dir "${FM_STATE_OVERRIDE:-$FM_HOME/state}")
CLOSE_CONFIG=$(absolute_dir "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}")
# The close hook pairs cleanup only with this home's own backlog. A guardian
# home or a test may point FM_DATA_OVERRIDE at another directory; that close
# must never tear down a same-id task in this home.
close_owns_this_home_backlog() {
  local home_data
  home_data=$(fm_backlog_data_absolute "$CLOSE_HOME/data") || return 1
  [ "$CLOSE_DATA" = "$home_data" ]
}

close_return_copy() {  # <task-id>
  local id=$1 meta kind
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  meta="$CLOSE_STATE/$id.meta"
  # No task record means no launched endpoint or copy; nothing is owed.
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(LC_ALL=C sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -1)
  # Persistent secondmates are never backlog items, so a close can never retire
  # one. Preserve the home and its children untouched.
  [ "$kind" = secondmate ] && return 0
  if ! close_owns_this_home_backlog; then
    echo "copy: task $id's copy was preserved; its close landed in $CLOSE_DATA, not this home's own backlog" >&2
    return 0
  fi
  echo "copy: task $id closed; running the guarded copy return" >&2
  if FM_HOME="$CLOSE_HOME" FM_STATE_OVERRIDE="$CLOSE_STATE" \
     FM_DATA_OVERRIDE="$CLOSE_DATA" FM_CONFIG_OVERRIDE="$CLOSE_CONFIG" \
     "$SCRIPT_DIR/fm-teardown.sh" "$id" --after-close >&2; then
    echo "copy: task $id's guarded cleanup completed" >&2
  elif [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    echo "copy: task $id's copy was already finished by another close" >&2
  else
    echo "copy: task $id's copy was preserved; the guarded cleanup refused above" >&2
  fi
  return 0
}

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  case "$arg" in
    --help|-h) CLOSE_COMMAND= ;;
  esac
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
# A close lands first and stays authoritative: the guarded copy return runs only
# after tasks-axi reports success, never changes the close result, and never
# forces. A refusal preserves the dirty, unlanded, reassigned, or otherwise
# ambiguous copy for an ordinary teardown or a later close retry.
if [ -n "$CLOSE_COMMAND" ]; then
  tasks-axi ${ARGS[@]+"${ARGS[@]}"}
  close_status=$?
  [ "$close_status" -eq 0 ] || exit "$close_status"
  close_return_copy "$CLOSE_ID"
  exit 0
fi
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
