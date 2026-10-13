#!/usr/bin/env bash
# Shared inert --help handling for firstmate command scripts.
#
# bin/fm-lock.sh --help, and every other command, must print usage and exit 0
# without taking a lock, writing a file, appending a status line, or contacting
# the network. A script sources this file and calls fm_cli_help "$@" before any
# state change. fm_cli_help returns immediately unless the first argument is -h
# or --help; in that case it prints the calling script's own header comment (its
# "Usage:" block when the header has one, otherwise the whole header, otherwise
# a one-line fallback) and exits 0. It reads only the calling script's source
# and never touches state.
fm_cli_help() {  # [args...]
  local first=${1:-} source usage
  case "$first" in
    -h | --help) ;;
    *)
      return 0
      ;;
  esac
  source=${BASH_SOURCE[1]:-}
  usage=
  if [ -n "$source" ] && [ -f "$source" ]; then
    usage=$(awk '
      NR == 1 { next }
      /^#/ {
        line = $0
        sub(/^# ?/, "", line)
        header[++n] = line
        if (line ~ /^Usage:/) usage_start = n
        next
      }
      { exit }
      END {
        if (usage_start) { for (i = usage_start; i <= n; i++) print header[i] }
        else if (n > 0) print header[1]
      }
    ' "$source" 2>/dev/null)
  fi
  if [ -n "$usage" ]; then
    printf '%s\n' "$usage"
  else
    printf 'usage: %s (see the script header for the full contract)\n' "${source##*/}"
  fi
  exit 0
}
