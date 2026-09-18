#!/usr/bin/env python3
"""Discord conversation console for Firstmate.

Reads captain messages posted in the per-server ``#firstmate`` text channels and
in the threads under them, turns each accepted message into a durable
captain-inbox note through the existing ``fm-inbox.sh note`` external-id seam,
and posts Firstmate's answer back into the conversation thread it came from.

One conversation is one thread: a message in a thread keeps its thread identity
in the durable inbox metadata, so a reply returns to that exact thread and two
parallel conversations never cross. Only configured captain Discord user ids are
accepted; every other message is ignored and recorded as ignored, never silently
dropped.

The bot token is decrypted into process memory only through the shared owner in
``bin/fm_discord_live.py``; it is never printed, logged, or written to disk, and
every failure path is redacted. Live reads and writes stay disabled unless the
config enables ``live.polling`` and ``live.posting``.

The console has two inbound transports that feed the same durable capture path:
a permanent Discord gateway connection (``live.gateway``) that makes the bot
appear online and delivers each captain message the moment it is posted, and the
original bounded REST polling pass. The gateway connection is a supervised
process-event source with an internal bounded-exponential reconnect and a
polling fallback, so it is a transport, never an LLM agent.

Usage (via bin/fm-discord-conversation-console.sh):
    fm-discord-conversation-console.sh sample-config
    fm-discord-conversation-console.sh config-check [--config <json>]
    fm-discord-conversation-console.sh listen [--config <json>]
    fm-discord-conversation-console.sh connect [--config <json>] [--once] [--max-seconds <n>]
    fm-discord-conversation-console.sh reply [--config <json>] --text-file <f>
        (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
        [--nonce <n>] [--dry-run]
    fm-discord-conversation-console.sh status [--config <json>]
    fm-discord-conversation-console.sh start [--config <json>] [--dry-run]
    fm-discord-conversation-console.sh stop [--config <json>]

``start`` registers the permanent-connection source
``discord-conversation-console-gateway`` when ``live.gateway`` is enabled, and
the bounded REST source ``discord-conversation-console`` otherwise; ``stop``
retires both. The watcher reconciles and supervises the registered source, so a
lost gateway connection is re-established and a crashed listener is relaunched
without a permanently running LLM agent.

Test seams: FM_DISCORD_LIVE_API_BASE and FM_DISCORD_LIVE_SOPS are owned by
bin/fm_discord_live.py. FM_DISCORD_LIVE_GATEWAY_URL overrides the gateway URL,
and FM_DISCORD_GATEWAY_BACKOFF_BASE, FM_DISCORD_GATEWAY_BACKOFF_MAX, and
FM_DISCORD_GATEWAY_FALLBACK_POLL bound the reconnect and fallback cadence.
Neither changes what is redacted.
"""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("fwl", SCRIPT_DIR / "fm_discord_workspace_lib.py")
fwl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fwl)

_live_spec = importlib.util.spec_from_file_location("fm_discord_live", SCRIPT_DIR / "fm_discord_live.py")
live = importlib.util.module_from_spec(_live_spec)
_live_spec.loader.exec_module(live)

FMError = fwl.FMError

SCHEMA = "fm-discord-conversation-console.config.v1"
EVENT_SCHEMA = "fm-discord-conversation-console.event.v1"
IGNORED_SCHEMA = "fm-discord-conversation-console.ignored.v1"
THREAD_SCHEMA = "fm-discord-conversation-console.thread.v1"
LAST_PASS_SCHEMA = "fm-discord-conversation-console.last-pass.v1"
CONNECTION_SCHEMA = "fm-discord-conversation-console.connection.v1"
SOURCE_ID = "discord-conversation-console"
GATEWAY_SOURCE_ID = "discord-conversation-console-gateway"
ADAPTER = "discord-conversation-console"
CONSOLE_STATE_SUBDIR = "conversation-console"
INBOX_SOURCE = "discord"

DEFAULT_MAX_MESSAGES = 100
DEFAULT_MAX_THREADS = 100
DEFAULT_MAX_IGNORED = 500

# The permanent Discord gateway connection. The default intent bitfield is
# GUILDS (1) | GUILD_MESSAGES (512) | MESSAGE_CONTENT (32768); the captain has
# enabled the privileged Message Content intent, so a message's text arrives
# with the dispatch instead of needing a REST read.
DEFAULT_GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"
DEFAULT_GATEWAY_INTENTS = 33281
DEFAULT_BACKOFF_BASE_SECONDS = 2.0
DEFAULT_BACKOFF_MAX_SECONDS = 60.0
DEFAULT_FALLBACK_POLL_SECONDS = 20.0
DEFAULT_FALLBACK_AFTER_ATTEMPTS = 3
GATEWAY_CONNECT_TIMEOUT_SECONDS = 20.0
# A READY payload for a large guild can be several megabytes; this only bounds a
# malformed or hostile frame, never a legitimate dispatch.
MAX_GATEWAY_FRAME_BYTES = 64 * 1024 * 1024
GATEWAY_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# Discord thread channel types whose parent is the configured #firstmate channel.
THREAD_CHANNEL_TYPES = (10, 11, 12)

# Same operational-text refusal the rest of the Discord tooling applies: a
# firstmate answer is captain-facing prose, never supervision machinery.
REFUSED_MARKERS = ("FIRSTMATE WATCHER WAKE", "FIRSTMATE_OP:", "\u2063", "\u26f5")


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def default_config_path(env: "fwl.Env") -> Path:
    return env.config / "discord-conversation-console.json"


def validate_gateway_intents(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise FMError("gateway.intents must be a positive JSON integer bitfield")
    if value > 0x7FFFFFFF:
        raise FMError("gateway.intents is outside the Discord intent bitfield range")
    return value


def env_float(name: str, value: Any, field: str) -> float:
    """Resolve one positive float, with an env var test seam taking precedence."""
    override = os.environ.get(name)
    if override is not None:
        try:
            parsed = float(override)
        except ValueError as exc:
            raise FMError(f"{name} must be a number") from exc
        if parsed <= 0:
            raise FMError(f"{name} must be positive")
        return parsed
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        raise FMError(f"{field} must be a positive number")
    return float(value)


class ConsoleChannel:
    def __init__(self, raw: Dict[str, Any], index: int):
        label = raw.get("label")
        self.label = label.strip() if isinstance(label, str) and label.strip() else f"channel-{index}"
        self.guild_id = fwl.validate_snowflake(raw.get("guild_id"), f"channels[{index}].guild_id") or ""
        self.channel_id = fwl.validate_snowflake(raw.get("channel_id"), f"channels[{index}].channel_id") or ""


class ConsoleConfig:
    def __init__(self, path: Path, raw: Dict[str, Any], home: Path):
        self.path = path
        self.raw = raw
        fwl.reject_inline_secret_values(raw)
        fwl.validate_secret_reference_fields(raw, home)
        schema = raw.get("schema", SCHEMA)
        if schema != SCHEMA:
            raise FMError(f"unsupported config schema: {schema}")
        secret_file = raw.get("secret_file")
        if not isinstance(secret_file, str) or not secret_file:
            raise FMError("secret_file must name the Discord sops secret file under config/")
        self.secret_file = secret_file
        token_key = raw.get("discord_bot_token_key")
        if not isinstance(token_key, str) or not fwl.SECRET_REFERENCE_RE.fullmatch(token_key):
            raise FMError("discord_bot_token_key must be an uppercase secret reference name")
        self.token_key = token_key
        bot = raw.get("bot") if isinstance(raw.get("bot"), dict) else {}
        self.bot_user_id = fwl.validate_snowflake(raw.get("bot_user_id") or bot.get("user_id"), "bot.user_id") or ""
        self.captain_user_ids: List[str] = []
        for user_id in fwl.as_list(raw.get("captain_user_ids"), "captain_user_ids"):
            sid = fwl.validate_snowflake(user_id, "captain_user_ids[]")
            assert sid is not None
            if sid == self.bot_user_id:
                raise FMError("captain_user_ids must not include the bot user id")
            self.captain_user_ids.append(sid)
        if not self.captain_user_ids:
            raise FMError("captain_user_ids must contain at least one captain Discord user id")
        raw_channels = fwl.as_list(raw.get("channels"), "channels")
        if not raw_channels:
            raise FMError("channels must contain at least one #firstmate channel")
        self.channels: List[ConsoleChannel] = []
        seen_channels = set()
        seen_guilds = set()
        for index, item in enumerate(raw_channels):
            if not isinstance(item, dict):
                raise FMError(f"channels[{index}] must be a JSON object")
            channel = ConsoleChannel(item, index)
            if channel.channel_id in seen_channels:
                raise FMError(f"channels contains duplicate channel id: {channel.channel_id}")
            seen_channels.add(channel.channel_id)
            seen_guilds.add(channel.guild_id)
            self.channels.append(channel)
        self.guild_ids = sorted(seen_guilds)
        bounds = raw.get("bounds") if isinstance(raw.get("bounds"), dict) else {}
        self.max_messages = fwl.validate_positive_json_integer(
            bounds.get("max_messages_per_channel", DEFAULT_MAX_MESSAGES),
            "bounds.max_messages_per_channel",
            100,
        )
        self.max_threads = fwl.validate_positive_json_integer(
            bounds.get("max_threads_per_pass", DEFAULT_MAX_THREADS),
            "bounds.max_threads_per_pass",
            200,
        )
        self.max_ignored = fwl.validate_positive_json_integer(
            bounds.get("max_ignored_records", DEFAULT_MAX_IGNORED),
            "bounds.max_ignored_records",
            5000,
        )
        self.live_polling_enabled = fwl.bool_from_path(raw, ["live.polling", "approvals.live_polling", "live_polling"], False)
        self.live_posting_enabled = fwl.bool_from_path(raw, ["live.posting", "approvals.live_posting", "live_posting"], False)
        self.live_gateway_enabled = fwl.bool_from_path(raw, ["live.gateway", "approvals.live_gateway", "live_gateway"], False)
        gateway = raw.get("gateway") if isinstance(raw.get("gateway"), dict) else {}
        configured_url = gateway.get("url") if isinstance(gateway.get("url"), str) else ""
        self.gateway_url = os.environ.get("FM_DISCORD_LIVE_GATEWAY_URL") or configured_url.strip() or DEFAULT_GATEWAY_URL
        self.gateway_intents = validate_gateway_intents(gateway.get("intents", DEFAULT_GATEWAY_INTENTS))
        self.gateway_backoff_base = env_float(
            "FM_DISCORD_GATEWAY_BACKOFF_BASE",
            gateway.get("backoff_base_seconds", DEFAULT_BACKOFF_BASE_SECONDS),
            "gateway.backoff_base_seconds",
        )
        self.gateway_backoff_max = env_float(
            "FM_DISCORD_GATEWAY_BACKOFF_MAX",
            gateway.get("backoff_max_seconds", DEFAULT_BACKOFF_MAX_SECONDS),
            "gateway.backoff_max_seconds",
        )
        self.gateway_fallback_poll_seconds = env_float(
            "FM_DISCORD_GATEWAY_FALLBACK_POLL",
            gateway.get("fallback_poll_seconds", DEFAULT_FALLBACK_POLL_SECONDS),
            "gateway.fallback_poll_seconds",
        )
        self.gateway_fallback_after_attempts = fwl.validate_positive_json_integer(
            gateway.get("fallback_after_attempts", DEFAULT_FALLBACK_AFTER_ATTEMPTS),
            "gateway.fallback_after_attempts",
            100,
        )
        if self.gateway_backoff_max < self.gateway_backoff_base:
            raise FMError("gateway.backoff_max_seconds must be at least gateway.backoff_base_seconds")

    @classmethod
    def load(cls, env: "fwl.Env", path_text: Optional[str]) -> "ConsoleConfig":
        path = Path(path_text).expanduser() if path_text else default_config_path(env)
        if not path.is_absolute():
            path = (Path.cwd() / path).resolve()
        raw = fwl.read_json(path)
        return cls(path.resolve(), raw, env.home)

    def channel_for_id(self, channel_id: str) -> Optional[ConsoleChannel]:
        for channel in self.channels:
            if channel.channel_id == channel_id:
                return channel
        return None


def sample_config() -> Dict[str, Any]:
    return {
        "schema": SCHEMA,
        "secret_file": "config/discord-workspace.secrets.sops.yaml",
        "discord_bot_token_key": "FIRSTMATE_DISCORD_BOT_TOKEN",
        "bot": {"user_id": "222222222222222222"},
        "captain_user_ids": ["333333333333333333"],
        "channels": [
            {"label": "Internal server A", "guild_id": "111111111111111111", "channel_id": "444444444444444441"},
            {"label": "Internal server B", "guild_id": "111111111111111112", "channel_id": "444444444444444442"},
        ],
        "live": {"polling": False, "posting": False, "gateway": False},
        "gateway": {
            "url": DEFAULT_GATEWAY_URL,
            "intents": DEFAULT_GATEWAY_INTENTS,
            "backoff_base_seconds": DEFAULT_BACKOFF_BASE_SECONDS,
            "backoff_max_seconds": DEFAULT_BACKOFF_MAX_SECONDS,
            "fallback_poll_seconds": DEFAULT_FALLBACK_POLL_SECONDS,
            "fallback_after_attempts": DEFAULT_FALLBACK_AFTER_ATTEMPTS,
        },
        "bounds": {
            "max_messages_per_channel": DEFAULT_MAX_MESSAGES,
            "max_threads_per_pass": DEFAULT_MAX_THREADS,
            "max_ignored_records": DEFAULT_MAX_IGNORED,
        },
    }


# ---------------------------------------------------------------------------
# State paths
# ---------------------------------------------------------------------------

def console_state_path(env: "fwl.Env", *parts: str) -> Path:
    return fwl.discord_state_path(env, CONSOLE_STATE_SUBDIR, *parts)


def cursor_path(env: "fwl.Env", channel_id: str) -> Path:
    return console_state_path(env, "cursors", f"{channel_id}.cursor")


def thread_record_path(env: "fwl.Env", thread_id: str) -> Path:
    return console_state_path(env, "threads", f"{thread_id}.json")


def ignored_path(env: "fwl.Env") -> Path:
    return console_state_path(env, "ignored.json")


def last_pass_path(env: "fwl.Env") -> Path:
    return console_state_path(env, "last-pass.json")


def connection_path(env: "fwl.Env") -> Path:
    return console_state_path(env, "connection.json")


def read_connection(env: "fwl.Env") -> Optional[Dict[str, Any]]:
    try:
        record = fwl.load_existing_json(connection_path(env))
    except FMError:
        return None
    return record if isinstance(record, dict) else None


def write_connection(env: "fwl.Env", mode: str, state: str, since: str, attempts: int, error: str, url: str) -> None:
    record = {
        "schema": CONNECTION_SCHEMA,
        "mode": mode,
        "state": state,
        "since": since,
        "updated_at": fwl.utc_now(),
        "attempts": attempts,
        "error": error,
        "url": url,
    }
    with fwl.state_transaction(env):
        fwl.atomic_json(connection_path(env), record)


def record_connection_state(env: "fwl.Env", mode: str, state: str, error: str = "", attempts: int = 0, url: str = "") -> None:
    """Publish the connection mode and health, preserving a settled `since`."""
    current = read_connection(env)
    since = fwl.utc_now()
    if isinstance(current, dict) and current.get("mode") == mode and current.get("state") == state and current.get("since"):
        since = str(current["since"])
    write_connection(env, mode, state, since, attempts, error[-500:], url)


def gateway_host_label(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    host = parts.hostname or ""
    if not host:
        return ""
    return f"{parts.scheme}://{host}"


def atomic_text(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def read_cursor(env: "fwl.Env", channel_id: str) -> int:
    path = cursor_path(env, channel_id)
    if not path.exists():
        return 0
    if path.is_symlink() or not path.is_file():
        raise FMError(f"refusing unsafe cursor path: {path}")
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return 0
    if not text.isdigit():
        raise FMError(f"cursor is not a numeric Discord message id: {path}")
    return int(text)


def load_thread_record(env: "fwl.Env", thread_id: str) -> Optional[Dict[str, Any]]:
    path = thread_record_path(env, thread_id)
    try:
        return fwl.load_existing_json(path)
    except FMError:
        raise FMError(f"recorded conversation thread is malformed: {path}")


# ---------------------------------------------------------------------------
# Message normalization and inbox handoff
# ---------------------------------------------------------------------------

def normalize_message(
    cfg: "ConsoleConfig",
    channel: ConsoleChannel,
    channel_id: str,
    parent_id: str,
    message: Dict[str, Any],
) -> Dict[str, Any]:
    """Classify one Discord message into an accepted text event or an ignored event."""
    guild_id = channel.guild_id
    message_id = str(message.get("id") or "")
    author = message.get("author") if isinstance(message.get("author"), dict) else {}
    author_id = str(author.get("id") or message.get("author_id") or "")
    is_bot = bool(author.get("bot") or message.get("author_is_bot"))
    base = {
        "schema": EVENT_SCHEMA,
        "source": INBOX_SOURCE,
        "label": channel.label,
        "guild_id": guild_id,
        "channel_id": channel_id,
        "parent_id": parent_id,
        "thread_id": channel_id if parent_id else "",
        "message_id": message_id,
        "author_id": author_id,
        "external_id": message_id,
        "request_id": request_id_for(guild_id, channel_id, message_id) if message_id.isdigit() else "",
        "jump_url": f"https://discord.com/channels/{guild_id}/{channel_id}/{message_id}",
        "timestamp": str(message.get("timestamp") or ""),
    }
    if not fwl.ID_RE.fullmatch(message_id):
        return ignored_event(base, "invalid-message-id")
    if not author_id:
        return ignored_event(base, "missing-author")
    if is_bot or author_id == cfg.bot_user_id:
        return ignored_event(base, "bot-author")
    if author_id not in cfg.captain_user_ids:
        return ignored_event(base, "unknown-author")
    content_value = message.get("content", "")
    if "content" in message and not isinstance(content_value, str):
        return ignored_event(base, "invalid-content")
    content = content_value.strip() if isinstance(content_value, str) else ""
    if not content:
        return ignored_event(base, "empty-message")
    event = dict(base)
    event["kind"] = "text"
    event["content"] = content
    return event


def ignored_event(base: Dict[str, Any], reason: str) -> Dict[str, Any]:
    event = dict(base)
    event["kind"] = "ignored"
    event["reason"] = reason
    return event


def request_id_for(guild_id: str, channel_id: str, message_id: str) -> str:
    return f"discord:{guild_id}:{channel_id}:{message_id}"


def event_metadata(event: Dict[str, Any]) -> Dict[str, Any]:
    allowed = [
        "schema", "source", "kind", "label", "guild_id", "channel_id", "parent_id",
        "thread_id", "message_id", "author_id", "external_id", "request_id", "jump_url", "timestamp",
    ]
    return {key: event[key] for key in allowed if key in event}


def note_body(event: Dict[str, Any]) -> str:
    lines = [f"Discord conversation / {event.get('label')}"]
    lines.append(f"request: {event.get('request_id')}")
    if event.get("thread_id"):
        lines.append(f"conversation: thread {event.get('thread_id')} under #firstmate {event.get('parent_id')}")
    else:
        lines.append(f"conversation: channel {event.get('channel_id')}")
    lines.append(f"from: {event.get('author_id')}")
    if event.get("jump_url"):
        lines.append(f"link: {event.get('jump_url')}")
    lines.append("")
    lines.append(str(event.get("content") or ""))
    lines.append("")
    lines.append(
        "answer with: bin/fm-discord-conversation-console.sh reply --request-id "
        f"{event.get('request_id')} --text-file <answer-file>"
    )
    return "\n".join(lines).rstrip() + "\n"


def handoff_event(env: "fwl.Env", event: Dict[str, Any]) -> None:
    """Feed one accepted event through the existing external-id inbox seam."""
    body = note_body(event)
    metadata_dir = console_state_path(env, "metadata-staging")
    metadata_dir.mkdir(parents=True, exist_ok=True)
    fd, meta_tmp = tempfile.mkstemp(prefix=".metadata.", suffix=".json", dir=str(metadata_dir))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(event_metadata(event), handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(meta_tmp, 0o600)
        inbox_cmd = [
            str(env.script_dir / "fm-inbox.sh"),
            "note",
            "--source",
            INBOX_SOURCE,
            "--external-id",
            str(event.get("external_id")),
            "--metadata-file",
            meta_tmp,
            "-",
        ]
        proc = subprocess.run(inbox_cmd, input=body, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode != 0:
            if proc.stdout:
                print(proc.stdout, end="")
            if proc.stderr:
                print(proc.stderr, end="", file=sys.stderr)
            raise FMError(f"captain inbox capture failed for {event.get('external_id')}")
    finally:
        try:
            os.unlink(meta_tmp)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Discord HTTP helpers
# ---------------------------------------------------------------------------

class ConsoleClient:
    def __init__(self, cfg: "ConsoleConfig", env: "fwl.Env"):
        self.token = live.decrypt_token_from(env, cfg.secret_file, cfg.token_key)
        self.client = live.DiscordClient(self.token)

    def redact(self, text: str) -> str:
        return live.redact(text, self.token)

    def active_threads(self, guild_id: str) -> List[Dict[str, Any]]:
        listing = self.client.request("GET", f"/guilds/{guild_id}/threads/active")
        threads = listing.get("threads") if isinstance(listing, dict) else None
        return [t for t in threads if isinstance(t, dict)] if isinstance(threads, list) else []

    def archived_threads(self, channel_id: str, limit: int) -> List[Dict[str, Any]]:
        listing = self.client.request(
            "GET",
            f"/channels/{channel_id}/threads/archived/public",
            params={"limit": str(limit)},
        )
        threads = listing.get("threads") if isinstance(listing, dict) else None
        return [t for t in threads if isinstance(t, dict)] if isinstance(threads, list) else []

    def messages(self, channel_id: str, after: int, limit: int) -> List[Dict[str, Any]]:
        params = {"limit": str(limit)}
        if after:
            params["after"] = str(after)
        listing = self.client.request("GET", f"/channels/{channel_id}/messages", params=params)
        return [m for m in listing if isinstance(m, dict)] if isinstance(listing, list) else []

    def post_message(self, channel_id: str, text: str) -> str:
        sent = self.client.request(
            "POST",
            f"/channels/{channel_id}/messages",
            {"content": text, "allowed_mentions": {"parse": []}},
        )
        message_id = str(sent.get("id") or "") if isinstance(sent, dict) else ""
        if not message_id.isdigit():
            raise FMError("Discord did not return a usable message id for the reply")
        return message_id

    def channel(self, channel_id: str) -> Dict[str, Any]:
        info = self.client.request("GET", f"/channels/{channel_id}")
        return info if isinstance(info, dict) else {}


# ---------------------------------------------------------------------------
# Inbound capture
# ---------------------------------------------------------------------------

def ignored_record(event: Dict[str, Any], channel: ConsoleChannel, target_id: str) -> Dict[str, Any]:
    return {
        "at": fwl.utc_now(),
        "guild_id": channel.guild_id,
        "channel_id": target_id,
        "message_id": str(event.get("message_id") or ""),
        "author_id": str(event.get("author_id") or ""),
        "reason": str(event.get("reason") or "ignored"),
    }


def append_ignored(env: "fwl.Env", records: List[Dict[str, Any]], max_ignored: int) -> None:
    if not records:
        return
    with fwl.state_transaction(env):
        path = ignored_path(env)
        existing: List[Any] = []
        if path.exists():
            loaded = fwl.load_existing_json(path)
            if isinstance(loaded, dict) and isinstance(loaded.get("records"), list):
                existing = loaded["records"]
        seen = {
            (str(record.get("channel_id") or ""), str(record.get("message_id") or ""))
            for record in existing
            if isinstance(record, dict)
        }
        for record in records:
            key = (str(record.get("channel_id") or ""), str(record.get("message_id") or ""))
            if key in seen:
                continue
            seen.add(key)
            existing.append(record)
        fwl.atomic_json(path, {"schema": IGNORED_SCHEMA, "records": existing[-max_ignored:]})


def ingest_message(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    channel: ConsoleChannel,
    channel_id: str,
    parent_id: str,
    message: Dict[str, Any],
) -> str:
    """Capture or record one message through the shared path, whichever transport saw it."""
    event = normalize_message(cfg, channel, channel_id, parent_id, message)
    if event.get("kind") == "text":
        handoff_event(env, event)
        return "captured"
    append_ignored(env, [ignored_record(event, channel, channel_id)], cfg.max_ignored)
    return "ignored"


def finish_target(env: "fwl.Env", channel_id: str, cursor: int, ignored_batch: List[Dict[str, Any]], max_ignored: int) -> None:
    append_ignored(env, ignored_batch, max_ignored)
    if cursor:
        with fwl.state_transaction(env):
            current = read_cursor(env, channel_id)
            if cursor > current:
                atomic_text(cursor_path(env, channel_id), f"{cursor}\n")


def process_target(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    channel: ConsoleChannel,
    target_id: str,
    parent_id: str,
) -> Tuple[int, int, int]:
    """Poll one channel or thread; return (scanned, captured, ignored)."""
    last = read_cursor(env, target_id)
    messages = client.messages(target_id, last, cfg.max_messages)
    messages.sort(key=lambda m: int(str(m.get("id") or "0")) if str(m.get("id") or "0").isdigit() else 0)
    ignored_batch: List[Dict[str, Any]] = []
    cursor = last
    captured = 0
    ignored = 0
    for message in messages:
        event = normalize_message(cfg, channel, target_id, parent_id, message)
        message_id = str(event.get("message_id") or "")
        if event.get("kind") == "text":
            handoff_event(env, event)
            captured += 1
        else:
            ignored += 1
            ignored_batch.append(ignored_record(event, channel, target_id))
        if message_id.isdigit() and int(message_id) > cursor:
            cursor = int(message_id)
    finish_target(env, target_id, cursor, ignored_batch, cfg.max_ignored)
    return len(messages), captured, ignored


def record_thread(env: "fwl.Env", channel: ConsoleChannel, thread: Dict[str, Any]) -> None:
    thread_id = str(thread.get("id") or "")
    if not thread_id.isdigit():
        return
    record = {
        "schema": THREAD_SCHEMA,
        "thread_id": thread_id,
        "guild_id": channel.guild_id,
        "parent_id": channel.channel_id,
        "label": channel.label,
        "recorded_at": fwl.utc_now(),
    }
    with fwl.state_transaction(env):
        fwl.atomic_json(thread_record_path(env, thread_id), record)


def inbound_pass(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient") -> Dict[str, int]:
    active_by_guild: Dict[str, List[Dict[str, Any]]] = {}
    for guild_id in cfg.guild_ids:
        active_by_guild[guild_id] = client.active_threads(guild_id)
    scanned = captured = ignored = 0
    per_channel: Dict[str, int] = {}
    for channel in cfg.channels:
        targets: List[Tuple[str, str]] = [(channel.channel_id, "")]
        seen = {channel.channel_id}
        threads = [t for t in active_by_guild.get(channel.guild_id, []) if str(t.get("parent_id") or "") == channel.channel_id]
        try:
            threads += client.archived_threads(channel.channel_id, min(cfg.max_threads, 50))
        except FMError:
            # An archived-thread listing that is not available for a plain text
            # channel is not a failure of the parent channel poll.
            pass
        for thread in threads[: cfg.max_threads]:
            thread_id = str(thread.get("id") or "")
            if not thread_id.isdigit() or thread_id in seen:
                continue
            seen.add(thread_id)
            record_thread(env, channel, thread)
            targets.append((thread_id, channel.channel_id))
        for target_id, parent_id in targets:
            n_scanned, n_captured, n_ignored = process_target(env, cfg, client, channel, target_id, parent_id)
            scanned += n_scanned
            captured += n_captured
            ignored += n_ignored
            per_channel[target_id] = read_cursor(env, target_id)
    stats = {
        "at": fwl.utc_now(),
        "scanned": scanned,
        "captured": captured,
        "ignored": ignored,
        "cursors": per_channel,
    }
    with fwl.state_transaction(env):
        fwl.atomic_json(last_pass_path(env), {"schema": LAST_PASS_SCHEMA, **stats})
    return stats


# ---------------------------------------------------------------------------
# Permanent connection (Discord gateway)
# ---------------------------------------------------------------------------

class GatewaySocketError(FMError):
    """A gateway websocket could not connect, or dropped while in use."""


class GatewayWebSocket:
    """Minimal RFC 6455 client for the Discord gateway, standard library only.

    It requests the JSON encoding and never negotiates per-message compression,
    so every data frame payload is the raw UTF-8 JSON text. Client frames are
    always masked and server frames are unmasked, as the protocol requires.
    """

    def __init__(self, url: str, timeout: float):
        self.url = url
        self.timeout = timeout
        self.sock: Optional[socket.socket] = None
        self.reader: Optional[Any] = None
        self._write_lock = threading.Lock()

    def connect(self) -> None:
        parts = urllib.parse.urlsplit(self.url)
        scheme = parts.scheme.lower()
        if scheme not in ("ws", "wss"):
            raise GatewaySocketError("gateway url must be ws:// or wss://")
        host = parts.hostname or ""
        if not host:
            raise GatewaySocketError("gateway url has no host")
        port = parts.port or (443 if scheme == "wss" else 80)
        path = parts.path or "/"
        if parts.query:
            path = f"{path}?{parts.query}"
        try:
            raw = socket.create_connection((host, port), timeout=self.timeout)
        except OSError as exc:
            raise GatewaySocketError(f"gateway connection to {host} failed: {exc}") from exc
        if scheme == "wss":
            context = ssl.create_default_context()
            try:
                raw = context.wrap_socket(raw, server_hostname=host)
            except (ssl.SSLError, OSError) as exc:
                raw.close()
                raise GatewaySocketError(f"gateway TLS handshake to {host} failed: {exc}") from exc
        raw.settimeout(self.timeout)
        self.sock = raw
        self.reader = raw.makefile("rb")
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        try:
            raw.sendall(handshake.encode("ascii"))
            status = self.reader.readline().decode("latin-1").strip()
            headers: Dict[str, str] = {}
            while True:
                line = self.reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
                name, _, value = line.decode("latin-1").partition(":")
                headers[name.strip().lower()] = value.strip()
        except (OSError, socket.timeout, ssl.SSLError) as exc:
            self.close()
            raise GatewaySocketError(f"gateway websocket handshake failed: {exc}") from exc
        if " 101 " not in status:
            self.close()
            raise GatewaySocketError(f"gateway websocket handshake was refused: {status}")
        expected = base64.b64encode(
            hashlib.sha1((key + GATEWAY_WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        if headers.get("sec-websocket-accept") != expected:
            self.close()
            raise GatewaySocketError("gateway websocket handshake returned a wrong accept key")

    def set_timeout(self, timeout: float) -> None:
        self.timeout = timeout
        if self.sock is not None:
            self.sock.settimeout(timeout)

    def _read_exact(self, size: int) -> bytes:
        if self.reader is None:
            raise GatewaySocketError("gateway websocket is not connected")
        try:
            data = self.reader.read(size)
        except (socket.timeout, TimeoutError, OSError) as exc:
            raise GatewaySocketError(f"gateway websocket read failed: {exc}") from exc
        if data is None or len(data) < size:
            raise GatewaySocketError("gateway websocket closed")
        return data

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.sock is None:
            raise GatewaySocketError("gateway websocket is not connected")
        length = len(payload)
        header = bytearray([0x80 | opcode])
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", length)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        frame = bytes(header) + mask + masked
        with self._write_lock:
            try:
                self.sock.sendall(frame)
            except (OSError, socket.timeout) as exc:
                raise GatewaySocketError(f"gateway websocket write failed: {exc}") from exc

    def send_json(self, payload: Dict[str, Any]) -> None:
        self._send_frame(0x1, json.dumps(payload, separators=(",", ":")).encode("utf-8"))

    def recv_text(self) -> Optional[str]:
        fragments = b""
        active = False
        while True:
            header = self._read_exact(2)
            first, second = header[0], header[1]
            fin = bool(first & 0x80)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            if length > MAX_GATEWAY_FRAME_BYTES:
                raise GatewaySocketError("gateway websocket frame exceeds the size bound")
            mask = self._read_exact(4) if masked else b""
            payload = self._read_exact(length) if length else b""
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x8:
                return None
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2):
                fragments = payload
                active = True
                if fin:
                    return fragments.decode("utf-8", "replace")
                continue
            if opcode == 0x0 and active:
                fragments += payload
                if fin:
                    return fragments.decode("utf-8", "replace")
                continue
            # An unknown opcode is ignored rather than desynchronizing the stream.
            continue

    def close(self) -> None:
        reader, self.reader = self.reader, None
        sock, self.sock = self.sock, None
        if reader is not None:
            try:
                reader.close()
            except OSError:
                pass
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


class GatewayHeartbeat:
    def __init__(self, transport: "GatewayWebSocket", interval: float):
        self.transport = transport
        self.interval = interval
        self.sequence: Optional[int] = None
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._beat, name="discord-gateway-heartbeat", daemon=True)
        self._thread.start()

    def _beat(self) -> None:
        while not self._stop.wait(self.interval):
            try:
                self.transport.send_json({"op": 1, "d": self.sequence})
            except Exception:
                return

    def note_sequence(self, sequence: Any) -> None:
        if isinstance(sequence, int) and not isinstance(sequence, bool):
            self.sequence = sequence

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None


def gateway_identify_payload(token: str, intents: int) -> Dict[str, Any]:
    return {
        "op": 2,
        "d": {
            "token": token,
            "intents": intents,
            "properties": {"os": sys.platform, "browser": "firstmate", "device": "firstmate"},
            "presence": {"since": None, "activities": [], "status": "online", "afk": False},
        },
    }


def resolve_gateway_channel(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    channel_id: str,
    cache: Dict[str, Optional[Tuple[str, ConsoleChannel]]],
) -> Optional[Tuple[str, ConsoleChannel]]:
    """Map a dispatch channel id to its configured #firstmate channel and parent."""
    channel = cfg.channel_for_id(channel_id)
    if channel is not None:
        return ("", channel)
    if channel_id in cache:
        return cache[channel_id]
    record = load_thread_record(env, channel_id)
    parent_id = str(record.get("parent_id") or "") if isinstance(record, dict) else ""
    parent_channel = cfg.channel_for_id(parent_id) if parent_id else None
    if parent_channel is not None:
        cache[channel_id] = (parent_id, parent_channel)
        return cache[channel_id]
    lookup: Dict[str, Any] = {}
    try:
        lookup = client.channel(channel_id)
    except FMError:
        cache[channel_id] = None
        return None
    parent_id = str(lookup.get("parent_id") or "")
    parent_channel = cfg.channel_for_id(parent_id) if parent_id else None
    ctype = lookup.get("type")
    if parent_channel is not None and ctype in THREAD_CHANNEL_TYPES:
        record_thread(env, parent_channel, {"id": channel_id, "parent_id": parent_id})
        cache[channel_id] = (parent_id, parent_channel)
        return cache[channel_id]
    cache[channel_id] = None
    return None


def handle_gateway_message(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    data: Dict[str, Any],
    cache: Dict[str, Optional[Tuple[str, ConsoleChannel]]],
) -> None:
    """Capture one MESSAGE_CREATE dispatch through the same path as polling."""
    guild_id = str(data.get("guild_id") or "")
    channel_id = str(data.get("channel_id") or "")
    if guild_id not in cfg.guild_ids or not channel_id:
        return
    resolved = resolve_gateway_channel(env, cfg, client, channel_id, cache)
    if resolved is None:
        return
    parent_id, channel = resolved
    ingest_message(env, cfg, channel, channel_id, parent_id, data)


def gateway_connect(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", state: Dict[str, Any]) -> bool:
    """Run one gateway session to completion; return whether it reached READY."""
    url = str(state.get("resume_url") or cfg.gateway_url)
    transport = GatewayWebSocket(url, GATEWAY_CONNECT_TIMEOUT_SECONDS)
    transport.connect()
    heartbeat: Optional[GatewayHeartbeat] = None
    reached_ready = False
    try:
        hello: Optional[Dict[str, Any]] = None
        for _ in range(10):
            message = transport.recv_text()
            if message is None:
                raise GatewaySocketError("gateway closed before hello")
            try:
                payload = json.loads(message)
            except json.JSONDecodeError:
                continue
            if payload.get("op") == 10:
                hello = payload
                break
        if hello is None:
            raise GatewaySocketError("gateway did not send hello")
        interval = float((hello.get("d") or {}).get("heartbeat_interval") or 45000) / 1000.0
        transport.set_timeout(max(interval * 2.5, 30.0))
        heartbeat = GatewayHeartbeat(transport, interval)
        if state.get("session_id") and state.get("resume_url"):
            transport.send_json({
                "op": 6,
                "d": {"token": client.token, "session_id": state["session_id"], "seq": state.get("sequence")},
            })
        else:
            transport.send_json(gateway_identify_payload(client.token, cfg.gateway_intents))
        heartbeat.start()
        cache: Dict[str, Optional[Tuple[str, ConsoleChannel]]] = {}
        while True:
            message = transport.recv_text()
            if message is None:
                break
            try:
                payload = json.loads(message)
            except json.JSONDecodeError:
                continue
            op = payload.get("op")
            data = payload.get("d")
            if op == 0 and isinstance(data, dict):
                heartbeat.note_sequence(data.get("s"))
                state["sequence"] = data.get("s")
                event_type = payload.get("t")
                if event_type == "READY":
                    reached_ready = True
                    state["session_id"] = str(data.get("session_id") or "")
                    state["resume_url"] = str(data.get("resume_gateway_url") or url)
                    record_connection_state(env, "gateway", "connected", url=gateway_host_label(url))
                elif event_type == "RESUMED":
                    reached_ready = True
                    record_connection_state(env, "gateway", "connected", url=gateway_host_label(url))
                elif event_type == "MESSAGE_CREATE":
                    handle_gateway_message(env, cfg, client, data, cache)
            elif op == 1:
                transport.send_json({"op": 1, "d": state.get("sequence")})
            elif op == 7:
                break
            elif op == 9:
                if not data:
                    state["session_id"] = None
                    state["resume_url"] = None
                    state["sequence"] = None
                break
            elif op == 11:
                continue
    finally:
        if heartbeat is not None:
            heartbeat.stop()
        transport.close()
    return reached_ready


def interruptible_sleep(seconds: float, max_seconds: Optional[float], started: float) -> None:
    deadline = time.monotonic() + seconds
    if max_seconds is not None:
        deadline = min(deadline, started + max_seconds)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 0.5))


def run_polling_fallback(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", attempts: int, reason: str) -> None:
    record_connection_state(
        env, "polling-fallback", "polling", error=reason, attempts=attempts, url=gateway_host_label(cfg.gateway_url)
    )
    try:
        inbound_pass(env, cfg, client)
    except FMError as exc:
        record_connection_state(
            env,
            "polling-fallback",
            "polling",
            error=client.redact(str(exc)),
            attempts=attempts,
            url=gateway_host_label(cfg.gateway_url),
        )


def run_gateway_daemon(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    once: bool = False,
    max_seconds: Optional[float] = None,
) -> int:
    """Hold the permanent connection open, reconnecting on every drop.

    A connection that never reaches READY falls back to the existing bounded
    polling pass, still retrying the gateway, so the console never goes silent.
    The fallback ends as soon as a connection is established.
    """
    state: Dict[str, Any] = {"session_id": None, "resume_url": None, "sequence": None}
    backoff = cfg.gateway_backoff_base
    failures = 0
    last_error = ""
    started = time.monotonic()
    while True:
        try:
            reached = gateway_connect(env, cfg, client, state)
            if not reached:
                raise GatewaySocketError("gateway connection ended before it was established")
            failures = 0
            backoff = cfg.gateway_backoff_base
            record_connection_state(
                env, "gateway", "reconnecting", error="connection closed; reconnecting", url=gateway_host_label(cfg.gateway_url)
            )
        except FMError as exc:
            failures += 1
            last_error = client.redact(str(exc))
            if failures >= cfg.gateway_fallback_after_attempts:
                mode, state_name = "polling-fallback", "polling"
            else:
                mode, state_name = "gateway", "reconnecting"
            record_connection_state(
                env, mode, state_name, error=last_error, attempts=failures, url=gateway_host_label(cfg.gateway_url)
            )
        if once:
            if failures >= cfg.gateway_fallback_after_attempts:
                run_polling_fallback(env, cfg, client, failures, last_error)
            return 0
        if failures >= cfg.gateway_fallback_after_attempts:
            run_polling_fallback(env, cfg, client, failures, last_error)
            interruptible_sleep(cfg.gateway_fallback_poll_seconds, max_seconds, started)
        else:
            interruptible_sleep(backoff, max_seconds, started)
            backoff = min(max(backoff * 2, cfg.gateway_backoff_base), cfg.gateway_backoff_max)
        if max_seconds is not None and time.monotonic() - started >= max_seconds:
            return 0


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_sample_config(args: argparse.Namespace, env: "fwl.Env") -> int:
    print(json.dumps(sample_config(), indent=2, sort_keys=True))
    return 0


def cmd_config_check(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    print(f"config ok: {cfg.path}")
    print(f"channels: {len(cfg.channels)}")
    for channel in cfg.channels:
        print(f"  {channel.label}: guild {channel.guild_id} channel {channel.channel_id}")
    print(f"live polling: {'on' if cfg.live_polling_enabled else 'off'}")
    print(f"live posting: {'on' if cfg.live_posting_enabled else 'off'}")
    print(f"live gateway: {'on' if cfg.live_gateway_enabled else 'off'}")
    print(f"gateway url: {gateway_host_label(cfg.gateway_url)}")
    return 0


def cmd_listen(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    if not cfg.live_polling_enabled:
        raise FMError("inbound listening is disabled; enable live.polling in the conversation console config")
    client = ConsoleClient(cfg, env)
    try:
        stats = inbound_pass(env, cfg, client)
    except FMError as exc:
        print(f"fm-discord-conversation-console: {client.redact(str(exc))}", file=sys.stderr)
        return 1
    print(f"listened: scanned={stats['scanned']} captured={stats['captured']} ignored={stats['ignored']}")
    return 0


def cmd_connect(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    if not cfg.live_polling_enabled:
        raise FMError("the permanent connection is disabled; enable live.polling in the conversation console config")
    if not cfg.live_gateway_enabled:
        raise FMError("the permanent connection is disabled; enable live.gateway in the conversation console config")
    client = ConsoleClient(cfg, env)
    return run_gateway_daemon(env, cfg, client, once=args.once, max_seconds=args.max_seconds)


def resolve_target(
    cfg: "ConsoleConfig",
    env: "fwl.Env",
    request_id: Optional[str],
    thread: Optional[str],
    channel: Optional[str],
) -> Tuple[str, str, str]:
    if request_id:
        match = fwl.REQUEST_RE.fullmatch(request_id)
        if not match:
            raise FMError("request id must be discord:<guild>:<channel>:<message>")
        guild_id, channel_id, message_id = match.groups()
        configured = cfg.channel_for_id(channel_id)
        if configured is not None:
            if configured.guild_id != guild_id:
                raise FMError("request id names a channel outside the configured guild")
            return guild_id, channel_id, message_id
        record = load_thread_record(env, channel_id)
        if record is None:
            raise FMError("request id names an unknown #firstmate channel or thread")
        if str(record.get("guild_id") or "") != guild_id:
            raise FMError("request id names a thread outside the configured guild")
        return guild_id, channel_id, message_id
    if thread:
        record = load_thread_record(env, thread)
        if record is None:
            raise FMError("--thread is not a recorded #firstmate conversation")
        return str(record.get("guild_id") or ""), thread, ""
    if channel:
        configured = cfg.channel_for_id(channel)
        if configured is None:
            raise FMError("--channel is not a configured #firstmate channel")
        return configured.guild_id, channel, ""
    raise FMError("one of --request-id, --thread, or --channel is required")


def cmd_reply(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    guild_id, channel_id, message_id = resolve_target(cfg, env, args.request_id, args.thread, args.channel)
    text = fwl.read_text_file(args.text_file).strip()
    for marker in REFUSED_MARKERS:
        if marker in text:
            raise FMError("refusing to post operational text to a conversation channel")
    digest = fwl.sha256_text(text)
    anchor = args.request_id or f"discord:{guild_id}:{channel_id}:{message_id or '0'}"
    nonce = args.nonce or f"reply:{anchor}:{digest}"
    target = {"guild_id": guild_id, "channel_id": channel_id}
    if message_id:
        target["message_id"] = message_id
    receipt = fwl.base_receipt("reply", ADAPTER, target, digest)
    if args.dry_run:
        print("Discord conversation reply plan (no network).")
        print(f"destination thread/channel: {channel_id}")
        print(f"reply-to request: {anchor}")
        print(f"allowed_mentions: {json.dumps({'parse': []}, sort_keys=True)}")
        print(f"nonce: {nonce}")
        print("dry-run only; no Discord post was made.")
        return 0
    if not cfg.live_posting_enabled:
        raise FMError("live posting is disabled; enable live.posting in the conversation console config")
    existing = fwl.load_existing_json(fwl.receipt_path(env, nonce))
    if existing is not None:
        comparable = dict(existing)
        comparable.pop("recorded_at", None)
        if comparable != fwl.receipt_record(nonce, receipt, str(existing.get("discord_message_id") or "")):
            raise FMError("refusing to overwrite a different Discord receipt for the same nonce")
        print(f"receipt exists for nonce {nonce}; no second delivery")
        return 0
    client = ConsoleClient(cfg, env)
    try:
        discord_message_id = client.post_message(channel_id, text)
    except FMError as exc:
        print(f"fm-discord-conversation-console: {client.redact(str(exc))}", file=sys.stderr)
        return 1
    print(fwl.record_receipt(env, nonce, receipt, discord_message_id))
    print(f"replied in conversation {channel_id}")
    return 0


def cmd_status(args: argparse.Namespace, env: "fwl.Env") -> int:
    """Side-effect-free health report: local records only, safe to run in a loop."""
    path = Path(args.config).expanduser() if args.config else default_config_path(env)
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    print("discord conversation console status")
    print(f"config: {path}")
    try:
        cfg = ConsoleConfig.load(env, args.config)
    except FMError as exc:
        print(f"health: config-invalid: {exc}")
        return 0
    polling_registered = (env.state / "procevent" / f"{SOURCE_ID}.source").is_file()
    gateway_registered = (env.state / "procevent" / f"{GATEWAY_SOURCE_ID}.source").is_file()
    connection = read_connection(env)
    secret_path = Path(cfg.secret_file)
    if not secret_path.is_absolute():
        secret_path = env.home / secret_path
    secret_present = secret_path.is_file()
    if not cfg.live_polling_enabled:
        health = "polling-disabled"
    elif cfg.live_gateway_enabled and not gateway_registered:
        health = "stopped"
    elif not cfg.live_gateway_enabled and not polling_registered:
        health = "stopped"
    elif not secret_present:
        health = "secret-missing"
    elif cfg.live_gateway_enabled and not (isinstance(connection, dict) and connection.get("mode")):
        health = "starting"
    elif cfg.live_gateway_enabled and isinstance(connection, dict) and connection.get("mode") == "polling-fallback":
        health = "polling-fallback"
    else:
        health = "healthy"
    thread_dir = console_state_path(env, "threads")
    thread_count = sum(1 for _ in thread_dir.glob("*.json")) if thread_dir.is_dir() else 0
    ignored_count = 0
    last_pass: Dict[str, Any] = {}
    try:
        loaded_ignored = fwl.load_existing_json(ignored_path(env))
        if isinstance(loaded_ignored, dict) and isinstance(loaded_ignored.get("records"), list):
            ignored_count = len(loaded_ignored["records"])
    except FMError:
        health = "state-malformed"
    try:
        loaded_pass = fwl.load_existing_json(last_pass_path(env))
        if isinstance(loaded_pass, dict):
            last_pass = loaded_pass
    except FMError:
        health = "state-malformed"
    print(f"health: {health}")
    print(f"channels: {len(cfg.channels)}")
    for channel in cfg.channels:
        last = read_cursor(env, channel.channel_id)
        print(f"  {channel.label}: guild {channel.guild_id} channel {channel.channel_id} last_message={last}")
    print(f"live polling: {'on' if cfg.live_polling_enabled else 'off'}")
    print(f"live posting: {'on' if cfg.live_posting_enabled else 'off'}")
    print(f"live gateway: {'on' if cfg.live_gateway_enabled else 'off'}")
    print(f"listener registered: {'yes' if (gateway_registered if cfg.live_gateway_enabled else polling_registered) else 'no'}")
    if cfg.live_gateway_enabled:
        if isinstance(connection, dict) and connection.get("mode"):
            print(f"connection mode: {connection.get('mode')}")
            print(f"connection state: {connection.get('state')} since {connection.get('since')}")
            if connection.get("error"):
                print(f"connection note: {connection.get('error')}")
        else:
            print("connection mode: not established")
    else:
        print("connection mode: polling")
    print(f"secret file: {'present' if secret_present else 'missing'}")
    print(f"recorded threads: {thread_count}")
    print(f"ignored records: {ignored_count}")
    if last_pass:
        print(f"last pass: {last_pass.get('at')} scanned={last_pass.get('scanned')} captured={last_pass.get('captured')} ignored={last_pass.get('ignored')}")
    else:
        print("last pass: none")
    return 0


def _procevent_command(env: "fwl.Env", cfg: "ConsoleConfig") -> List[str]:
    return [str(env.script_dir / "fm-procevent-discord-conversation-console.sh"), "source", "--config", str(cfg.path)]


def _gateway_procevent_command(env: "fwl.Env", cfg: "ConsoleConfig") -> List[str]:
    return [str(env.script_dir / "fm-procevent-discord-conversation-console.sh"), "gateway", "--config", str(cfg.path)]


def _register_source(env: "fwl.Env", source_id: str, command: List[str]) -> str:
    register_cmd = [str(env.script_dir / "fm-procevent.sh"), "register", ADAPTER, source_id, "--"] + command
    proc = subprocess.run(register_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        if proc.stdout:
            print(proc.stdout, end="")
        if proc.stderr:
            print(proc.stderr, end="", file=sys.stderr)
        raise FMError("process-event registration failed")
    return proc.stdout


def _retire_source(env: "fwl.Env", source_id: str) -> str:
    retire_cmd = [str(env.script_dir / "fm-procevent.sh"), "retire", source_id]
    proc = subprocess.run(retire_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        if proc.stdout:
            print(proc.stdout, end="")
        if proc.stderr:
            print(proc.stderr, end="", file=sys.stderr)
        raise FMError("process-event retirement failed")
    return proc.stdout


def cmd_start(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    if cfg.live_gateway_enabled:
        source_id = GATEWAY_SOURCE_ID
        command = _gateway_procevent_command(env, cfg)
        alternate = SOURCE_ID
    else:
        source_id = SOURCE_ID
        command = _procevent_command(env, cfg)
        alternate = GATEWAY_SOURCE_ID
    if args.dry_run:
        print("Discord conversation console start dry-run (no network).")
        print(f"connection mode: {'gateway' if cfg.live_gateway_enabled else 'polling'}")
        print(f"source id: {source_id}")
        print("register command:")
        print(" ".join([str(env.script_dir / "fm-procevent.sh"), "register", ADAPTER, source_id, "--"] + command))
        return 0
    if not cfg.live_polling_enabled:
        raise FMError("start refused while live.polling is disabled in the conversation console config")
    # Exactly one inbound transport is registered, so polling and the permanent
    # connection never both collect the same message.
    output = _retire_source(env, alternate)
    if output:
        print(output, end="")
    output = _register_source(env, source_id, command)
    if output:
        print(output, end="")
    if cfg.live_gateway_enabled:
        print("discord conversation console permanent connection registered; the watcher supervises it")
    else:
        print("discord conversation console listener registered; the watcher supervises it")
    return 0


def cmd_stop(args: argparse.Namespace, env: "fwl.Env") -> int:
    for source_id in (SOURCE_ID, GATEWAY_SOURCE_ID):
        output = _retire_source(env, source_id)
        if output:
            print(output, end="")
    print("discord conversation console listener retired")
    return 0


# ---------------------------------------------------------------------------
# Process-event adapter
# ---------------------------------------------------------------------------

def procevent_cmd_source(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    if not cfg.live_polling_enabled:
        print("discord conversation console: live polling is disabled in the config", file=sys.stderr)
        return 1
    client = ConsoleClient(cfg, env)
    try:
        inbound_pass(env, cfg, client)
    except FMError as exc:
        print(f"discord conversation console source failed: {client.redact(str(exc))}", file=sys.stderr)
        return 1
    return fwl.EXIT_NO_RESULT


def procevent_cmd_gateway(args: argparse.Namespace, env: "fwl.Env") -> int:
    cfg = ConsoleConfig.load(env, args.config)
    if not cfg.live_polling_enabled or not cfg.live_gateway_enabled:
        print("discord conversation console: the permanent connection is disabled in the config", file=sys.stderr)
        return 1
    client = ConsoleClient(cfg, env)
    return run_gateway_daemon(env, cfg, client, once=args.once, max_seconds=args.max_seconds)


def procevent_cmd_classify(args: argparse.Namespace, env: "fwl.Env") -> int:
    print("ignored")
    return 0


def procevent_cmd_silent(args: argparse.Namespace, env: "fwl.Env") -> int:
    return 0


def procevent_cmd_terminal(args: argparse.Namespace, env: "fwl.Env") -> int:
    return 1


def procevent_cmd_self_announcing(args: argparse.Namespace, env: "fwl.Env") -> int:
    return 0


def procevent_cmd_autohandle(args: argparse.Namespace, env: "fwl.Env") -> int:
    if args.source_id not in (SOURCE_ID, GATEWAY_SOURCE_ID) or not str(args.sequence).isdigit():
        raise FMError("not a discord conversation console capture")
    subprocess.run(
        [str(env.script_dir / "fm-procevent.sh"), "handled", args.source_id, str(args.sequence)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return 0


def procevent_cmd_answers(args: argparse.Namespace, env: "fwl.Env") -> int:
    return 0


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def add_config_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", help="non-secret Discord conversation console config JSON")


def build_tool_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-discord-conversation-console.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("sample-config")
    p.set_defaults(func=cmd_sample_config)
    p = sub.add_parser("config-check")
    add_config_argument(p)
    p.set_defaults(func=cmd_config_check)
    p = sub.add_parser("listen")
    add_config_argument(p)
    p.set_defaults(func=cmd_listen)
    p = sub.add_parser("connect")
    add_config_argument(p)
    p.add_argument("--once", action="store_true")
    p.add_argument("--max-seconds", type=float)
    p.set_defaults(func=cmd_connect)
    p = sub.add_parser("reply")
    add_config_argument(p)
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--request-id")
    target.add_argument("--thread")
    target.add_argument("--channel")
    p.add_argument("--text-file", required=True)
    p.add_argument("--nonce")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_reply)
    p = sub.add_parser("status")
    add_config_argument(p)
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("start")
    add_config_argument(p)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_start)
    p = sub.add_parser("stop")
    add_config_argument(p)
    p.set_defaults(func=cmd_stop)
    return parser


def build_procevent_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-procevent-discord-conversation-console.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("source")
    add_config_argument(p)
    p.set_defaults(func=procevent_cmd_source)
    p = sub.add_parser("gateway")
    add_config_argument(p)
    p.add_argument("--once", action="store_true")
    p.add_argument("--max-seconds", type=float)
    p.set_defaults(func=procevent_cmd_gateway)
    p = sub.add_parser("classify")
    p.add_argument("result_file")
    p.set_defaults(func=procevent_cmd_classify)
    p = sub.add_parser("silent")
    p.add_argument("result_file")
    p.set_defaults(func=procevent_cmd_silent)
    p = sub.add_parser("terminal")
    p.add_argument("result_file")
    p.set_defaults(func=procevent_cmd_terminal)
    p = sub.add_parser("self-announcing")
    p.set_defaults(func=procevent_cmd_self_announcing)
    p = sub.add_parser("autohandle")
    p.add_argument("source_id")
    p.add_argument("sequence")
    p.add_argument("result_file")
    p.set_defaults(func=procevent_cmd_autohandle)
    p = sub.add_parser("answers")
    p.add_argument("result_file")
    p.set_defaults(func=procevent_cmd_answers)
    return parser


def main(argv: List[str]) -> int:
    if len(argv) < 3:
        print("usage: fm_discord_conversation_console_lib.py <tool|procevent> <script-dir> ...", file=sys.stderr)
        return 2
    mode = argv[1]
    env = fwl.Env(argv[2])
    rest = argv[3:]
    if mode == "tool":
        parser = build_tool_parser()
    elif mode == "procevent":
        parser = build_procevent_parser()
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    args = parser.parse_args(rest)
    try:
        return int(args.func(args, env))
    except FMError as exc:
        fwl.die(str(exc))
        return 1
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
