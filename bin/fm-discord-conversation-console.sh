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
#   fm-discord-conversation-console.sh connect [--config <json>] [--once] [--max-seconds <n>]
#   fm-discord-conversation-console.sh reply [--config <json>] --text-file <f>
#       (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
#       [--nonce <n>] [--dry-run]
#   fm-discord-conversation-console.sh card [--config <json>] --card-file <f>
#       (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
#       [--nonce <n>] [--dry-run]
#   fm-discord-conversation-console.sh typing [--config <json>] --channel <id>
#       [--interval <n>] [--max-seconds <n>] [--stop]
#   fm-discord-conversation-console.sh status [--config <json>]
#   fm-discord-conversation-console.sh latency [--config <json>] [--limit <n>] [--json]
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
# `card` posts one captain-facing card with up to five labelled option buttons.
# Each press arrives as a gateway interaction, is answered through Discord's
# interaction callback, and records the captain's choice through the same
# keyed-answer intake a typed reply uses (bin/fm-captain-hold.sh). The card path
# refuses unless the permanent connection is registered, because polling cannot
# receive an interaction.
#
# start registers the permanent-connection source
# `discord-conversation-console-gateway` when live.gateway is enabled, and the
# bounded REST source `discord-conversation-console` otherwise; stop retires
# both. The watcher reconciles and supervises the registered source, so no
# permanently running agent is created.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_conversation_console_lib.py" tool "$SCRIPT_DIR" "$@"
