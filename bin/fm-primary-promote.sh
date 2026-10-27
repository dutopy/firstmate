#!/usr/bin/env bash
# Permit this home's next supervision-lock acquisition after manual failback.
#
# Usage: FM_HOME=/path/to/home bin/fm-primary-promote.sh --confirm-other-primary-stopped
#        bin/fm-primary-promote.sh --help
#
# Before promotion, the operator must stop or fence the other primary and verify
# that it cannot restart. The confirmation flag records that operator assertion;
# this command does not inspect, stop, fence or contact the other machine.
# From an iPhone, run the same command through the existing authenticated SSH
# connection to the standby machine. No new listener or credential is needed.
#
# Standby is an operator-installed config/manual-promotion-required marker under
# FM_HOME (FM_CONFIG_OVERRIDE selects another config directory). To prepare an
# INACTIVE home, create its config directory and an empty regular marker file.
# Installing standby is a separate operator action, not a live authority change
# performed by this command. Without the marker, ordinary homes are unchanged.
#
# Explicit promotion removes only that regular marker; repeating it when absent
# succeeds without writing anything. Symlinks and other non-regular markers are
# refused. A failed removal leaves acquisition forbidden while the marker exists.
# Promotion never writes state/.lock, steals a live local lock, starts a parent,
# schedules a retry or reacts to lease expiry. Existing running sessions are not
# revoked by installing a marker; use it only on an inactive home.
#
# Home resolution follows FM_HOME, then FM_ROOT_OVERRIDE, then this code root.
# The marker's age and contents do not authorize promotion. Exit 0 means admission
# is open locally, not that another primary is fenced or a new parent is running.
# Exit 1 reports an unsafe marker or removal failure; exit 2 reports missing or
# unexpected confirmation arguments. --help is inert and exits 0.

# shellcheck source=bin/fm-cli-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-cli-lib.sh"
fm_cli_help "$@"
set -u

if [ "$#" -ne 1 ] || [ "${1:-}" != --confirm-other-primary-stopped ]; then
  echo "error: require exactly --confirm-other-primary-stopped after verifying the other primary cannot run; see --help" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MARKER="$CONFIG/manual-promotion-required"

if [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ]; then
  echo "local admission already open; no parent started or remote fencing verified"
  exit 0
fi
if [ ! -f "$MARKER" ] || [ -L "$MARKER" ]; then
  printf 'error: standby marker is not a regular file: %s; keep this home inactive\n' "$MARKER" >&2
  exit 1
fi
if ! rm -- "$MARKER"; then
  printf 'error: cannot remove standby marker: %s; keep this home inactive\n' "$MARKER" >&2
  exit 1
fi
if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
  printf 'error: standby marker remains: %s; keep this home inactive\n' "$MARKER" >&2
  exit 1
fi
echo "local manual promotion complete; no parent started or remote fencing verified"
