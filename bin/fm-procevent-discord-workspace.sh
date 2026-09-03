#!/usr/bin/env bash
# fm-procevent-discord-workspace.sh - built-in process-event adapter for Discord workspace intake.
#
# Usage:
#   fm-procevent-discord-workspace.sh arm [--dry-run] [--config <json>]
#   fm-procevent-discord-workspace.sh source [--config <json>]
#   fm-procevent-discord-workspace.sh classify <result-file>
#   fm-procevent-discord-workspace.sh silent <result-file>
#   fm-procevent-discord-workspace.sh terminal <result-file>
#   fm-procevent-discord-workspace.sh self-announcing
#   fm-procevent-discord-workspace.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-discord-workspace.sh answers <result-file>
#
# The adapter is deliberately inert for live services in this phase. `arm`
# renders a dry-run registration plan and every non-dry-run arm refuses until a
# later activation task supplies live approval. `source` reads only an offline
# fixture named by FM_DISCORD_WORKSPACE_FIXTURE or poll.fixture_file; without one
# it refuses before any network call. Accepted forum-post/thread messages are
# normalized into one durable fm-inbox note through fm-inbox.sh's external-id
# idempotency seam. Ignored messages are marked handled without a wake, and the
# adapter declares self-announcing so an accepted message produces only the
# ordinary captain-inbox notification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_workspace_lib.py" procevent "$SCRIPT_DIR" "$@"
