#!/usr/bin/env bash
# fm-discord-session-mirror.sh - Firstmate-side Discord session mirror.
#
# Rebinds this home's live Firstmate sessions to the per-project Discord
# forums: one session thread per live task in the sessions forum of the
# project that task belongs to (title "<project> - <task> - <worktree-name>",
# tags session + worktree + exactly one reconciled state tag), one tagged
# artifact thread per durable deliverable, and the intake that turns a
# captain-created thread or an explicit plain-language request into a session
# bound to that thread.
#
# Usage:
#   fm-discord-session-mirror.sh sample-config
#   fm-discord-session-mirror.sh config-check [--config <json>]
#   fm-discord-session-mirror.sh report [--config <json>] [--task <id>]...
#   fm-discord-session-mirror.sh ensure [--config <json>] [--dry-run]
#   fm-discord-session-mirror.sh sync [--config <json>] [--task <id>]... [--dry-run]
#   fm-discord-session-mirror.sh artifact [--config <json>] --task <id> --kind <report|patch|pr|livrable|rapport|lien|test> --title <t> --body-file <f> [--dry-run]
#   fm-discord-session-mirror.sh request [--config <json>] --thread <id> [--text-file <f>] [--dry-run]
#   fm-discord-session-mirror.sh bind [--config <json>] --thread <id> --task <id> [--dry-run]
#
# The config file is local and non-secret: config/discord-session-mirror.json
# by default, or --config. It owns the project-to-forum mapping, the forum tag
# vocabulary, the reconciled-state-to-tag table, and the refused guilds; none of
# those live in code. Every write is refused unless the config enables
# live.posting, and `report` never contacts Discord at all.
# `ensure` reconciles the live preconditions a webhook transport cannot
# establish for itself - the forum tags the contract requires and one webhook per
# target forum - writes the resulting non-secret ids back to the config, and
# records the exact undo of every live change.
# The bot token follows the existing Firstmate Discord convention: it is
# decrypted from the configured config/*.sops.yaml secret file into process
# memory only, via the same owner as bin/fm-discord-live.sh, and is redacted
# from every failure path.
# Concurrent passes are serialized by the shared Discord state lock.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_discord_session_mirror_lib.py" "$SCRIPT_DIR" "$@"
