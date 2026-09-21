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
#       [--card-file <f>] [--task-id <id>] [--nonce <n>] [--dry-run]
#   fm-discord-conversation-console.sh mirror [--config <json>] --text-file <f>
#       --item-key <durable item identity> [--tag captain|main] [--channel <id>] [--dry-run]
#   fm-discord-conversation-console.sh card [--config <json>] --card-file <f>
#       (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
#       [--task-id <id>] [--nonce <n>] [--dry-run]
#   fm-discord-conversation-console.sh card-escalate [--config <json>] [--dry-run]
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
# `mirror` posts one bounded item of a live Pi session's dialog into the
# configured #firstmate channel through this console's own bot identity, so the
# native Pi session mirror needs no second identity. Each item carries a durable
# item key supplied by the caller, and the shared receipt makes the post
# exactly-once across restarts and replays. The channel and the switch live in
# the config (mirror.enabled, mirror.channel_id), never in code, and the whole
# capability is off by default.
#
# `card` posts one captain-facing card with up to five labelled option buttons.
# Each press arrives as a gateway interaction, is answered through Discord's
# interaction callback, and records the captain's choice through the same
# keyed-answer intake a typed reply uses (bin/fm-captain-hold.sh). The card path
# refuses unless the permanent connection is registered, because polling cannot
# receive an interaction, and unless the card's task is still an open captain
# call, so every button on a posted card can validate.
#
# `reply` can carry the card for the interaction it answers: `--card-file` posts
# the card through that same guarded path, in the same conversation, immediately
# after the reply text. The reply text always posts; the card never replaces it.
# A card is posted for a decision, a blocker, a clarification question, a
# projection choice, or a free request, and the card's identity is keyed to the
# reply, so a replayed reply mints no second card.
#
# `card-escalate` runs one bounded escalation pass over open, unanswered cards:
# a card open past the configured delay (cards.escalation_delay_seconds) while
# its task is still an open captain call is mirrored once into the dedicated
# #blocages channel (cards.escalation_channel_id) with the same durable card
# identity and buttons, so a press on either surface resolves the one card. The
# single attempt is recorded on the card whether it lands or not; answered,
# closed, already-escalated, and too-young cards receive none. The
# permanent-connection loop runs the same scan at most once per ten minutes, so
# an unanswered held card is mirrored without any manual step, and a failed or
# undeliverable attempt is recorded as a visible delivery gap rather than
# retried in a loop.
#
# The console also posts one card of its own: an uncertain voice transcription is
# posted as a confirmation card whose three buttons are the existing card actions
# (confirm the reading as heard, correct it in chat, discard it). Its press is
# recorded on the card and on the reading's transcript record, wakes firstmate
# through the same inbox seam, and never touches a captain hold, because an
# uncertain reading is not a held task. Switch: transcription.confirm_card.
#
# start registers the permanent-connection source
# `discord-conversation-console-gateway` when live.gateway is enabled, and the
# bounded REST source `discord-conversation-console` otherwise; stop retires
# both. The watcher reconciles and supervises the registered source, so no
# permanently running agent is created.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_conversation_console_lib.py" tool "$SCRIPT_DIR" "$@"
