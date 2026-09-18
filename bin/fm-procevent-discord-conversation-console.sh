#!/usr/bin/env bash
# fm-procevent-discord-conversation-console.sh - built-in process-event adapter for the
# Discord conversation console.
#
# Usage:
#   fm-procevent-discord-conversation-console.sh source [--config <json>]
#   fm-procevent-discord-conversation-console.sh classify <result-file>
#   fm-procevent-discord-conversation-console.sh silent <result-file>
#   fm-procevent-discord-conversation-console.sh terminal <result-file>
#   fm-procevent-discord-conversation-console.sh self-announcing
#   fm-procevent-discord-conversation-console.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-discord-conversation-console.sh answers <result-file>
#
# `source` runs one bounded inbound pass: it reads the configured #firstmate
# channels and their threads, hands every accepted captain message to the
# captain inbox through fm-inbox.sh's external-id seam, and records every
# non-captain message as ignored. A successful pass is silent and exits
# nonzero with no output so the runner records no-result and keeps the source
# armed; a genuine failure prints one bounded redacted actionable line as a
# captured result. The adapter declares self-announcing, because accepted
# messages already produce the ordinary captain-inbox notification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_conversation_console_lib.py" procevent "$SCRIPT_DIR" "$@"
