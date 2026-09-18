#!/usr/bin/env bash
# fm-discord-conversation-console.sh - talk to Firstmate from Discord.
#
# Reads captain messages posted in the per-server #firstmate text channels and
# in the threads under them, turns each accepted message into a durable captain
# inbox note through the existing fm-inbox.sh external-id seam, and posts
# Firstmate's answer back into the originating thread (or channel when the
# message had no thread).
#
# Usage:
#   fm-discord-conversation-console.sh sample-config
#   fm-discord-conversation-console.sh config-check [--config <json>]
#   fm-discord-conversation-console.sh listen [--config <json>]
#   fm-discord-conversation-console.sh reply [--config <json>] --text-file <f>
#       (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
#       [--nonce <n>] [--dry-run]
#   fm-discord-conversation-console.sh status [--config <json>]
#   fm-discord-conversation-console.sh start [--config <json>] [--dry-run]
#   fm-discord-conversation-console.sh stop [--config <json>]
#
# The config file is local and non-secret: config/discord-conversation-console.json
# by default, or --config. It names one bot identity, the captain Discord user
# ids, the #firstmate channel of each internal server, and the live polling and
# posting switches. It never stores a token: the bot token is decrypted into
# process memory only through the shared owner in bin/fm_discord_live.py, and no
# token is printed, logged, or written to disk.
#
# start registers the bounded listener as the repository's built-in process-event
# source `discord-conversation-console` and stop retires it; the watcher
# reconciles and supervises it, so no permanently running agent is created.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_conversation_console_lib.py" tool "$SCRIPT_DIR" "$@"
