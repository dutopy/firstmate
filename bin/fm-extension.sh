#!/usr/bin/env bash
# Tracked shell entrypoint for local and fm-on extension binding commands.

# Inert help: fm_cli_help prints this script's own usage and exits 0 before any
# state change, so --help can never take a lock, write state, or reach the network.
# shellcheck source=bin/fm-cli-lib.sh
fm_cli_dir=${BASH_SOURCE[0]%/*}
[ "$fm_cli_dir" != "${BASH_SOURCE[0]}" ] || fm_cli_dir=.
. "$fm_cli_dir/fm-cli-lib.sh" 2>/dev/null || true
unset fm_cli_dir
if command -v fm_cli_help >/dev/null 2>&1; then fm_cli_help "$@"; fi

set -eu
set -o pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ "${1:-}" = remote-bind ]; then
  [ "$#" -ge 4 ] || { printf 'usage: %s remote-bind <secondmate-id> <package-root> <bind-options...>\n' "$0" >&2; exit 2; }
  route=$2
  package_root=$3
  shift 3
  "$SCRIPT_DIR/fm-extension.mjs" pack-transfer "$package_root" \
    | "$SCRIPT_DIR/fm-on.sh" --stdin "$route" fm-extension.sh receive-transfer-bind "$@"
  exit $?
fi
exec "$SCRIPT_DIR/fm-extension.mjs" "$@"
