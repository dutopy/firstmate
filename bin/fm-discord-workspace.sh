#!/usr/bin/env bash
# fm-discord-workspace.sh - offline owner for Firstmate's private Discord operations workspace.
#
# This script validates non-secret config, renders setup and health dry-runs,
# plans outbound replies/status/artifacts, records idempotent outbound receipts,
# links Discord-originated requests to tasks, preserves pending final follow-ups,
# and safely refuses live setup, live posting, live health, and destructive
# retirement until a later activation task supplies every required approval.
#
# Usage:
#   fm-discord-workspace.sh sample-config
#   fm-discord-workspace.sh config-check [--config <json>]
#   fm-discord-workspace.sh setup --dry-run [--config <json>]
#   fm-discord-workspace.sh setup --apply [--config <json>]     (refuses in this phase)
#   fm-discord-workspace.sh health [--local|--secrets|--discord|--transcription|--process-event]
#   fm-discord-workspace.sh reply --request-id <discord:guild:channel:message> --text-file <file>
#   fm-discord-workspace.sh status --profile <profile> --text-file <file> [--thread <id>]
#   fm-discord-workspace.sh artifact --profile <profile> --file <path> --purpose <tag> [--request-id <id>]
#   fm-discord-workspace.sh publish-artifact --profile <profile> --file <path> --purpose <tag> --url <https-url> --access <mode>
#   fm-discord-workspace.sh link-task <task-id> --request-id <discord:guild:channel:message>
#   fm-discord-workspace.sh followup <task-id> [--final] --text-file <file>
#   fm-discord-workspace.sh guard-work <task-id>
#   fm-discord-workspace.sh retire [--apply]
#
# The config file is local and non-secret: config/discord-workspace.json by
# default, or --config. It names exactly one operations guild, one Firstmate
# operations bot identity, captain Discord user ids, ProApplis/Folium/ARFAL
# categories, exchanges and artifacts forum ids, thread allowlists, forum tag
# vocabularies, and dry-run-only policy choices. The script never reads .env,
# never decrypts secret values, never contacts Discord or Groq in this phase,
# and never creates categories, channels, threads, tags, bots, permissions, or
# live registrations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_workspace_lib.py" tool "$SCRIPT_DIR" "$@"
