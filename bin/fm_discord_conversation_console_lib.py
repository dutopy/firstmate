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

A captain voice message or supported audio attachment with no caption is
transcribed through Groq Whisper large-v3 (bin/fm_groq_whisper.py) and fed into
the same capture path as typed text, so the acknowledgement, fast path, typing
indicator, and full turn behave identically. The temporary audio is deleted
before the request returns and neither the audio nor the transcription key is
ever written to a durable record or a log.

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

The same permanent connection carries the captain's button presses. The ``card``
command posts one captain-facing decision, blocker, or clarification message
with up to five labelled option buttons; a press arrives as a gateway
``INTERACTION_CREATE`` dispatch, is answered through Discord's interaction
callback, and records the captain's choice through the same keyed-answer intake a
typed reply uses (``bin/fm-captain-hold.sh answer``, or ``hold --until`` for a
"later" option). A validated press also appends exactly one durable wake through
the same captain-inbox seam a typed message uses (``bin/fm-inbox.sh note``), so
firstmate's ordinary supervision picks the recorded answer up without the
captain saying anything in chat; the interaction id is the inbox external id, so
a repeated delivery appends no second wake. A card is only posted while the
permanent connection is registered, because a bounded poll cannot receive an
interaction, and while its task is still an open captain call, so a posted card
is one whose every button can validate.

The console reply can carry the card for the interaction it answers. The
``reply`` command's optional ``--card-file`` posts the card through that same
guarded path, in the same conversation, immediately after the reply text, so a
clarification question, a projection choice, a free request, a decision, or a
blocker arrives with its card and the captain settles it with one press. The
reply text always posts and the card never replaces it, the card's identity is
keyed to the reply so a replayed reply mints no second card, and the trigger
mapping (``INTERACTION_CARD_TRIGGERS``) is the single owner of which interaction
shapes produce a card.

The same card machinery carries the captain's confirmation of an uncertain
transcription. When two readings of a captain voice message disagree, the
console posts the uncertain reading as a card whose three buttons are existing
card actions: confirm the reading as it was heard (``answer``), correct it by
typing in the conversation (``chat``), or discard that reading (``release``).
A press is recorded in the card record, folded into the durable transcript
record for that reading, and announced through the same captain-inbox wake seam,
so the pending item proceeds without the captain typing anything, and the audio
path, the transcript record, and the existing chat confirmation are all left as
they are. Only the configured captain user ids may press, and a replayed
delivery posts no second card and records no second outcome.

Every captured request also gets one bounded latency-journal record that the
read-only ``latency`` subcommand and ``status`` report. The five measured stages
are: stage 1 Discord creation to console ingest, stage 2 console handling, stage
3 the wake reaching the watcher (the ``.seen-inbox`` marker), stage 4 the
session's acknowledgement (the ``fm-inbox.sh drain --ack`` marker), and stage 5
the turn itself up to the reply. Stages 3 and 4 are read back from the durable
markers the capture path already produces rather than re-timed here; a message
captured through polling while ``live.gateway`` is enabled is recorded in a
bounded delivery-gap journal so the fallback is visible instead of silent.

Usage (via bin/fm-discord-conversation-console.sh):
    fm-discord-conversation-console.sh sample-config
    fm-discord-conversation-console.sh config-check [--config <json>]
    fm-discord-conversation-console.sh listen [--config <json>]
    fm-discord-conversation-console.sh connect [--config <json>] [--once] [--max-seconds <n>]
    fm-discord-conversation-console.sh reply [--config <json>] --text-file <f>
        (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
        [--card-file <f>] [--task-id <id>] [--nonce <n>] [--dry-run]
    fm-discord-conversation-console.sh card [--config <json>] --card-file <f>
        (--request-id <discord:guild:channel:message> | --thread <id> | --channel <id>)
        [--nonce <n>] [--dry-run]
    fm-discord-conversation-console.sh typing [--config <json>] --channel <id>
        [--interval <n>] [--max-seconds <n>] [--stop]
    fm-discord-conversation-console.sh status [--config <json>]
    fm-discord-conversation-console.sh latency [--config <json>] [--limit <n>] [--json]
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
import datetime
import hashlib
import importlib.util
import json
import math
import os
import re
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("fwl", SCRIPT_DIR / "fm_discord_workspace_lib.py")
fwl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fwl)

_live_spec = importlib.util.spec_from_file_location("fm_discord_live", SCRIPT_DIR / "fm_discord_live.py")
live = importlib.util.module_from_spec(_live_spec)
_live_spec.loader.exec_module(live)

_whisper_spec = importlib.util.spec_from_file_location("fm_groq_whisper", SCRIPT_DIR / "fm_groq_whisper.py")
whisper = importlib.util.module_from_spec(_whisper_spec)
_whisper_spec.loader.exec_module(whisper)

FMError = fwl.FMError

SCHEMA = "fm-discord-conversation-console.config.v1"
EVENT_SCHEMA = "fm-discord-conversation-console.event.v1"
IGNORED_SCHEMA = "fm-discord-conversation-console.ignored.v1"
THREAD_SCHEMA = "fm-discord-conversation-console.thread.v1"
LAST_PASS_SCHEMA = "fm-discord-conversation-console.last-pass.v1"
CONNECTION_SCHEMA = "fm-discord-conversation-console.connection.v1"
FAST_PATH_SCHEMA = "fm-discord-conversation-console.fast-path.v1"
LATENCY_SCHEMA = "fm-discord-conversation-console.latency.v1"
DELIVERY_GAP_SCHEMA = "fm-discord-conversation-console.delivery-gaps.v1"
TYPING_SCHEMA = "fm-discord-conversation-console.typing.v1"
TRANSCRIPT_SCHEMA = "fm-discord-conversation-console.transcript.v1"
SOURCE_ID = "discord-conversation-console"
GATEWAY_SOURCE_ID = "discord-conversation-console-gateway"
ADAPTER = "discord-conversation-console"
CONSOLE_STATE_SUBDIR = "conversation-console"
INBOX_SOURCE = "discord"

DEFAULT_MAX_MESSAGES = 100
DEFAULT_MAX_THREADS = 100
DEFAULT_MAX_IGNORED = 500

# Audio transcription. An audio attachment is downloaded from Discord into one
# temporary file, transcribed through Groq Whisper large-v3 in French with the
# captain's vocabulary prompt, and fed into the same capture path as text. The
# temporary audio is deleted before the request returns, and neither the audio
# nor the API key is ever written to a durable record or a log.
DEFAULT_AUDIO_MAX_BYTES = 25 * 1024 * 1024
DEFAULT_AUDIO_MAX_DURATION_SECONDS = 600
DEFAULT_TRANSCRIPTION_KEY_ENV = whisper.DEFAULT_KEY_ENV
DEFAULT_TRANSCRIPTION_MODEL = whisper.DEFAULT_MODEL
DEFAULT_TRANSCRIPTION_LANGUAGE = whisper.DEFAULT_LANGUAGE
DEFAULT_TRANSCRIPTION_PROMPT = whisper.DEFAULT_PROMPT
DEFAULT_TRANSCRIPTION_BASE_URL = whisper.DEFAULT_BASE_URL
DEFAULT_TRANSCRIPTION_TIMEOUT_SECONDS = whisper.DEFAULT_TIMEOUT_SECONDS
DEFAULT_TRANSCRIPTION_PREFIX = "Transcription : "
# The visible uncertainty marker. It replaces the ordinary prefix on the posted
# transcript and is repeated in the note, so neither the captain nor firstmate
# can read an uncertain transcription as a settled one.
DEFAULT_TRANSCRIPTION_UNCERTAIN_PREFIX = "Transcription incertaine - \u00e0 confirmer : "
DEFAULT_TRANSCRIPTION_CONFIDENCE_CHECK = True
DEFAULT_TRANSCRIPTION_CONFIDENCE_MAX_SECONDS = whisper.DEFAULT_CONFIDENCE_MAX_SECONDS
TRANSCRIPT_CONFIDENCE_STATUSES = ("agree", "disagree", "unavailable", "skipped", "disabled")
TRANSCRIPT_CONFIDENCE_MAX_REASON_CHARS = 200
MAX_TRANSCRIPT_RECORDS = 5000

# The fast path. The deterministic acknowledgement is posted the moment a
# captain message is captured, then Jev decides whether the message can be
# answered directly from durable records. A classifier that is missing, slow,
# wrong, or malformed routes the message to the full firstmate turn exactly as
# if the fast path did not exist.
DEFAULT_FAST_PATH_ACK = "On it - checking the records."
DEFAULT_FAST_PATH_TIMEOUT_SECONDS = 5.0
DEFAULT_FAST_PATH_MAX_ANSWER_CHARS = 1900
CLASSIFIER_ENV_TIMEOUT = "FM_JV_CONSOLE_ROUTE_TIMEOUT"
# One bounded shell read may not outlive the whole fast path; per-command bound.
FAST_PATH_READ_TIMEOUT_SECONDS = 10.0
# The reconciled states bin/fm-crew-state.sh can print, in plain captain words.
FAST_PATH_STATE_WORDS = {
    "working": "in progress",
    "parked": "waiting on a review or your input",
    "paused": "paused on an external wait",
    "done": "done",
    "blocked": "blocked",
    "failed": "did not complete",
    "unknown": "not clear from the records",
}
FAST_PATH_TASK_TOKEN_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,119}")
FAST_PATH_BACKLOG_LINE_RE = re.compile(r"^- \[[ xX]\] ([A-Za-z0-9][A-Za-z0-9._-]{1,119}) (?:-|$)")
# A fleet-wide fast answer is offered only for a message that plainly asks for
# current status, so a misclassified greeting can never draw a status dump.
FAST_PATH_QUESTION_HINTS = (
    "status", "stand", "state", "running", "in flight", "flight", "blocked",
    "waiting", "progress", "happening", "going on", "where",
    "statut", "\u00e9tat", "etat", "o\u00f9", "en cours", "bloqu\u00e9", "bloque",
)
# A blocked-specific answer is built from the per-task reconciled state, so the
# reply names the tasks that are actually blocked rather than the in-flight list.
FAST_PATH_BLOCKED_HINTS = ("blocked", "bloqu\u00e9", "bloque")
# Per-record-kind retention, so the per-message fast-path records stay bounded.
FAST_PATH_MAX_RECORDS = 5000

# The prepared request. Before the main turn, one bounded advisory step reads the
# captain's free-form message and attaches a structured packet to the durable
# intake note: the intent class, the target project and task entity selected
# from code-built candidate lists, the identifiers the message carries, and
# three to five facts already present in the records. The packet is advisory:
# the captain's raw message always accompanies it and stays authoritative, and a
# disabled, missing, failing, slow, or low-confidence preparation falls back
# deterministically to the raw message alone. Preparation never answers the
# captain, never dispatches work, and never changes a task record.
PREPARE_SCHEMA = "fm-discord-conversation-console.prepared-request.v1"
DEFAULT_PREPARE_TIMEOUT_SECONDS = 4.0
MAX_PREPARE_TIMEOUT_SECONDS = 60.0
DEFAULT_PREPARE_MAX_FACTS = 5
MIN_PREPARE_FACTS = 3
MAX_PREPARE_FACTS = 5
PREPARE_MAX_RECORDS = 5000
PREPARE_INTENTS = ("state_question", "new_work", "decision_answer", "chat")
PREPARE_ENV_TIMEOUT = "FM_JV_PREPARE_TIMEOUT"
# The candidate lists the model may select from are bounded, so one message can
# never carry an unbounded request, and every packet field stays short because
# a note body is read by a session with finite context.
MAX_PREPARE_MESSAGE_CHARS = 4000
MAX_PREPARE_CANDIDATE_TASKS = 40
MAX_PREPARE_PR_URLS = 3
MAX_PREPARE_DATES = 3
PREPARE_ASK_MAX_CHARS = 600
PREPARE_FACT_MAX_CHARS = 240
PREPARE_SUMMARY_MAX_CHARS = 200
PREPARE_PROJECT_LINE_RE = re.compile(r"^- (\S+) \[([^\]]*)\] - (.*)$")
PREPARE_PR_URL_RE = re.compile(r"https?://[^\s<>()]*?/pull/\d+")
PREPARE_DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")

# Captain-facing reply presentation. Discord chat is read on a phone, so the
# reply path renders one deterministic shape - a short bold label per section,
# "- " bullet lines, a blank line between sections, and a URL left intact - and
# enforces a hard character bound instead of trusting the prose to stay short.
# Discord rejects a message body above 2000 characters, so the bound can never
# exceed that; it is deliberately smaller than the hard limit.
DEFAULT_REPLY_MAX_CHARS = 1900
MAX_REPLY_CHARS = 2000
MIN_REPLY_MAX_CHARS = 100
REPLY_LABEL_MAX_CHARS = 80
# The raw answer file may be longer than one Discord message because the reply
# path renders and trims it; this only bounds a pathologically large file.
MAX_REPLY_RAW_CHARS = 20000
MAX_REPLY_RAW_BYTES = 80000
REPLY_BULLET_RE = re.compile(r"^\s*(?:[-*\u2022]|\d+[.)])\s+(.*)$")
REPLY_URL_RE = re.compile(r"https?://[^\s<>()]+")
# Action cards. A captain-facing decision, blocker, or clarification card is one
# Discord message carrying up to five labelled option buttons. Discord posts
# buttons as a ``components`` array and delivers every press as a gateway
# ``INTERACTION_CREATE`` dispatch, which is answered through the interaction
# callback - a deferred update followed by an edit of the card message - so a
# press never shows "interaction failed". The caller supplies the option labels
# and values; the card path never invents an option from prose. A card is only
# posted while its task is still an open captain call - the authoritative hold
# state, not the card's prose - so every button on a posted card can validate. A
# press records the captain's answer through the same keyed-answer intake a typed
# reply uses (bin/fm-captain-hold.sh answer, or hold --until for "later"), and
# the card is edited to show the recorded answer with its buttons disabled.
CARD_SCHEMA = "fm-discord-conversation-console.card.v1"
CARD_INTERACTION_SCHEMA = "fm-discord-conversation-console.card-interaction.v1"
CARD_CUSTOM_ID_PREFIX = "fmcard"
CARD_ID_HEX_CHARS = 16
MAX_CARD_OPTIONS = 5
MAX_CARD_BODY_CHARS = 1700
MAX_CARD_HINT_CHARS = 200
MAX_CARD_LABEL_CHARS = 80
MAX_CARD_VALUE_CHARS = 1000
CARD_ACTIONS = ("answer", "release", "later", "chat")
CARD_KIND_TASK = "task"
CARD_KIND_TRANSCRIPT = "transcript"
CARD_KINDS = (CARD_KIND_TASK, CARD_KIND_TRANSCRIPT)
# The captain-interaction shapes a card can carry, and the explicit trigger
# mapping from a shape to the card it produces. Every shape in this mapping
# produces exactly one card; a shape absent from it produces none, so carding a
# new interaction is a deliberate edit here rather than an implicit side effect.
# The five shapes the console cards are a held decision, a blocker, a
# clarification question, a projection choice, and a free request. A card always
# accompanies the interaction's console reply; it never replaces the reply text.
CARD_TYPES = ("decision", "blocker", "clarification", "projection", "free_request")
DEFAULT_CARD_TYPE = "decision"
INTERACTION_CARD_TRIGGERS = {
    "decision": "decision",
    "blocker": "blocker",
    "clarification": "clarification",
    "projection": "projection",
    "free_request": "free_request",
}
# The uncertain reading's confirmation card maps its three buttons onto the
# existing card actions rather than inventing a fourth: the reading as heard is
# the answer, the correction is the free-form chat option, and the discard is
# the release option that drops the reading without deleting anything.
TRANSCRIPT_CARD_CONFIRM_LABEL = "C'est bien \u00e7a"
TRANSCRIPT_CARD_CORRECT_LABEL = "Je corrige"
TRANSCRIPT_CARD_DISCARD_LABEL = "\u00c0 jeter"
TRANSCRIPT_CARD_HINT = "Ou r\u00e9ponds directement dans la conversation."
TRANSCRIPT_CARD_CONTEXT = (
    "Deux lectures du m\u00eame audio divergent : confirme la lecture, corrige-la, ou jette-la."
)
TRANSCRIPT_CARD_CONFIRM_STYLE = 3
TRANSCRIPT_CARD_CORRECT_STYLE = 2
TRANSCRIPT_CARD_DISCARD_STYLE = 4
# Discord button styles: 1 primary, 2 secondary, 3 success, 4 danger.
CARD_STYLE_BY_ACTION = {"answer": 1, "release": 3, "later": 2, "chat": 2}
CARD_BUTTON_STYLES = (1, 2, 3, 4)
CARD_ID_RE = re.compile(r"^[0-9a-f]{%d}$" % CARD_ID_HEX_CHARS)
CARD_CUSTOM_ID_RE = re.compile(r"^" + CARD_CUSTOM_ID_PREFIX + r":([0-9a-f]{%d}):([0-%d])$" % (CARD_ID_HEX_CHARS, MAX_CARD_OPTIONS - 1))
# Discord component-interaction plumbing. A press is acknowledged through the
# interaction callback with type 6, which defers the card edit; no other callback
# is sent, because Discord answers a callback only once. Every later message
# travels the interaction webhook, and flag 64 keeps a follow-up private to the
# presser.
CARD_INTERACTION_COMPONENT = 3
CARD_CALLBACK_DEFERRED_UPDATE = 6
CARD_EPHEMERAL_FLAG = 64
CARD_CALLBACK_TIMEOUT_SECONDS = 20.0
# The first acknowledgement must reach Discord before its 3-second interaction
# window closes, so it gets its own short bound and is never retried; every
# later edit or follow-up uses the general callback bound.
CARD_ACK_TIMEOUT_SECONDS = 2.5
CARD_ANSWER_TIMEOUT_SECONDS = 120.0
# A validated press appends exactly one durable wake through the same
# captain-inbox seam a typed message uses, so firstmate's ordinary supervision
# picks the recorded answer up without the captain saying anything in chat. The
# interaction id is the inbox external id, which is what makes a repeated
# delivery append no second wake.
CARD_WAKE_SOURCE = "discord-card"
CARD_WAKE_TIMEOUT_SECONDS = 30.0
# One bounded escalation for a held card left unanswered in its originating
# conversation. The delay is the documented window the card stays only there;
# after it, the same durable card identity is mirrored once into the dedicated
# #blocages channel - never a loop - and the scan itself runs at most once per
# bounded interval from the permanent-connection loop.
CARD_ESCALATION_DELAY_SECONDS = 24 * 60 * 60.0
CARD_ESCALATION_SCAN_INTERVAL_SECONDS = 600.0
# The dedicated channel an unanswered card is mirrored into. The config's
# cards.escalation_channel_id overrides it; a home that leaves it unset records
# an honest delivery gap instead of guessing a channel.
DEFAULT_CARD_ESCALATION_CHANNEL_ID = "1548332678233718807"
MAX_CARD_INTERACTION_RECORDS = 5000

# The latency journal. One bounded record per captured captain request records
# the five measured stages, so bin/fm-discord-conversation-console.sh status and
# the `latency` subcommand can report them without contacting Discord. The
# Discord-creation, ingest, capture and answer timestamps are written here by
# the console; the wake-delivery and session-activation timestamps are read from
# the durable watcher/inbox markers the console's own capture path produces.
LATENCY_MAX_RECORDS = 5000
DEFAULT_LATENCY_REPORT_ROWS = 20
# Bounded delivery-gap journal: a silent fall back to polling must stay visible.
DELIVERY_GAP_MAX_RECORDS = 200

# The typing indicator. Discord expires a typing state after about ten seconds,
# so a full-turn message needs a bounded keeper that re-emits it while firstmate
# works and stops the moment the answer is posted. The keeper is a short-lived
# detached process with a hard deadline and a durable stop marker, never an
# unbounded loop, and it is started only for a full turn.
DEFAULT_TYPING_INTERVAL_SECONDS = 8.0
DEFAULT_TYPING_MAX_SECONDS = 900.0
MIN_TYPING_INTERVAL_SECONDS = 1.0
MAX_TYPING_INTERVAL_SECONDS = 60.0
MIN_TYPING_MAX_SECONDS = 30.0
MAX_TYPING_MAX_SECONDS = 3600.0

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

# The native Pi session mirror. The captain's terminal Pi session is mirrored
# into one configured #firstmate channel through this console's own bot
# identity, so no second bot or webhook identity is introduced. The capability
# reuses the delivery discipline the other mirrors already have: the caller
# supplies a durable item identity, the shared nonce-keyed receipt makes the
# post exactly-once across restarts and replays, the rendered body is cut to a
# configured bound so one item can never exceed one Discord message, and an
# empty item is refused before any post. The channel and the switch are config,
# never code. The channel and the whole capability default to off.
MIRROR_CURSOR_SCHEMA = "fm-discord-conversation-console.mirror-cursor.v1"
MIRROR_TAGS = ("captain", "main")
DEFAULT_MIRROR_MAX_CHARS = 1800
MIN_MIRROR_MAX_CHARS = 100
# The raw item may be longer than one Discord message because the mirror path
# bounds and truncates before posting; this only refuses a pathologically large
# hand-written file.
MAX_MIRROR_RAW_CHARS = 20000
MAX_MIRROR_RAW_BYTES = 80000
# The durable item identity the caller passes. It is a position in the source,
# never the item's text, so two identical lines delivered from two positions
# still post twice while one position delivered twice posts once.
MIRROR_ITEM_KEY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$")
# A truncated item keeps its head and its tail, with the omission stated in
# place, so a bounded post is visibly bounded rather than silently partial.
MIRROR_TRUNCATION = "[mirror truncated: %d characters omitted]"


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


def card_delay_seconds(value: Any) -> float:
    """Resolve the card escalation delay, allowing zero for focused tests.

    The configured value is the default; FM_CONSOLE_CARD_ESCALATION_DELAY
    overrides it so a test can make every posted card immediately eligible.
    """
    override = os.environ.get("FM_CONSOLE_CARD_ESCALATION_DELAY")
    candidate: Any = override if override is not None else value
    if isinstance(candidate, str):
        try:
            candidate = float(candidate)
        except ValueError as exc:
            raise FMError("cards.escalation_delay_seconds must be a number") from exc
    if isinstance(candidate, bool) or not isinstance(candidate, (int, float)) or candidate < 0:
        raise FMError("cards.escalation_delay_seconds must be zero or a positive number")
    return float(candidate)


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
        self.reply_max_chars = fwl.validate_positive_json_integer(
            bounds.get("reply_max_chars", DEFAULT_REPLY_MAX_CHARS),
            "bounds.reply_max_chars",
            MAX_REPLY_CHARS,
        )
        if self.reply_max_chars < MIN_REPLY_MAX_CHARS:
            raise FMError("bounds.reply_max_chars must be at least %d" % MIN_REPLY_MAX_CHARS)
        self.live_polling_enabled = fwl.bool_from_path(raw, ["live.polling", "approvals.live_polling", "live_polling"], False)
        self.live_posting_enabled = fwl.bool_from_path(raw, ["live.posting", "approvals.live_posting", "live_posting"], False)
        self.live_gateway_enabled = fwl.bool_from_path(raw, ["live.gateway", "approvals.live_gateway", "live_gateway"], False)
        cards = raw.get("cards") if isinstance(raw.get("cards"), dict) else {}
        self.card_escalation_channel_id = (
            fwl.validate_snowflake(
                cards.get("escalation_channel_id") or os.environ.get("FM_CONSOLE_CARD_ESCALATION_CHANNEL"),
                "cards.escalation_channel_id",
                required=False,
            )
            or ""
        )
        self.card_escalation_delay_seconds = card_delay_seconds(
            cards.get("escalation_delay_seconds", CARD_ESCALATION_DELAY_SECONDS)
        )
        mirror = raw.get("mirror") if isinstance(raw.get("mirror"), dict) else {}
        self.mirror_enabled = fwl.bool_from_path(raw, ["mirror.enabled", "mirror_enabled"], False)
        self.mirror_channel_id = (
            fwl.validate_snowflake(mirror.get("channel_id"), "mirror.channel_id", required=False) or ""
        )
        self.mirror_max_chars = fwl.validate_positive_json_integer(
            mirror.get("max_chars", DEFAULT_MIRROR_MAX_CHARS),
            "mirror.max_chars",
            MAX_REPLY_CHARS,
        )
        if self.mirror_max_chars < MIN_MIRROR_MAX_CHARS:
            raise FMError("mirror.max_chars must be at least %d" % MIN_MIRROR_MAX_CHARS)
        # The channel is only required once the mirror is on, so shipping the
        # capability off-by-default never invalidates an existing config. When
        # it is on, the target must be one of the configured #firstmate
        # channels rather than any channel the code happens to be handed.
        if self.mirror_enabled:
            if not self.mirror_channel_id:
                raise FMError("mirror.channel_id must name the #firstmate channel the session mirror posts into")
            if self.channel_for_id(self.mirror_channel_id) is None:
                raise FMError("mirror.channel_id is not one of the configured #firstmate channels")
        fast_path = raw.get("fast_path") if isinstance(raw.get("fast_path"), dict) else {}
        self.fast_path_enabled = fwl.bool_from_path(raw, ["fast_path.enabled", "fast_path_enabled"], False)
        self.fast_path_answers_enabled = fwl.bool_from_path(raw, ["fast_path.answers", "fast_path_answers"], True)
        ack_text = fast_path.get("acknowledgement")
        if ack_text is None:
            ack_text = DEFAULT_FAST_PATH_ACK
        if not isinstance(ack_text, str) or not ack_text.strip():
            raise FMError("fast_path.acknowledgement must be a non-empty string")
        if len(ack_text.strip()) > 300:
            raise FMError("fast_path.acknowledgement must be 300 characters or fewer")
        for marker in REFUSED_MARKERS:
            if marker in ack_text:
                raise FMError("fast_path.acknowledgement must not contain operational text")
        self.fast_path_ack_text = ack_text.strip()
        self.fast_path_ack_enabled = fwl.bool_from_path(
            raw, ["fast_path.acknowledgement_enabled", "fast_path_acknowledgement_enabled"], True
        )
        classifier = fast_path.get("classifier_command")
        if classifier is None or classifier == "":
            self.fast_path_classifier = (SCRIPT_DIR / "fm-jev-console-route.sh").resolve()
        elif isinstance(classifier, str):
            self.fast_path_classifier = Path(classifier).expanduser().resolve()
        else:
            raise FMError("fast_path.classifier_command must be a path string")
        self.fast_path_timeout = env_float(
            CLASSIFIER_ENV_TIMEOUT,
            fast_path.get("classifier_timeout_seconds", DEFAULT_FAST_PATH_TIMEOUT_SECONDS),
            "fast_path.classifier_timeout_seconds",
        )
        if self.fast_path_timeout > 60.0:
            raise FMError("fast_path.classifier_timeout_seconds must be at most 60")
        self.fast_path_max_answer_chars = fwl.validate_positive_json_integer(
            fast_path.get("max_answer_chars", DEFAULT_FAST_PATH_MAX_ANSWER_CHARS),
            "fast_path.max_answer_chars",
            2000,
        )
        self.fast_path_typing_enabled = fwl.bool_from_path(
            raw, ["fast_path.typing", "fast_path_typing"], True
        )
        self.fast_path_typing_interval = env_float(
            "FM_CONSOLE_TYPING_INTERVAL",
            fast_path.get("typing_interval_seconds", DEFAULT_TYPING_INTERVAL_SECONDS),
            "fast_path.typing_interval_seconds",
        )
        if not MIN_TYPING_INTERVAL_SECONDS <= self.fast_path_typing_interval <= MAX_TYPING_INTERVAL_SECONDS:
            raise FMError(
                "fast_path.typing_interval_seconds must be between %g and %g"
                % (MIN_TYPING_INTERVAL_SECONDS, MAX_TYPING_INTERVAL_SECONDS)
            )
        self.fast_path_typing_max_seconds = env_float(
            "FM_CONSOLE_TYPING_MAX_SECONDS",
            fast_path.get("typing_max_seconds", DEFAULT_TYPING_MAX_SECONDS),
            "fast_path.typing_max_seconds",
        )
        if not MIN_TYPING_MAX_SECONDS <= self.fast_path_typing_max_seconds <= MAX_TYPING_MAX_SECONDS:
            raise FMError(
                "fast_path.typing_max_seconds must be between %g and %g"
                % (MIN_TYPING_MAX_SECONDS, MAX_TYPING_MAX_SECONDS)
            )
        if not self.fast_path_ack_enabled and not self.fast_path_typing_enabled:
            raise FMError(
                "fast_path cannot disable both the acknowledgement and the typing indicator; "
                "at least one visible sign of activity is required"
            )
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
        self._parse_audio(raw)
        self._parse_transcription(raw)
        self._parse_prepare(raw)

    def _parse_prepare(self, raw: Dict[str, Any]) -> None:
        """The advisory request-preparation step; off by default.

        A disabled step is the whole fallback: no packet is built, no preparer
        is run, and the durable note keeps the raw message exactly as it does
        today.
        """
        prepare = raw.get("prepare") if isinstance(raw.get("prepare"), dict) else {}
        self.prepare_enabled = fwl.bool_from_path(raw, ["prepare.enabled", "prepare_enabled"], False)
        classifier = prepare.get("classifier_command")
        if classifier is None or classifier == "":
            self.prepare_classifier = (SCRIPT_DIR / "fm-jev-console-prepare.sh").resolve()
        elif isinstance(classifier, str):
            self.prepare_classifier = Path(classifier).expanduser().resolve()
        else:
            raise FMError("prepare.classifier_command must be a path string")
        self.prepare_timeout = env_float(
            PREPARE_ENV_TIMEOUT,
            prepare.get("timeout_seconds", DEFAULT_PREPARE_TIMEOUT_SECONDS),
            "prepare.timeout_seconds",
        )
        if self.prepare_timeout > MAX_PREPARE_TIMEOUT_SECONDS:
            raise FMError(
                "prepare.timeout_seconds must be at most %g" % MAX_PREPARE_TIMEOUT_SECONDS
            )
        self.prepare_max_facts = fwl.validate_positive_json_integer(
            prepare.get("max_facts", DEFAULT_PREPARE_MAX_FACTS),
            "prepare.max_facts",
            MAX_PREPARE_FACTS,
        )
        if self.prepare_max_facts < MIN_PREPARE_FACTS:
            raise FMError("prepare.max_facts must be at least %d" % MIN_PREPARE_FACTS)

    def _parse_audio(self, raw: Dict[str, Any]) -> None:
        """The Discord-CDN allowlist and bounds shared with the workspace schema."""
        audio = raw.get("audio") if isinstance(raw.get("audio"), dict) else {}
        self.audio_max_bytes = fwl.validate_positive_json_integer(
            audio.get("max_bytes", DEFAULT_AUDIO_MAX_BYTES), "audio.max_bytes"
        )
        max_duration = audio.get("max_duration_secs", DEFAULT_AUDIO_MAX_DURATION_SECONDS)
        if isinstance(max_duration, bool) or not isinstance(max_duration, (int, float)):
            raise FMError("audio.max_duration_secs must be a positive finite number")
        self.audio_max_duration_secs = float(max_duration)
        if not (self.audio_max_duration_secs > 0):
            raise FMError("audio.max_duration_secs must be a positive finite number")
        self.audio_delete_raw = fwl.validate_bool(
            audio.get("delete_temporary_raw", audio.get("delete_temporary_audio", True)),
            "audio.delete_temporary_raw",
            default=True,
        )
        self.audio_cdn_hosts: List[str] = []
        seen: set = set()
        for index, value in enumerate(fwl.as_list(audio.get("allowed_cdn_hosts", fwl.DEFAULT_CDN_HOSTS), "audio.allowed_cdn_hosts")):
            label = f"audio.allowed_cdn_hosts[{index}]"
            if not isinstance(value, str) or not value or value != value.lower() or len(value) > 253:
                raise FMError(f"{label} must be a normalized lowercase hostname")
            if any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part) for part in value.split(".")):
                raise FMError(f"{label} must be a normalized lowercase hostname")
            if value in seen:
                raise FMError(f"{label} duplicates an earlier hostname")
            seen.add(value)
            self.audio_cdn_hosts.append(value)
        if not self.audio_cdn_hosts:
            raise FMError("audio.allowed_cdn_hosts must not be empty")
        # fwl.validate_audio_attachment reads these names on a workspace-shaped
        # config; the console config exposes the same names so one validator
        # owns the CDN, size, duration, and MIME rules.
        self.cdn_hosts = self.audio_cdn_hosts

    def _parse_transcription(self, raw: Dict[str, Any]) -> None:
        tx = raw.get("transcription") if isinstance(raw.get("transcription"), dict) else {}
        # On by default: the captain asked to talk instead of type, and a missing
        # key still yields one honest line rather than silence.
        self.transcription_enabled = fwl.bool_from_path(raw, ["transcription.enabled", "transcription_enabled"], True)
        provider = tx.get("provider", "groq")
        if not isinstance(provider, str) or provider not in ("disabled", "groq"):
            raise FMError("transcription.provider must be disabled or groq")
        self.transcription_provider = provider
        key_env = tx.get("api_key", DEFAULT_TRANSCRIPTION_KEY_ENV)
        if not isinstance(key_env, str) or not fwl.SECRET_REFERENCE_RE.fullmatch(key_env):
            raise FMError("transcription.api_key must be an uppercase secret reference name")
        self.transcription_key_env = key_env
        try:
            self.transcription_model = whisper.validate_model(str(tx.get("model", DEFAULT_TRANSCRIPTION_MODEL)))
            self.transcription_language = whisper.validate_language(str(tx.get("language", DEFAULT_TRANSCRIPTION_LANGUAGE)))
            self.transcription_prompt = whisper.validate_prompt(str(tx.get("prompt", DEFAULT_TRANSCRIPTION_PROMPT)))
            configured_base = tx.get("base_url", DEFAULT_TRANSCRIPTION_BASE_URL)
            if not isinstance(configured_base, str):
                raise FMError("transcription.base_url must be a string")
            self.transcription_base_url = whisper.api_base_url(configured_base)
        except whisper.GroqError as exc:
            raise FMError(str(exc)) from exc
        self.transcription_timeout = env_float(
            "FM_GROQ_TIMEOUT",
            tx.get("timeout_seconds", DEFAULT_TRANSCRIPTION_TIMEOUT_SECONDS),
            "transcription.timeout_seconds",
        )
        if self.transcription_timeout > whisper.MAX_TIMEOUT_SECONDS:
            raise FMError(f"transcription.timeout_seconds must be at most {whisper.MAX_TIMEOUT_SECONDS:g}")
        prefix = tx.get("transcript_prefix", DEFAULT_TRANSCRIPTION_PREFIX)
        if not isinstance(prefix, str) or len(prefix) > 200:
            raise FMError("transcription.transcript_prefix must be a string of at most 200 characters")
        self.transcription_prefix = prefix
        self.transcription_post_transcript = fwl.bool_from_path(
            raw, ["transcription.post_transcript", "transcription_post_transcript"], True
        )
        # The confidence check costs one extra bounded call, and only on short
        # audio, so it is on by default: a silently wrong transcript is worse
        # than a slower one.
        self.transcription_confidence_check = fwl.bool_from_path(
            raw,
            ["transcription.confidence_check", "transcription_confidence_check"],
            DEFAULT_TRANSCRIPTION_CONFIDENCE_CHECK,
        )
        try:
            self.transcription_confidence_max_seconds = whisper.validate_confidence_max_seconds(
                tx.get("confidence_check_max_seconds", DEFAULT_TRANSCRIPTION_CONFIDENCE_MAX_SECONDS)
            )
        except whisper.GroqError as exc:
            raise FMError(str(exc)) from exc
        # The confirmation card turns the existing "ask the captain to confirm"
        # into one press, and it is on by default because that is the affordance
        # the captain asked for. It posts only where a press could arrive, so a
        # home without the permanent connection keeps today's chat confirmation.
        self.transcription_confirm_card = fwl.bool_from_path(
            raw, ["transcription.confirm_card", "transcription_confirm_card"], True
        )

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
        "mirror": {
            "enabled": False,
            "channel_id": "444444444444444441",
            "max_chars": DEFAULT_MIRROR_MAX_CHARS,
        },
        "cards": {
            "escalation_channel_id": DEFAULT_CARD_ESCALATION_CHANNEL_ID,
            "escalation_delay_seconds": CARD_ESCALATION_DELAY_SECONDS,
        },
        "fast_path": {
            "enabled": False,
            "answers": True,
            "acknowledgement": DEFAULT_FAST_PATH_ACK,
            "acknowledgement_enabled": True,
            "typing": True,
            "typing_interval_seconds": DEFAULT_TYPING_INTERVAL_SECONDS,
            "typing_max_seconds": DEFAULT_TYPING_MAX_SECONDS,
            "classifier_command": "",
            "classifier_timeout_seconds": DEFAULT_FAST_PATH_TIMEOUT_SECONDS,
            "max_answer_chars": DEFAULT_FAST_PATH_MAX_ANSWER_CHARS,
        },
        "gateway": {
            "url": DEFAULT_GATEWAY_URL,
            "intents": DEFAULT_GATEWAY_INTENTS,
            "backoff_base_seconds": DEFAULT_BACKOFF_BASE_SECONDS,
            "backoff_max_seconds": DEFAULT_BACKOFF_MAX_SECONDS,
            "fallback_poll_seconds": DEFAULT_FALLBACK_POLL_SECONDS,
            "fallback_after_attempts": DEFAULT_FALLBACK_AFTER_ATTEMPTS,
        },
        "prepare": {
            "enabled": False,
            "classifier_command": "",
            "timeout_seconds": DEFAULT_PREPARE_TIMEOUT_SECONDS,
            "max_facts": DEFAULT_PREPARE_MAX_FACTS,
        },
        "audio": {
            "max_bytes": DEFAULT_AUDIO_MAX_BYTES,
            "max_duration_secs": DEFAULT_AUDIO_MAX_DURATION_SECONDS,
            "delete_temporary_raw": True,
            "allowed_cdn_hosts": list(fwl.DEFAULT_CDN_HOSTS),
        },
        "transcription": {
            "enabled": True,
            "provider": "groq",
            "api_key": DEFAULT_TRANSCRIPTION_KEY_ENV,
            "model": DEFAULT_TRANSCRIPTION_MODEL,
            "language": DEFAULT_TRANSCRIPTION_LANGUAGE,
            "prompt": DEFAULT_TRANSCRIPTION_PROMPT,
            "base_url": DEFAULT_TRANSCRIPTION_BASE_URL,
            "timeout_seconds": DEFAULT_TRANSCRIPTION_TIMEOUT_SECONDS,
            "transcript_prefix": DEFAULT_TRANSCRIPTION_PREFIX,
            "post_transcript": True,
            "confidence_check": DEFAULT_TRANSCRIPTION_CONFIDENCE_CHECK,
            "confidence_check_max_seconds": DEFAULT_TRANSCRIPTION_CONFIDENCE_MAX_SECONDS,
            "confirm_card": True,
        },
        "bounds": {
            "max_messages_per_channel": DEFAULT_MAX_MESSAGES,
            "max_threads_per_pass": DEFAULT_MAX_THREADS,
            "max_ignored_records": DEFAULT_MAX_IGNORED,
            "reply_max_chars": DEFAULT_REPLY_MAX_CHARS,
        },
    }


# ---------------------------------------------------------------------------
# State paths
# ---------------------------------------------------------------------------

def console_state_path(env: "fwl.Env", *parts: str) -> Path:
    return fwl.discord_state_path(env, CONSOLE_STATE_SUBDIR, *parts)


def mirror_cursor_path(env: "fwl.Env") -> Path:
    return console_state_path(env, "mirror-cursor.json")


def read_mirror_cursor(env: "fwl.Env") -> Optional[Dict[str, Any]]:
    """Read the extension's durable mirror cursor for a report; never raise.

    The console owns this record's shape - the extension is only its writer - so
    a record carrying a different schema reads as no cursor rather than as a
    position this report would then misstate.
    """
    try:
        record = fwl.load_existing_json(mirror_cursor_path(env))
    except FMError:
        return None
    if not isinstance(record, dict) or record.get("schema") != MIRROR_CURSOR_SCHEMA:
        return None
    return record


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


def fast_path_record_path(env: "fwl.Env", kind: str, request_id: str) -> Path:
    """One durable fast-path record, keyed by the request it belongs to."""
    if kind not in ("acks", "answers", "decisions", "audits"):
        raise FMError(f"unknown fast-path record kind: {kind}")
    return console_state_path(env, "fast-path", kind, f"{fwl.sha256_text(request_id)}.json")


def typing_path(env: "fwl.Env", channel_id: str) -> Path:
    return console_state_path(env, "typing", f"{channel_id}.json")


def prepare_outcome_path(env: "fwl.Env", request_id: str) -> Path:
    """One durable preparation outcome per request: the packet, or the fallback."""
    if not request_id:
        raise FMError("a preparation outcome needs a request id")
    return console_state_path(env, "prepare", f"{fwl.sha256_text(request_id)}.json")


def cards_dir(env: "fwl.Env") -> Path:
    return console_state_path(env, "cards")


def card_path(env: "fwl.Env", card_id: str) -> Path:
    if not CARD_ID_RE.fullmatch(card_id):
        raise FMError("card id must be %d lowercase hex characters" % CARD_ID_HEX_CHARS)
    return console_state_path(env, "cards", f"{card_id}.json")


def card_interaction_path(env: "fwl.Env", interaction_id: str) -> Path:
    if not fwl.ID_RE.fullmatch(interaction_id):
        raise FMError("interaction id must be a decimal Discord id")
    return console_state_path(env, "cards", "interactions", f"{interaction_id}.json")


def card_custom_id(card_id: str, index: int) -> str:
    return f"{CARD_CUSTOM_ID_PREFIX}:{card_id}:{index}"


def latency_path(env: "fwl.Env", request_id: str) -> Path:
    """One durable latency journal record, keyed by the captain request."""
    return console_state_path(env, "latency", f"{fwl.sha256_text(request_id)}.json")


def delivery_gaps_path(env: "fwl.Env") -> Path:
    return console_state_path(env, "delivery-gaps.json")


def inbox_marker_path(env: "fwl.Env", name: str) -> Path:
    """The watcher's per-note surfaced marker, named exactly as inbox_surfaced_marker."""
    key = f"inbox:{name}"
    return env.state / (".seen-inbox-" + key.encode("utf-8").hex())


def inbox_ack_path(env: "fwl.Env", note_id: str) -> Path:
    """The acknowledgement marker bin/fm-inbox.sh drain --ack writes."""
    return env.state / "inbox" / "handled" / f"{note_id}.acked"


def file_mtime_epoch(path: Path) -> Optional[float]:
    try:
        if not path.is_file() or path.is_symlink():
            return None
        return path.stat().st_mtime
    except OSError:
        return None


def read_typing_record(env: "fwl.Env", channel_id: str) -> Optional[Dict[str, Any]]:
    try:
        record = fwl.load_existing_json(typing_path(env, channel_id))
    except FMError:
        return None
    return record if isinstance(record, dict) else None


def pid_alive(pid: Any) -> bool:
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def stop_typing(env: "fwl.Env", channel_id: str) -> bool:
    """Remove the typing marker for one channel so its keeper stops; idempotent."""
    path = typing_path(env, channel_id)
    with fwl.state_transaction(env):
        if not path.exists() or path.is_symlink():
            return False
        try:
            path.unlink()
        except FileNotFoundError:
            return False
    return True


def ensure_typing(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any]) -> None:
    """Start or refresh the bounded typing keeper for this channel, once per request.

    The keeper is a short-lived detached process: it re-emits the Discord typing
    indicator every interval until the durable stop marker is removed (by the
    reply command) or its hard deadline passes. Starting it only on a new
    full-turn decision keeps a replayed capture from restarting it.
    """
    if not cfg.fast_path_typing_enabled:
        return
    channel_id = str(event.get("channel_id") or "")
    request_id = str(event.get("request_id") or "")
    if not channel_id.isdigit() or not request_id:
        return
    now = time.time()
    max_seconds = cfg.fast_path_typing_max_seconds
    with fwl.state_transaction(env):
        existing = read_typing_record(env, channel_id)
        if isinstance(existing, dict):
            requests = [r for r in existing.get("request_ids") or [] if isinstance(r, str)]
            expires_at = existing.get("expires_at")
            spawned_epoch = existing.get("spawned_epoch")
            starting = (
                existing.get("pid") in (0, None)
                and isinstance(spawned_epoch, (int, float))
                and now - spawned_epoch < 10
            )
            live = (pid_alive(existing.get("pid")) or starting) and isinstance(expires_at, (int, float)) and expires_at > now
            if live:
                if request_id not in requests:
                    requests.append(request_id)
                fwl.atomic_json(
                    typing_path(env, channel_id),
                    {
                        "schema": TYPING_SCHEMA,
                        "channel_id": channel_id,
                        "request_ids": requests[-20:],
                        "pid": existing.get("pid"),
                        "started_at": existing.get("started_at") or fwl.utc_now(),
                        "expires_at": min(now + max_seconds, float(expires_at)),
                        "spawned_epoch": spawned_epoch,
                        "updated_at": fwl.utc_now(),
                    },
                )
                return
        fwl.atomic_json(
            typing_path(env, channel_id),
            {
                "schema": TYPING_SCHEMA,
                "channel_id": channel_id,
                "request_ids": [request_id],
                "pid": 0,
                "started_at": fwl.utc_now(),
                "expires_at": now + max_seconds,
                "spawned_epoch": now,
                "updated_at": fwl.utc_now(),
            },
        )
        command = [
            str(env.script_dir / "fm-discord-conversation-console.sh"),
            "typing",
            "--config",
            str(cfg.path),
            "--channel",
            channel_id,
        ]
        try:
            subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=True,
            )
        except OSError:
            # A keeper that cannot start must not fail the capture; the reply
            # command's stop is a no-op and the marker expires on its own.
            pass


def load_fast_path_record(env: "fwl.Env", kind: str, request_id: str) -> Optional[Dict[str, Any]]:
    try:
        record = fwl.load_existing_json(fast_path_record_path(env, kind, request_id))
    except FMError:
        return None
    return record if isinstance(record, dict) else None


def store_fast_path_record(env: "fwl.Env", kind: str, request_id: str, record: Dict[str, Any]) -> None:
    stored = dict(record)
    stored.update({"schema": FAST_PATH_SCHEMA, "kind": kind, "request_id": request_id, "recorded_at": fwl.utc_now()})
    path = fast_path_record_path(env, kind, request_id)
    with fwl.state_transaction(env):
        fwl.atomic_json(path, stored)
        prune_fast_path_records(path.parent)


def prune_fast_path_records(directory: Path) -> None:
    """Keep only the newest FAST_PATH_MAX_RECORDS records in one kind's directory."""
    try:
        records = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    except OSError:
        return
    for stale in records[FAST_PATH_MAX_RECORDS:]:
        try:
            stale.unlink()
        except OSError:
            pass


def load_prepare_outcome(env: "fwl.Env", request_id: str) -> Optional[Dict[str, Any]]:
    if not request_id:
        return None
    try:
        record = fwl.load_existing_json(prepare_outcome_path(env, request_id))
    except FMError:
        return None
    return record if isinstance(record, dict) else None


def store_prepare_outcome(env: "fwl.Env", request_id: str, record: Dict[str, Any]) -> None:
    """Write one preparation outcome durably; a failed write never fails a capture."""
    if not request_id:
        return
    stored = dict(record)
    stored.update({"schema": PREPARE_SCHEMA, "request_id": request_id, "recorded_at": fwl.utc_now()})
    path = prepare_outcome_path(env, request_id)
    try:
        with fwl.state_transaction(env):
            fwl.atomic_json(path, stored)
            prune_prepare_outcomes(path.parent)
    except FMError:
        return


def prune_prepare_outcomes(directory: Path) -> None:
    try:
        records = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    except OSError:
        return
    for stale in records[PREPARE_MAX_RECORDS:]:
        try:
            stale.unlink()
        except OSError:
            pass


def prepare_counts(env: "fwl.Env") -> Dict[str, Any]:
    """Read-only prepared/fallen-back tallies and the newest outcome, for status."""
    result: Dict[str, Any] = {"prepared": 0, "fallback": 0, "last": {}}
    directory = console_state_path(env, "prepare")
    newest: Optional[Path] = None
    newest_mtime = -1.0
    try:
        if not directory.is_dir():
            return result
        for path in directory.glob("*.json"):
            try:
                record = fwl.load_existing_json(path)
                mtime = path.stat().st_mtime
            except (FMError, OSError):
                continue
            if not isinstance(record, dict):
                continue
            if record.get("status") == "prepared":
                result["prepared"] += 1
            else:
                result["fallback"] += 1
            if mtime > newest_mtime:
                newest_mtime = mtime
                newest = path
    except OSError:
        return result
    if newest is not None:
        try:
            record = fwl.load_existing_json(newest)
        except FMError:
            record = None
        if isinstance(record, dict):
            result["last"] = record
    return result


def transcript_record_path(env: "fwl.Env", request_id: str) -> Path:
    return console_state_path(env, "transcripts", f"{fwl.sha256_text(request_id)}.json")


def load_transcript_record(env: "fwl.Env", request_id: str) -> Optional[Dict[str, Any]]:
    if not request_id:
        return None
    try:
        record = fwl.load_existing_json(transcript_record_path(env, request_id))
    except FMError:
        return None
    return record if isinstance(record, dict) else None


def store_transcript_record(env: "fwl.Env", request_id: str, record: Dict[str, Any]) -> None:
    stored = dict(record)
    stored.update({"schema": TRANSCRIPT_SCHEMA, "request_id": request_id, "recorded_at": fwl.utc_now()})
    path = transcript_record_path(env, request_id)
    with fwl.state_transaction(env):
        fwl.atomic_json(path, stored)
        prune_transcript_records(path.parent)


def prune_transcript_records(directory: Path) -> None:
    try:
        records = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    except OSError:
        return
    for stale in records[MAX_TRANSCRIPT_RECORDS:]:
        try:
            stale.unlink()
        except OSError:
            pass


def transcript_counts(env: "fwl.Env") -> Dict[str, int]:
    directory = console_state_path(env, "transcripts")
    ok = failed = 0
    if directory.is_dir():
        for path in directory.glob("*.json"):
            try:
                record = fwl.load_existing_json(path)
            except FMError:
                continue
            if isinstance(record, dict):
                if record.get("status") == "ok":
                    ok += 1
                else:
                    failed += 1
    return {"ok": ok, "failed": failed}


def fast_path_counts(env: "fwl.Env") -> Dict[str, Any]:
    """Read-only counts and the most recent audit, for status."""
    result: Dict[str, Any] = {"acks": 0, "audits": 0, "last": {}}
    for kind, key in (("acks", "acks"), ("audits", "audits")):
        directory = console_state_path(env, "fast-path", kind)
        try:
            result[key] = len(list(directory.glob("*.json"))) if directory.is_dir() else 0
        except OSError:
            result[key] = 0
    directory = console_state_path(env, "fast-path", "audits")
    newest: Optional[Path] = None
    newest_mtime = -1.0
    try:
        if directory.is_dir():
            for path in directory.glob("*.json"):
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime > newest_mtime:
                    newest_mtime = mtime
                    newest = path
    except OSError:
        newest = None
    if newest is not None:
        try:
            record = fwl.load_existing_json(newest)
        except FMError:
            record = None
        if isinstance(record, dict):
            result["last"] = record
    return result


# ---------------------------------------------------------------------------
# Latency journal
#
# One durable record per captured captain request. The console writes the
# timestamps it owns (Discord creation, transport ingest, capture, answer); the
# wake-delivery and session-activation timestamps are read back from the
# durable markers the watcher and the inbox acknowledgement already write, so
# the journal never invents a stage it cannot observe.
# ---------------------------------------------------------------------------

def parse_discord_epoch(message_id: Any, timestamp: Any) -> Optional[float]:
    """The Discord creation time in epoch seconds, from the payload or snowflake."""
    if isinstance(timestamp, str) and timestamp.strip():
        text = timestamp.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            parsed = datetime.datetime.fromisoformat(text)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=datetime.timezone.utc)
            return parsed.timestamp()
        except ValueError:
            pass
    text = str(message_id or "")
    if text.isdigit():
        return ((int(text) >> 22) + 1420070400000) / 1000.0
    return None


def _epoch_float(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def read_latency_record(env: "fwl.Env", request_id: str) -> Optional[Dict[str, Any]]:
    try:
        record = fwl.load_existing_json(latency_path(env, request_id))
    except FMError:
        return None
    return record if isinstance(record, dict) else None


def update_latency(env: "fwl.Env", request_id: str, **fields: Any) -> None:
    """Merge one stage into this request's durable latency record.

    A missing request id is a no-op (an event with no stable identity is never
    tracked), and a failed write never fails the capture it is describing.
    """
    if not request_id:
        return
    path = latency_path(env, request_id)
    try:
        with fwl.state_transaction(env):
            record: Dict[str, Any] = {}
            if path.exists():
                loaded = fwl.load_existing_json(path)
                if isinstance(loaded, dict):
                    record = loaded
            record.update(fields)
            record.update({"schema": LATENCY_SCHEMA, "request_id": request_id, "updated_at": fwl.utc_now()})
            fwl.atomic_json(path, record)
            prune_latency_records(path.parent)
    except FMError:
        return


def prune_latency_records(directory: Path) -> None:
    try:
        records = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    except OSError:
        return
    for stale in records[LATENCY_MAX_RECORDS:]:
        try:
            stale.unlink()
        except OSError:
            pass


def latency_rows(env: "fwl.Env", limit: int = DEFAULT_LATENCY_REPORT_ROWS) -> List[Dict[str, Any]]:
    """Read-only per-request stage report, newest first, combining every marker."""
    directory = console_state_path(env, "latency")
    records: List[Dict[str, Any]] = []
    try:
        if directory.is_dir():
            for path in directory.glob("*.json"):
                try:
                    loaded = fwl.load_existing_json(path)
                except FMError:
                    continue
                if isinstance(loaded, dict) and loaded.get("request_id"):
                    records.append(loaded)
    except OSError:
        records = []
    records.sort(key=lambda record: _epoch_float(record.get("ingested_at")) or _epoch_float(record.get("captured_at")) or 0.0, reverse=True)
    rows: List[Dict[str, Any]] = []
    for record in records[:limit]:
        note_id = str(record.get("note_id") or "")
        discord_at = parse_discord_epoch(record.get("message_id"), record.get("discord_timestamp"))
        ingested_at = _epoch_float(record.get("ingested_at"))
        captured_at = _epoch_float(record.get("captured_at"))
        delivered_at = file_mtime_epoch(inbox_marker_path(env, note_id)) if note_id else None
        activated_at = file_mtime_epoch(inbox_ack_path(env, note_id)) if note_id else None
        answered_at = _epoch_float(record.get("answered_at"))

        def delta(start: Optional[float], end: Optional[float]) -> Optional[float]:
            if start is None or end is None:
                return None
            return round(end - start, 3)

        rows.append(
            {
                "request_id": str(record.get("request_id") or ""),
                "message_id": str(record.get("message_id") or ""),
                "label": str(record.get("label") or ""),
                "channel_id": str(record.get("channel_id") or ""),
                "transport": str(record.get("transport") or ""),
                "path": str(record.get("path") or ""),
                "note_id": note_id,
                "discord_at": discord_at,
                "ingested_at": ingested_at,
                "captured_at": captured_at,
                "delivered_at": delivered_at,
                "activated_at": activated_at,
                "answered_at": answered_at,
                "prepare_status": str(record.get("prepare_status") or ""),
                "prepare_ms": _epoch_float(record.get("prepare_ms")),
                "stage1_discord_to_console": delta(discord_at, ingested_at),
                "stage2_console_handling": delta(ingested_at, captured_at),
                "stage3_wake": delta(captured_at, delivered_at),
                "stage4_session_activation": delta(delivered_at, activated_at),
                "stage5_turn": delta(activated_at, answered_at),
                "total": delta(discord_at, answered_at),
            }
        )
    return rows


def _median(values: List[float]) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return round(ordered[middle], 3)
    return round((ordered[middle - 1] + ordered[middle]) / 2.0, 3)


def latency_medians(rows: List[Dict[str, Any]]) -> Dict[str, Optional[float]]:
    keys = (
        "stage1_discord_to_console", "stage2_console_handling", "stage3_wake",
        "stage4_session_activation", "stage5_turn", "prepare_ms", "total",
    )
    result: Dict[str, Optional[float]] = {}
    for key in keys:
        values = [float(row[key]) for row in rows if isinstance(row.get(key), (int, float)) and not isinstance(row.get(key), bool)]
        result[key] = _median(values)
    return result


def latency_transport_counts(env: "fwl.Env") -> Dict[str, int]:
    """Read-only transport tally over every journal record, for the gateway proof."""
    counts: Dict[str, int] = {}
    directory = console_state_path(env, "latency")
    try:
        if not directory.is_dir():
            return counts
        for path in directory.glob("*.json"):
            try:
                loaded = fwl.load_existing_json(path)
            except FMError:
                continue
            if not isinstance(loaded, dict):
                continue
            transport = str(loaded.get("transport") or "unknown")
            counts[transport] = counts.get(transport, 0) + 1
    except OSError:
        return counts
    return counts


# ---------------------------------------------------------------------------
# Delivery gaps
# ---------------------------------------------------------------------------

def read_delivery_gaps(env: "fwl.Env") -> List[Dict[str, Any]]:
    try:
        loaded = fwl.load_existing_json(delivery_gaps_path(env))
    except FMError:
        return []
    if isinstance(loaded, dict) and isinstance(loaded.get("gaps"), list):
        return [gap for gap in loaded["gaps"] if isinstance(gap, dict)]
    return []


def record_delivery_gap(env: "fwl.Env", kind: str, detail: str) -> None:
    """Record a visible delivery gap instead of letting the fallback stay silent."""
    try:
        with fwl.state_transaction(env):
            gaps = read_delivery_gaps(env)
            gaps.append({"at": fwl.utc_now(), "epoch": time.time(), "kind": kind, "detail": detail[:500]})
            fwl.atomic_json(
                delivery_gaps_path(env),
                {"schema": DELIVERY_GAP_SCHEMA, "updated_at": fwl.utc_now(), "gaps": gaps[-DELIVERY_GAP_MAX_RECORDS:]},
            )
    except FMError:
        return


def delivery_gap_counts(env: "fwl.Env") -> Dict[str, Any]:
    gaps = read_delivery_gaps(env)
    result: Dict[str, Any] = {"count": len(gaps), "last": gaps[-1] if gaps else {}}
    for kind in ("polling-capture", "gateway-fallback"):
        result[kind] = sum(1 for gap in gaps if gap.get("kind") == kind)
    return result


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

def payload_user_id(payload: Dict[str, Any]) -> str:
    """Resolve a guild or direct payload's user id.

    Discord sends a direct payload's user at the top level and a guild payload's
    user under ``member.user``, so both are consulted; an empty result means the
    payload carried no usable identity and the caller must not treat it as an
    identified non-captain.
    """
    user = payload.get("user")
    if isinstance(user, dict) and str(user.get("id") or ""):
        return str(user["id"])
    member = payload.get("member")
    if isinstance(member, dict):
        member_user = member.get("user")
        if isinstance(member_user, dict) and str(member_user.get("id") or ""):
            return str(member_user["id"])
    return ""


def normalize_message(
    cfg: "ConsoleConfig",
    channel: ConsoleChannel,
    channel_id: str,
    parent_id: str,
    message: Dict[str, Any],
    transport: str = "",
) -> Dict[str, Any]:
    """Classify one Discord message into an accepted text, audio, or ignored event."""
    guild_id = channel.guild_id
    message_id = str(message.get("id") or "")
    author = message.get("author") if isinstance(message.get("author"), dict) else {}
    author_id = str(author.get("id") or message.get("author_id") or "")
    if not author_id:
        # A guild payload may carry the author only under member.user; resolve it
        # before the missing-author branch so a real guild message is never
        # ignored as one from an unknown author.
        author_id = payload_user_id(message)
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
        "transport": transport,
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
    attachments = message.get("attachments") or []
    if not isinstance(attachments, list) or any(not isinstance(item, dict) for item in attachments):
        return ignored_event(base, "invalid-attachments")
    if audio_attachment_present(message, attachments):
        # An audio message with no typed caption becomes an audio event; the
        # transcript is fed back through the text capture path once produced.
        if not content:
            event = dict(base)
            event["kind"] = "audio"
            event["content"] = ""
            event["attachments"] = attachments
            event["flags"] = message.get("flags", 0)
            return event
    if not content:
        return ignored_event(base, "empty-message")
    event = dict(base)
    event["kind"] = "text"
    event["content"] = content
    return event


def audio_attachment_present(message: Dict[str, Any], attachments: List[Dict[str, Any]]) -> bool:
    """Whether Discord marks this message as carrying audio, without validating it.

    Detection is deliberately lenient so an unsupported or oversized audio
    attachment still reaches the transcribe path and earns an honest reply
    instead of being silently ignored.
    """
    flags = message.get("flags", 0)
    if isinstance(flags, int) and not isinstance(flags, bool) and flags & fwl.VOICE_MESSAGE_FLAG:
        return True
    for attachment in attachments:
        ctype = fwl.attachment_content_type(attachment)
        ext = Path(str(attachment.get("filename") or "")).suffix.lower()
        if ctype.startswith(fwl.ALLOWED_AUDIO_MIME_PREFIXES) or ext in fwl.ALLOWED_AUDIO_EXTENSIONS:
            return True
    return False


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
        "transcript", "transcript_confidence",
        "transport",
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
    if event.get("transcript"):
        lines.append("transcript: Groq Whisper large-v3 (fr) of the captain's audio message")
        if transcript_is_uncertain(event):
            confidence = event.get("transcript_confidence")
            lines.append(f"transcription-uncertain: {transcript_uncertainty_reason(confidence)}")
            alternate = confidence.get("alternate")
            if isinstance(alternate, str) and alternate:
                lines.append(f"transcription-second-reading: {alternate}")
            lines.append(
                "ask the captain to confirm the spoken words before answering; "
                "do not act on a single uncertain reading"
            )
            card_id = str(event.get("transcript_confirm_card") or "")
            if card_id:
                lines.append(
                    "transcription-confirmation-card: "
                    f"the conversation carries a card for this reading (card {card_id}) whose press "
                    "confirms it, asks for a correction in chat, or discards it, and appends its own durable wake"
                )
    lines.append("")
    packet = event.get("prepared_packet")
    if isinstance(packet, dict):
        # The packet is advisory and the raw message is authoritative, so the
        # two always travel together and in that order: the derived reading
        # first, then the captain's own words under an explicit heading that
        # says which one wins.
        lines.append("PREPARED REQUEST (advisory, derived from the raw message below)")
        lines.extend(render_prepared_packet(packet))
        lines.append("")
        lines.append("RAW MESSAGE (authoritative)")
    lines.append(str(event.get("content") or ""))
    lines.append("")
    lines.append(
        "answer with: bin/fm-discord-conversation-console.sh reply --request-id "
        f"{event.get('request_id')} --text-file <answer-file>"
    )
    # A captain interaction that supports a card carries one alongside its reply,
    # so the captain can settle it with one press instead of a typed sentence. The
    # reply text always posts; the card is additional and never replaces it.
    lines.append(
        "if this answer is a decision, a blocker, a clarification question, a projection choice, "
        "or a free request, attach its card with --card-file <card-file> so the captain can answer "
        "with one press; the reply text still posts unchanged"
    )
    # Captain chat is read on a phone, so the answer itself must be short: a few
    # sentences of outcome, not a report. This constrains length rather than
    # forcing it, and the reply command above is still the only reply path.
    lines.append("keep the answer short: a few sentences of outcome, no preamble and no restated question")
    lines.append(
        "format for a phone: a short first line as the title, one '- ' bullet per item, "
        "a blank line between sections, and any link as a full https URL"
    )
    return "\n".join(lines).rstrip() + "\n"


def handoff_event(env: "fwl.Env", event: Dict[str, Any]) -> str:
    """Feed one accepted event through the existing external-id inbox seam.

    Returns the durable note id (empty when the capture output cannot be read),
    which the latency journal keys its wake and activation markers by.
    """
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
        note_id = ""
        for line in (proc.stdout or "").splitlines():
            fields = line.strip().split()
            if len(fields) >= 2 and fields[0] == "queued":
                note_id = fields[1]
                break
        return note_id
    finally:
        try:
            os.unlink(meta_tmp)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Fast path: instant acknowledgement, Jev gate, record-backed answer
# ---------------------------------------------------------------------------

def _bounded_command(
    cmd: List[str],
    *,
    timeout: float,
    env_extra: Optional[Dict[str, str]] = None,
    stdin_text: Optional[str] = None,
) -> Optional[str]:
    """Run one bounded read-only child; any failure or timeout is an absent answer."""
    environ = dict(os.environ)
    if env_extra:
        environ.update(env_extra)
    try:
        proc = subprocess.run(
            cmd,
            input=stdin_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=environ,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def known_task_ids(env: "fwl.Env") -> set:
    """Every task id currently visible in durable records, for the answer builder."""
    ids = set()
    try:
        for meta in env.state.glob("*.meta"):
            name = meta.name[: -len(".meta")]
            if name:
                ids.add(name)
    except OSError:
        pass
    backlog = env.data / "backlog.md"
    try:
        if backlog.is_file() and not backlog.is_symlink():
            for line in backlog.read_text(encoding="utf-8", errors="replace").splitlines():
                match = FAST_PATH_BACKLOG_LINE_RE.match(line)
                if match:
                    ids.add(match.group(1))
    except OSError:
        pass
    return ids


def extract_task_id(env: "fwl.Env", content: str) -> Optional[str]:
    ids = known_task_ids(env)
    for token in FAST_PATH_TASK_TOKEN_RE.findall(content or ""):
        if token in ids:
            return token
    return None


def plain_state(state_line: Optional[str]) -> Optional[str]:
    match = re.match(r"state:\s+([A-Za-z-]+)", state_line or "")
    if not match:
        return None
    state = match.group(1)
    return FAST_PATH_STATE_WORDS.get(state, state)


def backlog_title(env: "fwl.Env", task_id: str) -> str:
    """The captain-authored backlog title for one task, or an empty string."""
    backlog = env.data / "backlog.md"
    try:
        if not backlog.is_file() or backlog.is_symlink():
            return ""
        for line in backlog.read_text(encoding="utf-8", errors="replace").splitlines():
            match = FAST_PATH_BACKLOG_LINE_RE.match(line)
            if not match or match.group(1) != task_id:
                continue
            parts = line.split(" - ", 1)
            if len(parts) < 2:
                return ""
            title = re.split(r"\s+\((?:repo|kind|priority|since|hold)[:=]", parts[1], maxsplit=1)[0]
            return title.strip()
    except OSError:
        return ""
    return ""


def in_flight_backlog_ids(env: "fwl.Env") -> List[str]:
    backlog = env.data / "backlog.md"
    ids: List[str] = []
    try:
        if not backlog.is_file() or backlog.is_symlink():
            return ids
        in_flight = False
        for line in backlog.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("## "):
                in_flight = line.strip().lower() == "## in flight"
                continue
            if not in_flight:
                continue
            match = FAST_PATH_BACKLOG_LINE_RE.match(line)
            if match:
                ids.append(match.group(1))
    except OSError:
        return []
    return ids


def task_plain_state(env: "fwl.Env", task_id: str) -> Optional[str]:
    """The reconciled state of one task in plain captain words, read read-only."""
    state_cmd = os.environ.get("FM_CONSOLE_CREW_STATE_CMD") or str(env.script_dir / "fm-crew-state.sh")
    state_line = _bounded_command(
        [state_cmd, task_id],
        timeout=FAST_PATH_READ_TIMEOUT_SECONDS,
        env_extra={"FM_HOME": str(env.home), "FM_CREW_STATE_NO_FORGE": "1"},
    )
    return plain_state(state_line)


def build_fast_answer(env: "fwl.Env", cfg: "ConsoleConfig", event: Dict[str, Any]) -> Optional[str]:
    """A deterministic answer from durable records, or None to fall back to a full turn.

    The builder is deliberately conservative: it answers a named task's
    reconciled current state plus its backlog title, or a plain fleet-wide
    in-flight or blocked list, and returns None for anything it cannot state
    from the records alone. It never guesses and never changes any state.
    """
    content = str(event.get("content") or "").strip()
    if not content:
        return None
    task_id = extract_task_id(env, content)
    if task_id:
        word = task_plain_state(env, task_id)
        if not word:
            return None
        lines = [f"{task_id} is {word}."]
        title = backlog_title(env, task_id)
        if title:
            lines.append(title)
        return "\n".join(lines)[: cfg.fast_path_max_answer_chars]
    lowered = content.lower()
    if not any(hint in lowered for hint in FAST_PATH_QUESTION_HINTS):
        return None
    in_flight = in_flight_backlog_ids(env)
    if not in_flight:
        return None
    if any(hint in lowered for hint in FAST_PATH_BLOCKED_HINTS):
        blocked = [listed for listed in in_flight[:8] if task_plain_state(env, listed) == "blocked"]
        if not blocked:
            return "Nothing is blocked right now."
        lines = ["Blocked right now:"] + [f"- {listed}" for listed in blocked]
        return "\n".join(lines)[: cfg.fast_path_max_answer_chars]
    lines = ["In flight right now:"]
    for listed in in_flight[:8]:
        lines.append(f"- {listed}")
    if len(in_flight) > 8:
        lines.append(f"and {len(in_flight) - 8} more.")
    return "\n".join(lines)[: cfg.fast_path_max_answer_chars]


def classify_console_route(env: "fwl.Env", cfg: "ConsoleConfig", event: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Ask Jev whether this message is a record-backed fast answer.

    Returns the classifier's verdict record whenever the classifier ran and
    emitted one readable verdict - including a legitimate full_turn verdict
    with its own reason and confidence. None is reserved for "the classifier
    was unavailable or its output was unreadable": a missing classifier file,
    a failed or timed-out command, or output that is not one JSON object. The
    caller records that distinction verbatim instead of collapsing every
    full turn into an unavailable classifier.
    """
    if not cfg.fast_path_classifier.is_file():
        return None
    payload = json.dumps(
        {
            "message": str(event.get("content") or "")[:4000],
            "label": str(event.get("label") or ""),
        }
    )
    timeout_text = str(round(cfg.fast_path_timeout, 3))
    output = _bounded_command(
        [str(cfg.fast_path_classifier), "-"],
        timeout=cfg.fast_path_timeout + 5.0,
        env_extra={"FM_HOME": str(env.home), CLASSIFIER_ENV_TIMEOUT: timeout_text},
        stdin_text=payload,
    )
    if output is None:
        return None
    line = output.strip().splitlines()[-1] if output.strip() else ""
    if not line:
        return None
    try:
        verdict = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(verdict, dict):
        return None
    return verdict


def _safe_fast_path_text(text: str, max_chars: int) -> str:
    text = (text or "").strip()
    if not text:
        return ""
    for marker in REFUSED_MARKERS:
        if marker in text:
            return ""
    if len(text) > max_chars:
        text = text[: max_chars - 1].rstrip() + "\u2026"
    return text


def _is_reply_label(line: str) -> bool:
    """True when one short line is a heading rather than a sentence.

    Only a short line with no sentence-ending punctuation and no bullet marker
    can be a heading, so ordinary prose is never bolded by accident. A trailing
    colon marks a lead-in label; it is kept inside the bold so the line still
    reads the same.
    """
    stripped = line.strip()
    if not stripped or len(stripped) > REPLY_LABEL_MAX_CHARS:
        return False
    if stripped.startswith("#") or REPLY_BULLET_RE.match(stripped):
        return False
    if REPLY_URL_RE.fullmatch(stripped):
        return False
    if stripped.endswith((".", "!", "?")) and not stripped.endswith(":"):
        return False
    return any(ch.isalnum() for ch in stripped)


def _bound_reply_text(text: str, max_chars: int) -> str:
    """Cut a rendered reply to the bound without splitting a word or a URL.

    The bound is the contract, so it always wins. The cut backs off to the
    nearest whitespace, and a URL left incomplete at the cut is dropped whole,
    so the posted message never contains a half-clickable link.
    """
    if max_chars <= 0:
        return ""
    if len(text) <= max_chars:
        return text
    budget = max_chars - 1  # room for the ellipsis
    cut = budget
    while cut > 0 and not text[cut].isspace():
        cut -= 1
    kept = text[:cut].rstrip().rstrip("-*\u2022").rstrip()
    # A URL that straddles the cut is removed whole rather than left split.
    partial = REPLY_URL_RE.search(kept)
    if partial and partial.end() == len(kept):
        kept = kept[: partial.start()].rstrip().rstrip("-*\u2022").rstrip()
    if not kept:
        return "\u2026"
    return kept + "\u2026"


def render_captain_reply(text: str, max_chars: int = DEFAULT_REPLY_MAX_CHARS) -> str:
    """Render one captain-facing answer as a short, scannable Discord message.

    Deterministic and model-free: blank lines split sections, the first line of
    a multi-line section (or a colon lead-in) becomes a bold label, list lines
    are normalized to "- " bullets, and the whole reply is cut to ``max_chars``.
    A blank line separates every section so the message reads on a phone.
    """
    if not isinstance(text, str):
        return ""
    normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not normalized:
        return ""
    sections: List[str] = []
    for raw_section in re.split(r"\n\s*\n", normalized):
        lines = [ln.strip() for ln in raw_section.split("\n") if ln.strip()]
        if not lines:
            continue
        rendered: List[str] = []
        for index, line in enumerate(lines):
            bullet = REPLY_BULLET_RE.match(line)
            if bullet:
                rendered.append("- " + bullet.group(1).strip())
                continue
            is_first = index == 0
            has_body = len(lines) > 1
            if is_first and _is_reply_label(line) and (has_body or line.endswith(":")):
                rendered.append("**" + line + "**")
                continue
            rendered.append(line)
        sections.append("\n".join(rendered))
    rendered_text = "\n\n".join(section for section in sections if section)
    return _bound_reply_text(rendered_text, max_chars)


def bound_mirror_text(text: str, max_chars: int) -> str:
    """Bound one mirrored dialog item to a single Discord message body.

    The mirror deliberately does not use ``render_captain_reply``: that renderer
    reflows prose into captain-facing sections, and a mirrored turn must read as
    the turn was written. What is shared is the hard bound. A text inside the
    bound is returned byte-for-byte, so the durable receipt digests the text the
    captain read; a longer one keeps its head and its tail and states the
    omission between them, so the post is always one whole, visibly bounded
    message rather than a silently partial one.
    """
    if not isinstance(text, str) or not text:
        return ""
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    # The marker states how many characters were dropped, and its own width
    # depends on that number, so the room left for head and tail is settled by
    # solving the pair rather than guessed; two passes always converge.
    room = max_chars - len(MIRROR_TRUNCATION % 0) - 2
    for _ in range(4):
        marker = MIRROR_TRUNCATION % (len(text) - room)
        settled = max_chars - len(marker) - 2
        if settled <= 0:
            return text[:max_chars]
        if settled == room:
            break
        room = settled
    marker = MIRROR_TRUNCATION % (len(text) - room)
    head = (room + 1) // 2
    tail = room - head
    if tail <= 0:
        return f"{text[:room]}\n{marker}"
    return f"{text[:head]}\n{marker}\n{text[-tail:]}"


# ---------------------------------------------------------------------------
# Prepared request: an advisory packet attached to the durable intake note
#
# The preparation is the second half of the captain-request fast path. The
# wake half delivers the note immediately; this half makes the note cheaper to
# act on by reading the message once, before the main turn, and attaching what
# the turn would otherwise have to hunt for: the intent, the target selected
# from code-built candidate lists, the identifiers the message carries, and a
# few facts already present in the records. Everything here is advisory and
# read-only with respect to the fleet: it never answers the captain, never
# dispatches work, and never writes anywhere outside the console's own state.
# The captain's raw message is always kept beside the packet and stays the
# authority.
# ---------------------------------------------------------------------------

def known_projects(env: "fwl.Env") -> List[Dict[str, str]]:
    """The registered projects as code-built candidates, from data/projects.md.

    The model may only select one of these; it can never name a project the
    registry does not carry. A missing registry yields no candidates rather
    than a guess, and then the project axis is simply not asked.
    """
    registry = env.data / "projects.md"
    projects: List[Dict[str, str]] = []
    seen: set = set()
    try:
        if not registry.is_file() or registry.is_symlink():
            return projects
        for line in registry.read_text(encoding="utf-8", errors="replace").splitlines():
            match = PREPARE_PROJECT_LINE_RE.match(line)
            if not match:
                continue
            project_id = match.group(1)
            if project_id in seen:
                continue
            seen.add(project_id)
            posture = match.group(2).strip()
            summary = re.sub(r"\s*\(added \d{4}-\d{2}-\d{2}\)\s*$", "", match.group(3).strip())
            if posture:
                summary = f"{summary} [{posture}]" if summary else f"[{posture}]"
            projects.append(
                {"id": project_id, "summary": summary[:PREPARE_SUMMARY_MAX_CHARS]}
            )
    except OSError:
        return projects
    return projects


def backlog_entries(env: "fwl.Env") -> Dict[str, Dict[str, str]]:
    """One pass over data/backlog.md: task id -> title, repo, kind, since, done."""
    entries: Dict[str, Dict[str, str]] = {}
    backlog = env.data / "backlog.md"
    try:
        if not backlog.is_file() or backlog.is_symlink():
            return entries
        for line in backlog.read_text(encoding="utf-8", errors="replace").splitlines():
            match = FAST_PATH_BACKLOG_LINE_RE.match(line)
            if not match:
                continue
            task_id = match.group(1)
            entry = {"title": "", "repo": "", "kind": "", "since": "", "done": "no"}
            if line.startswith("- [x]") or line.startswith("- [X]"):
                entry["done"] = "yes"
            parts = line.split(" - ", 1)
            if len(parts) > 1:
                body = parts[1]
                entry["title"] = re.split(
                    r"\s+\((?:repo|kind|priority|since|hold)[:=]", body, maxsplit=1
                )[0].strip()[:PREPARE_SUMMARY_MAX_CHARS]
                for field, pattern in (
                    ("repo", r"\(repo: ([^)]+)\)"),
                    ("kind", r"\(kind: ([^)]+)\)"),
                    ("since", r"\(since ([^)]+)\)"),
                ):
                    found = re.search(pattern, body)
                    if found:
                        entry[field] = found.group(1).strip()
            entries[task_id] = entry
    except OSError:
        return entries
    return entries


def candidate_tasks(env: "fwl.Env", content: str) -> List[Dict[str, str]]:
    """The task ids this message may be about: every id it names, plus the
    in-flight backlog. Bounded and code-built, so the model can only select a
    task that already exists."""
    wanted: List[str] = []
    known = known_task_ids(env)
    for token in FAST_PATH_TASK_TOKEN_RE.findall(content or ""):
        if token in known and token not in wanted:
            wanted.append(token)
    for task_id in in_flight_backlog_ids(env):
        if task_id not in wanted:
            wanted.append(task_id)
    bounded = wanted[:MAX_PREPARE_CANDIDATE_TASKS]
    entries = backlog_entries(env)
    return [
        {"id": task_id, "title": (entries.get(task_id) or {}).get("title", "")}
        for task_id in bounded
    ]


def normalise_ask(content: str) -> str:
    """The captain's own words on one bounded line.

    This is a faithful normalisation - whitespace collapsed, surrounding blank
    space removed - and never a paraphrase. The packet must not become a
    second, model-authored version of the ask that could diverge from the
    message the captain actually sent.
    """
    text = re.sub(r"\s+", " ", str(content or "")).strip()
    if len(text) > PREPARE_ASK_MAX_CHARS:
        text = text[: PREPARE_ASK_MAX_CHARS - 1].rstrip() + "\u2026"
    return text


def extract_identifiers(env: "fwl.Env", event: Dict[str, Any], entity: str) -> Dict[str, Any]:
    """The identifiers the message carries, read from the text and the event.

    Nothing here is inferred: a task id is only reported when it names a task
    that exists in the records, a pull request only when the text carries its
    full URL, and a date only when it appears in the message.
    """
    content = str(event.get("content") or "")
    task_id = entity or extract_task_id(env, content) or ""
    prs: List[str] = []
    for match in PREPARE_PR_URL_RE.finditer(content):
        url = match.group(0).rstrip(".,;")
        if url not in prs:
            prs.append(url)
    dates: List[str] = []
    for match in PREPARE_DATE_RE.finditer(content):
        if match.group(1) not in dates:
            dates.append(match.group(1))
    created = parse_discord_epoch(event.get("message_id"), event.get("timestamp"))
    received = ""
    if created:
        received = datetime.datetime.fromtimestamp(created, datetime.timezone.utc).strftime("%Y-%m-%d")
    target = str(event.get("thread_id") or event.get("channel_id") or "")
    return {
        "task": task_id,
        "pr": prs[:MAX_PREPARE_PR_URLS],
        "date": dates[:MAX_PREPARE_DATES],
        "received": received,
        "channel": target,
        "thread": str(event.get("thread_id") or ""),
    }


def prepare_facts(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    entity: str,
    project: str,
    entries: Dict[str, Dict[str, str]],
) -> List[str]:
    """Three to five durable facts about the message's target, or about the fleet.

    Every fact is a read of an existing record - the reconciled task state, the
    backlog line, the last recorded event, a recorded pull-request link, the
    in-flight list, the registry. Nothing is inferred and nothing is changed,
    and the count is bounded by the configured maximum.
    """
    facts: List[str] = []
    if entity:
        facts.extend(task_facts(env, entity, entries.get(entity) or {}))
    if project:
        registry = {item["id"]: item for item in known_projects(env)}
        listed = registry.get(project)
        if listed:
            facts.append(f"project {project}: {listed['summary']}")
        owned = [
            task_id
            for task_id, entry in entries.items()
            if entry.get("repo") == project and entry.get("done") == "no"
        ]
        facts.append(
            f"{project} open tasks: {len(owned)}" + ((" (" + ", ".join(sorted(owned)[:6]) + ")") if owned else "")
        )
    facts.extend(fleet_facts(env, entries))
    unique: List[str] = []
    for fact in facts:
        text = str(fact or "").strip()
        if not text or text in unique:
            continue
        unique.append(text[:PREPARE_FACT_MAX_CHARS])
    return unique[: cfg.prepare_max_facts]


def task_facts(env: "fwl.Env", task_id: str, entry: Dict[str, str]) -> List[str]:
    """What the records already say about one task, read read-only."""
    facts: List[str] = []
    word = task_plain_state(env, task_id)
    if word:
        facts.append(f"reconciled state: {task_id} is {word}")
    if entry:
        described = [
            part
            for part in (
                ("repo: " + entry["repo"]) if entry.get("repo") else "",
                ("kind: " + entry["kind"]) if entry.get("kind") else "",
                ("since " + entry["since"]) if entry.get("since") else "",
                "backlog: done" if entry.get("done") == "yes" else "backlog: open",
            )
            if part
        ]
        title = entry.get("title") or "(untitled)"
        facts.append(f"backlog: {title} ({', '.join(described)})")
    else:
        facts.append(f"backlog: {task_id} is not listed")
    last_event = last_status_event(env, task_id)
    if last_event:
        facts.append(f"last recorded event: {last_event}")
    pr_url = task_pr_url(env, task_id)
    if pr_url:
        facts.append(f"recorded pull request: {pr_url}")
    return facts


def fleet_facts(env: "fwl.Env", entries: Dict[str, Dict[str, str]]) -> List[str]:
    """The always-available facts about the queue itself, read read-only."""
    in_flight = in_flight_backlog_ids(env)
    facts: List[str] = []
    if in_flight:
        shown = ", ".join(in_flight[:6])
        more = f" (+{len(in_flight) - 6} more)" if len(in_flight) > 6 else ""
        facts.append(f"in flight: {len(in_flight)} ({shown}){more}")
    else:
        facts.append("in flight: none")
    open_count = sum(1 for entry in entries.values() if entry.get("done") != "yes")
    done_count = len(entries) - open_count
    facts.append(f"backlog: {open_count} open, {done_count} done")
    projects = known_projects(env)
    facts.append(f"projects registered: {len(projects)}")
    return facts


def last_status_event(env: "fwl.Env", task_id: str) -> str:
    """The task's latest recorded status event, bounded and read read-only."""
    path = env.state / f"{task_id}.status"
    try:
        if not path.is_file() or path.is_symlink():
            return ""
        lines = [
            line.strip()
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
            if line.strip()
        ]
    except OSError:
        return ""
    if not lines:
        return ""
    return lines[-1][:PREPARE_FACT_MAX_CHARS]


def task_pr_url(env: "fwl.Env", task_id: str) -> str:
    """The pull request the task's own metadata records, or an empty string."""
    meta = env.state / f"{task_id}.meta"
    try:
        if not meta.is_file() or meta.is_symlink():
            return ""
        for line in meta.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("pr="):
                value = line[len("pr="):].strip()
                if value:
                    return value
    except OSError:
        return ""
    return ""


class PrepareCall:
    """One bounded advisory preparer child, started before its answer is needed.

    The console starts it beside the route classification and reads it only at
    the handoff, so preparation runs inside a window the capture already spends
    on an advisory call instead of adding a second wait to the wake path. Every
    outcome other than a well-formed answer is the fallback, and the child is
    killed at its deadline so a stuck preparer can never hold the note.
    """

    def __init__(self, cmd: List[str], payload: str, timeout: float, env_extra: Dict[str, str]):
        self.timeout = timeout
        self.started_at = time.time()
        self.error = ""
        self._proc: Optional[subprocess.Popen] = None
        environ = dict(os.environ)
        environ.update(env_extra)
        try:
            self._proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                env=environ,
            )
            if self._proc.stdin is None:
                raise OSError("no standard input on the preparer child")
            self._proc.stdin.write(payload)
            self._proc.stdin.close()
        except (OSError, subprocess.SubprocessError, ValueError) as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            self.cancel()

    def finish(self) -> Optional[str]:
        """Wait out the remaining bound, returning stdout or None on any failure."""
        proc = self._proc
        if proc is None:
            return None
        remaining = self.timeout - (time.time() - self.started_at)
        try:
            if remaining <= 0:
                raise subprocess.TimeoutExpired(proc.args, self.timeout)
            proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            self.error = self.error or f"timeout after {self.timeout:g}s"
            self.cancel()
            return None
        if proc.returncode != 0:
            self.error = f"exit {proc.returncode}"
            self.cancel()
            return None
        output = ""
        try:
            if proc.stdout is not None:
                output = proc.stdout.read()
        except (OSError, ValueError) as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            self.cancel()
            return None
        self.cancel()
        return output

    def cancel(self) -> None:
        """Kill and reap the child; safe to call more than once."""
        proc = self._proc
        if proc is None:
            return
        self._proc = None
        if proc.returncode is None:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=5)
        except (subprocess.SubprocessError, OSError):
            pass
        for stream in (proc.stdin, proc.stdout):
            try:
                if stream is not None and not stream.closed:
                    stream.close()
            except (OSError, ValueError):
                pass


def start_prepare(env: "fwl.Env", cfg: "ConsoleConfig", event: Dict[str, Any]) -> Optional[PrepareCall]:
    """Start the bounded advisory preparer for one message, or None when it cannot start.

    The started call is stashed on the event, because it is read later in the
    same capture - after the route decision - and never by anyone else. The
    pop in finish_prepare/discard_prepare is therefore the only way it ends.
    """
    if not cfg.prepare_enabled:
        return None
    if not cfg.prepare_classifier.is_file():
        return None
    content = str(event.get("content") or "")
    payload = json.dumps(
        {
            "message": content[:MAX_PREPARE_MESSAGE_CHARS],
            "label": str(event.get("label") or ""),
            "projects": known_projects(env),
            "tasks": candidate_tasks(env, content),
        },
        ensure_ascii=False,
    )
    call = PrepareCall(
        [str(cfg.prepare_classifier), "-"],
        payload,
        cfg.prepare_timeout,
        {"FM_HOME": str(env.home), PREPARE_ENV_TIMEOUT: str(round(cfg.prepare_timeout, 3))},
    )
    event["prepare_call"] = call
    return call


def parse_prepare_verdict(output: str) -> Tuple[Optional[Dict[str, Any]], str]:
    """One strict JSON verdict from the preparer, or (None, why it is unusable)."""
    text = (output or "").strip()
    if not text:
        return None, "the preparer produced no answer"
    line = text.splitlines()[-1]
    try:
        verdict = json.loads(line)
    except json.JSONDecodeError:
        return None, "the preparer answer is not JSON"
    if not isinstance(verdict, dict):
        return None, "the preparer answer is not a JSON object"
    if verdict.get("flag"):
        return None, str(verdict.get("reason") or verdict.get("flag"))
    intent = verdict.get("intent")
    if intent not in PREPARE_INTENTS:
        return None, f"the preparer named an unknown intent: {intent!r}"
    confidence = verdict.get("intent_confidence")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        return None, "the preparer returned no usable confidence"
    if not math.isfinite(float(confidence)) or not 0.0 <= float(confidence) <= 1.0:
        return None, "the preparer returned a confidence outside 0..1"
    return verdict, "ok"


def build_prepared_packet(
    env: "fwl.Env", cfg: "ConsoleConfig", event: Dict[str, Any], verdict: Dict[str, Any]
) -> Dict[str, Any]:
    """The advisory packet, built from the verdict plus the durable records."""
    content = str(event.get("content") or "")
    entity = str(verdict.get("entity") or "")
    # The preparer only ever sees code-built candidates, so this is a boundary
    # assertion rather than a filter: an id that names no existing record is
    # dropped instead of being repeated into the packet.
    if entity and entity not in known_task_ids(env):
        entity = ""
    project = str(verdict.get("project") or "")
    entries = backlog_entries(env)
    return {
        "schema": PREPARE_SCHEMA,
        "request_id": str(event.get("request_id") or ""),
        "intent": str(verdict.get("intent") or ""),
        "intent_confidence": round(float(verdict.get("intent_confidence")), 4),
        "project": project or None,
        "entity": entity or None,
        "ask": normalise_ask(content),
        "identifiers": extract_identifiers(env, event, entity),
        "facts": prepare_facts(env, cfg, entity, project, entries),
        "raw_message": content,
        "raw_message_chars": len(content),
        "raw_message_sha256": fwl.sha256_text(content),
        "prepared_at": fwl.utc_now(),
    }


def finish_prepare(
    env: "fwl.Env", cfg: "ConsoleConfig", event: Dict[str, Any], reason: str = ""
) -> Dict[str, Any]:
    """Resolve a started preparation into a durable outcome and attach the packet.

    The caller names the reason when it deliberately did not prepare (a fast
    answer consumed the message, an uncertain transcription must first be
    confirmed). Every other path reads the started call here, and any failure,
    timeout, or uncertain verdict is the fallback: the note keeps the raw
    message alone and the outcome records why.
    """
    request_id = str(event.get("request_id") or "")
    call = event.pop("prepare_call", None)
    duration_ms: Optional[float] = None
    verdict: Optional[Dict[str, Any]] = None
    failure = reason
    if call is None:
        if not failure:
            failure = "no preparer was started"
    else:
        output = call.finish()
        # The measured cost is the whole bounded read, wait included: that is
        # the figure the wake path pays for the packet.
        duration_ms = round((time.time() - call.started_at) * 1000.0, 1)
        if output is None:
            failure = reason or call.error or "the preparer produced no answer"
        else:
            verdict, failure = parse_prepare_verdict(output)
    if verdict is None:
        outcome: Dict[str, Any] = {
            "status": "fallback",
            "reason": failure or "uncertain preparation",
            "packet": None,
        }
    else:
        outcome = {
            "status": "prepared",
            "reason": "ok",
            "packet": build_prepared_packet(env, cfg, event, verdict),
        }
    outcome["duration_ms"] = duration_ms
    store_prepare_outcome(env, request_id, outcome)
    if isinstance(outcome.get("packet"), dict):
        event["prepared_packet"] = outcome["packet"]
    return outcome


def discard_prepare(
    env: "fwl.Env", cfg: "ConsoleConfig", event: Dict[str, Any], reason: str
) -> Dict[str, Any]:
    """Cancel a started preparation whose packet has nowhere to go, and record why.

    This is what a fast answer does: it never becomes a note, so waiting out the
    preparer's bound would only delay the captain's answer. The child is killed
    at once and the outcome records that this message skipped preparation.
    """
    call = event.pop("prepare_call", None)
    duration_ms: Optional[float] = None
    if isinstance(call, PrepareCall):
        duration_ms = round((time.time() - call.started_at) * 1000.0, 1)
        call.cancel()
    outcome: Dict[str, Any] = {
        "status": "fallback",
        "reason": reason,
        "packet": None,
        "duration_ms": duration_ms,
    }
    store_prepare_outcome(env, str(event.get("request_id") or ""), outcome)
    return outcome


def prepare_latency_fields(outcome: Dict[str, Any]) -> Dict[str, Any]:
    """The preparation stage as the latency journal records it, or nothing."""
    if not isinstance(outcome, dict) or not outcome.get("status"):
        return {}
    return {
        "prepare_status": str(outcome.get("status")),
        "prepare_reason": str(outcome.get("reason") or "")[:200],
        "prepare_ms": outcome.get("duration_ms"),
    }


def render_prepared_packet(packet: Dict[str, Any]) -> List[str]:
    """The packet block as the note body reads it, one line per field."""
    lines: List[str] = []
    lines.append(f"intent: {packet.get('intent')} (confidence {packet.get('intent_confidence')})")

    def shown(value: Any) -> str:
        # A null axis reads as `none` on purpose: the note is prose firstmate
        # reads, and Python's None is an implementation detail of the record.
        return "none" if value in (None, "") else str(value)

    lines.append(f"project: {shown(packet.get('project'))} | entity: {shown(packet.get('entity'))}")
    lines.append(f"ask: {packet.get('ask')}")
    identifiers = packet.get("identifiers") if isinstance(packet.get("identifiers"), dict) else {}
    pairs = []
    for key in ("task", "pr", "date", "received", "channel"):
        value = identifiers.get(key)
        if isinstance(value, list):
            value = ", ".join(str(item) for item in value)
        if value:
            pairs.append(f"{key}={value}")
    lines.append("identifiers: " + (" ".join(pairs) if pairs else "none"))
    facts = packet.get("facts") if isinstance(packet.get("facts"), list) else []
    lines.append("facts:")
    for fact in facts:
        lines.append(f"- {fact}")
    return lines


def post_fast_path_message(env: "fwl.Env", client: "ConsoleClient", channel_id: str, text: str, nonce: str) -> str:
    """Post one idempotent fast-path message; a replay returns the first message id."""
    path = fwl.receipt_path(env, nonce)
    try:
        existing = fwl.load_existing_json(path)
    except FMError:
        existing = None
    if isinstance(existing, dict) and existing.get("discord_message_id"):
        return str(existing["discord_message_id"])
    message_id = client.post_message(channel_id, text)
    receipt = fwl.base_receipt("fast-path", ADAPTER, {"channel_id": channel_id}, fwl.sha256_text(text))
    fwl.record_receipt(env, nonce, receipt, message_id)
    return message_id


def ensure_fast_path_ack(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any]) -> str:
    """Post the deterministic acknowledgement once per request, or return the recorded id."""
    request_id = str(event.get("request_id") or "")
    existing = load_fast_path_record(env, "acks", request_id)
    if isinstance(existing, dict) and existing.get("discord_message_id"):
        return str(existing["discord_message_id"])
    message_id = client.post_message(str(event.get("channel_id") or ""), cfg.fast_path_ack_text)
    store_fast_path_record(env, "acks", request_id, {"discord_message_id": message_id})
    return message_id


def route_text_event(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any]) -> str:
    """Acknowledge, gate with Jev, then answer from records or capture for a full turn.

    Fail-closed: any missing classifier, error, timeout, malformed verdict,
    unbuildable answer, or failed post routes the message to the full firstmate
    turn through the same durable external-id capture as before. The
    acknowledgement is deterministic and idempotent by request id, and the
    classification verdict and chosen path are recorded as a durable audit
    record beside the message id.
    """
    request_id = str(event.get("request_id") or "")
    ingested_at = time.time()
    if request_id:
        update_latency(
            env,
            request_id,
            transport=str(event.get("transport") or ""),
            message_id=str(event.get("message_id") or ""),
            channel_id=str(event.get("channel_id") or ""),
            label=str(event.get("label") or ""),
            guild_id=str(event.get("guild_id") or ""),
            discord_timestamp=str(event.get("timestamp") or ""),
            ingested_at=ingested_at,
        )
        if str(event.get("transport") or "") == "polling" and cfg.live_gateway_enabled:
            # The permanent connection was enabled but this message only reached
            # the console through the bounded poll; make the fallback visible.
            record_delivery_gap(env, "polling-capture", f"message {event.get('message_id')} captured by polling while the gateway was enabled")
    # The advisory preparation starts here, beside the route classification, and
    # is read only at the handoff. That is what keeps it off the wake path: the
    # capture already spends this window on an advisory gate when the fast path
    # is on, so the packet costs the captain no extra wait to be attached.
    prepare_skip = ""
    if cfg.prepare_enabled and request_id:
        if transcript_is_uncertain(event):
            prepare_skip = "uncertain transcription: the spoken words are not confirmed yet"
        else:
            if start_prepare(env, cfg, event) is None:
                prepare_skip = "the preparer command is not available"
    # An uncertain transcript always takes the full turn: the fast path answers
    # from records, and an answer to a question the captain may not have asked is
    # worse than a slower confirmation. The marker in the note is what firstmate
    # then asks the captain about.
    if not (cfg.fast_path_enabled and cfg.live_posting_enabled) or not request_id or transcript_is_uncertain(event):
        prepare_outcome: Dict[str, Any] = {}
        if cfg.prepare_enabled and request_id:
            prepare_outcome = finish_prepare(env, cfg, event, prepare_skip)
        note_id = handoff_event(env, event)
        if request_id:
            update_latency(
                env,
                request_id,
                captured_at=time.time(),
                note_id=note_id,
                path="full_turn",
                **prepare_latency_fields(prepare_outcome),
            )
        return "captured"
    ack_message_id = ""
    ack_at: Optional[float] = None
    if cfg.fast_path_ack_enabled:
        try:
            ack_message_id = ensure_fast_path_ack(env, cfg, client, event)
            ack_at = time.time()
        except FMError:
            ack_message_id = ""
    decision = load_fast_path_record(env, "decisions", request_id)
    new_decision = decision is None
    if decision is None:
        verdict = classify_console_route(env, cfg, event)
        fast = (
            verdict is not None
            and verdict.get("verdict") == "fast_answer"
            and verdict.get("flag") == "answer_from_records"
        )
        answer_text = ""
        if fast and cfg.fast_path_answers_enabled:
            answer_text = build_fast_answer(env, cfg, event) or ""
        if fast and answer_text:
            decision = {
                "path": "fast_answer",
                "answer_text": answer_text,
                "verdict": {
                    "verdict": "fast_answer",
                    "confidence": verdict.get("confidence"),
                    "reason": verdict.get("reason"),
                },
            }
        else:
            # Keep the classifier's real verdict when it produced one, so the
            # record can tell "the classifier routed the full turn" apart from
            # "the classifier was unavailable or its output was unreadable".
            if verdict is None:
                recorded_verdict: Dict[str, Any] = {
                    "verdict": "full_turn",
                    "confidence": None,
                    "reason": "classifier unavailable or refused",
                }
            else:
                recorded_verdict = {
                    key: verdict.get(key)
                    for key in ("verdict", "confidence", "reason", "flag")
                }
                recorded_verdict["reason"] = recorded_verdict.get("reason") or "the classifier routed the full turn"
            decision = {
                "path": "full_turn",
                "answer_text": "",
                "verdict": recorded_verdict,
            }
        store_fast_path_record(env, "decisions", request_id, decision)
    path = str(decision.get("path") or "full_turn")
    answer_text = render_captain_reply(str(decision.get("answer_text") or ""), cfg.reply_max_chars)
    answer_text = _safe_fast_path_text(answer_text, cfg.fast_path_max_answer_chars)
    answer_message_id = ""
    answer_at: Optional[float] = None
    if path == "fast_answer" and answer_text:
        try:
            answer_message_id = post_fast_path_message(
                env, client, str(event.get("channel_id") or ""), answer_text, f"fast-answer:{request_id}"
            )
            answer_at = time.time()
        except FMError:
            # A failed fast answer is a full turn, and the decision is rewritten
            # so a replay never posts the answer after the capture.
            path = "full_turn"
            answer_message_id = ""
            if new_decision:
                decision["path"] = "full_turn"
                decision["answer_text"] = ""
                store_fast_path_record(env, "decisions", request_id, decision)
    note_id = ""
    prepare_outcome = {}
    if path != "fast_answer" or not answer_text:
        path = "full_turn"
        if cfg.prepare_enabled and request_id:
            prepare_outcome = finish_prepare(env, cfg, event, prepare_skip)
        note_id = handoff_event(env, event)
        if new_decision and cfg.fast_path_typing_enabled:
            try:
                ensure_typing(env, cfg, client, event)
            except FMError:
                pass
    elif cfg.prepare_enabled and request_id:
        # A fast answer never becomes a note, so the packet would have nowhere to
        # go: cancel the started call at once instead of waiting out its bound,
        # and record that the message skipped preparation for this reason.
        prepare_outcome = discard_prepare(
            env,
            cfg,
            event,
            prepare_skip or "the fast path answered the message without a full turn",
        )
    if request_id:
        latency_fields: Dict[str, Any] = {"path": path, "captured_at": answer_at or time.time()}
        latency_fields.update(prepare_latency_fields(prepare_outcome))
        if ack_at is not None:
            latency_fields["ack_at"] = ack_at
        if ack_message_id:
            latency_fields["ack_message_id"] = ack_message_id
        if note_id:
            latency_fields["note_id"] = note_id
        if answer_at is not None:
            latency_fields["answered_at"] = answer_at
        if answer_message_id:
            latency_fields["answer_message_id"] = answer_message_id
        update_latency(env, request_id, **latency_fields)
    verdict_record = decision.get("verdict") if isinstance(decision.get("verdict"), dict) else {}
    store_fast_path_record(
        env,
        "audits",
        request_id,
        {
            "path": path,
            "verdict": verdict_record,
            "channel_id": str(event.get("channel_id") or ""),
            "message_id": str(event.get("message_id") or ""),
            "ack_message_id": ack_message_id,
            "answer_message_id": answer_message_id,
        },
    )
    return "captured"


# ---------------------------------------------------------------------------
# Audio transcription
# ---------------------------------------------------------------------------

def route_inbound_event(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any]) -> bool:
    """Route one normalized inbound event; True when it produced a durable effect.

    A text event goes straight to the shared capture path. An audio event is
    transcribed into text and then handed to that exact same path, so the
    acknowledgement, fast path, typing indicator, and full turn behave
    identically and the answer still lands in the originating thread.
    """
    kind = event.get("kind")
    if kind == "text":
        route_text_event(env, cfg, client, event)
        return True
    if kind == "audio":
        return route_audio_event(env, cfg, client, event)
    return False


def audio_failure_text(reason: str) -> str:
    return f"Je n'ai pas pu transcrire ce message audio : {reason}"


def sanitize_transcript_confidence(
    confidence: Any, redact_text: Optional[Callable[[str], str]] = None
) -> Dict[str, Any]:
    """Keep only the JSON-safe, non-secret fields of one confidence record.

    The record describes how the transcript was checked, so it may hold only a
    status, the flags, the agreement ratio, the second reading, and a bounded
    redacted reason - never the key or the audio.
    """
    if not isinstance(confidence, dict):
        return {}
    record: Dict[str, Any] = {}
    status = confidence.get("status")
    if isinstance(status, str) and status in TRANSCRIPT_CONFIDENCE_STATUSES:
        record["status"] = status
    for flag in ("uncertain", "checked"):
        value = confidence.get(flag)
        if isinstance(value, bool):
            record[flag] = value
    ratio = confidence.get("ratio")
    if isinstance(ratio, (int, float)) and not isinstance(ratio, bool):
        record["ratio"] = round(float(ratio), 3)
    for key, limit in (
        ("alternate", whisper.CONFIDENCE_ALTERNATE_MAX_CHARS),
        ("reason", TRANSCRIPT_CONFIDENCE_MAX_REASON_CHARS),
    ):
        value = confidence.get(key)
        if isinstance(value, str) and value:
            record[key] = (redact_text(value) if redact_text else value)[:limit]
    return record


def confidence_is_uncertain(confidence: Any) -> bool:
    return isinstance(confidence, dict) and confidence.get("uncertain") is True


def transcript_is_uncertain(event: Dict[str, Any]) -> bool:
    """True when this event's transcript must not be read as settled."""
    return confidence_is_uncertain(event.get("transcript_confidence"))


def transcript_uncertainty_reason(confidence: Dict[str, Any]) -> str:
    """One line of why the transcript is uncertain, for the note's reader."""
    if confidence.get("status") == "unavailable":
        detail = str(confidence.get("reason") or "no detail")
        return f"the second reading of the same audio failed, so this reading is unverified ({detail})"
    ratio = confidence.get("ratio")
    if isinstance(ratio, (int, float)) and not isinstance(ratio, bool):
        return (
            "two readings of the same audio disagree "
            f"(word agreement {float(ratio):.2f}), so the transcript may not be what was said"
        )
    return "two readings of the same audio disagree, so the transcript may not be what was said"


def route_audio_event(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any]) -> bool:
    """Download, transcribe, and feed one audio message through the text path.

    Exactly once per request: a durable transcript record keyed by the request
    id means a replay reuses the first transcript and never downloads or calls
    Groq again. Every failure is recorded and answered with one honest line in
    the same conversation instead of silence.
    """
    request_id = str(event.get("request_id") or "")
    if not cfg.transcription_enabled or cfg.transcription_provider != "groq":
        event["reason"] = "audio-transcription-disabled"
        return False
    if not request_id:
        event["reason"] = "audio-without-message-id"
        return False
    existing = load_transcript_record(env, request_id)
    if existing is not None:
        if existing.get("status") == "ok":
            confidence = existing.get("confidence")
            reading = str(existing.get("text") or "")
            confirm_card = ""
            if confidence_is_uncertain(confidence):
                confirm_card, card_skip = post_transcript_card(env, cfg, client, event, reading)
                store_transcript_card_outcome(env, request_id, confirm_card, card_skip)
            _deliver_transcript(env, cfg, client, event, reading, confidence, confirm_card)
            return True
        event["reason"] = "audio-transcription-failed"
        return False
    try:
        meta, text = _transcribe_audio_event(env, cfg, client, event)
    except FMError as exc:
        reason = client.redact(str(exc))
        store_transcript_record(env, request_id, {"status": "failed", "reason": reason[:500]})
        _post_honest_failure(env, cfg, client, event, reason)
        event["reason"] = f"audio-transcription-failed: {reason[:120]}"
        return False
    confidence = meta.get("confidence")
    store_transcript_record(env, request_id, {"status": "ok", "text": text, **meta})
    _post_transcript(env, cfg, client, event, text, request_id, confidence)
    confirm_card = ""
    if confidence_is_uncertain(confidence):
        confirm_card, card_skip = post_transcript_card(env, cfg, client, event, text)
        store_transcript_card_outcome(env, request_id, confirm_card, card_skip)
    _deliver_transcript(env, cfg, client, event, text, confidence, confirm_card)
    return True


def _audio_candidate_url(message: Dict[str, Any], attachment_id: str) -> str:
    for attachment in message.get("attachments") or []:
        if isinstance(attachment, dict) and fwl.attachment_id(attachment) == attachment_id:
            return str(attachment.get("url") or "")
    return ""


def _transcribe_audio_event(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any]) -> Tuple[Dict[str, Any], str]:
    """Validate, download, and transcribe one audio attachment; delete it always."""
    flags_value = event.get("flags", 0)
    flags = flags_value if isinstance(flags_value, int) and not isinstance(flags_value, bool) else 0
    message = {
        "id": str(event.get("message_id") or ""),
        "content": "",
        "attachments": event.get("attachments") or [],
        "flags": flags,
    }
    meta, audio_kind = fwl.validate_audio_attachment(cfg, message, flags)
    url = validate_audio_cdn_url(_audio_candidate_url(message, str(meta.get("id") or "")), cfg)
    tmp_dir = console_state_path(env, "audio-tmp")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(tmp_dir, 0o700)
    except OSError:
        pass
    suffix = Path(str(meta.get("filename") or "")).suffix[:16]
    fd, tmp_name = tempfile.mkstemp(prefix=".audio.", suffix=suffix, dir=str(tmp_dir))
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        client.download_attachment(url, tmp_path, cfg.audio_max_bytes)
        api_key = whisper.resolve_api_key(env.home, cfg.transcription_key_env)
        if not api_key:
            raise FMError(
                f"transcription is enabled but {cfg.transcription_key_env} is not set in the environment or {env.home}/.env"
            )
        try:
            text, confidence = whisper.transcribe_checked(
                tmp_path,
                str(meta.get("filename") or "audio"),
                api_key=api_key,
                model=cfg.transcription_model,
                language=cfg.transcription_language,
                prompt=cfg.transcription_prompt,
                base_url=cfg.transcription_base_url,
                timeout=cfg.transcription_timeout,
                check=cfg.transcription_confidence_check,
                check_max_seconds=cfg.transcription_confidence_max_seconds,
                duration_secs=meta.get("duration_secs"),
            )
        except whisper.GroqError as exc:
            raise FMError(str(exc)) from exc
    finally:
        if cfg.audio_delete_raw:
            try:
                tmp_path.unlink()
            except OSError:
                pass
    text = text.strip()
    if not text:
        raise FMError("the audio contained no recognizable speech")
    record_meta = {
        "model": cfg.transcription_model,
        "language": cfg.transcription_language,
        "attachment_id": str(meta.get("id") or ""),
        "size": meta.get("size"),
        "duration_secs": meta.get("duration_secs"),
        "audio_kind": audio_kind,
        "confidence": sanitize_transcript_confidence(confidence, client.redact),
    }
    return record_meta, text


def validate_audio_cdn_url(url: str, cfg: "ConsoleConfig") -> str:
    if not url:
        raise FMError("audio attachment is missing its download URL")
    return fwl.validate_discord_cdn_url(url, cfg)


def _deliver_transcript(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    event: Dict[str, Any],
    text: str,
    confidence: Any = None,
    confirm_card: str = "",
) -> None:
    """Feed one transcript into the shared text path, carrying its confidence.

    The confidence travels with the message so the capture path can both mark
    the transcript and refuse to answer an uncertain one from records alone, and
    the confirmation card's id travels with it so the note can name the card the
    conversation already carries.
    """
    if not text:
        return
    text_event = dict(event)
    text_event["kind"] = "text"
    text_event["content"] = text
    text_event["transcript"] = True
    if isinstance(confidence, dict) and confidence:
        text_event["transcript_confidence"] = confidence
    if confirm_card:
        text_event["transcript_confirm_card"] = confirm_card
    text_event.pop("attachments", None)
    text_event.pop("flags", None)
    route_text_event(env, cfg, client, text_event)


def _post_transcript(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    event: Dict[str, Any],
    text: str,
    request_id: str,
    confidence: Any = None,
) -> None:
    """Show what was heard in the thread, once, before the answer arrives."""
    if not (cfg.transcription_post_transcript and cfg.live_posting_enabled):
        return
    uncertain = confidence_is_uncertain(confidence)
    prefix = DEFAULT_TRANSCRIPTION_UNCERTAIN_PREFIX if uncertain else cfg.transcription_prefix
    body = _safe_fast_path_text(prefix + text, cfg.fast_path_max_answer_chars)
    if not body:
        return
    try:
        post_fast_path_message(env, client, str(event.get("channel_id") or ""), body, f"transcript:{request_id}")
    except FMError:
        pass


def _post_honest_failure(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", event: Dict[str, Any], reason: str) -> None:
    """Answer a failed transcription with one honest line, never silence."""
    if not cfg.live_posting_enabled:
        return
    body = _safe_fast_path_text(audio_failure_text(reason), cfg.fast_path_max_answer_chars)
    if not body:
        body = "Je n'ai pas pu transcrire ce message audio."
    request_id = str(event.get("request_id") or "")
    try:
        post_fast_path_message(env, client, str(event.get("channel_id") or ""), body, f"transcript-failure:{request_id}")
    except FMError:
        pass


# ---------------------------------------------------------------------------
# Action cards
# ---------------------------------------------------------------------------

CARD_REFUSAL_TEXTS = {
    "non-captain": "Seul le capitaine peut r\u00e9pondre \u00e0 cette carte.",
    "unknown-custom-id": "Ce bouton n'est pas une carte Firstmate.",
    "unknown-card": "Cette carte n'est plus disponible.",
    "unreadable-card": "Cette carte n'est pas lisible, je ne peux pas enregistrer la r\u00e9ponse.",
    "card-mismatch": "Ce bouton ne correspond pas \u00e0 cette carte.",
    "unknown-option": "Cette option n'existe plus sur la carte.",
}
CARD_CHAT_CONFIRMATION = "R\u00e9ponds directement dans la conversation, je m'en occupe."
CARD_FAILURE_SUFFIX = "Je n'ai pas pu enregistrer ta r\u00e9ponse. R\u00e9essaie."
CARD_ERROR_TEXT = "Je n'ai pas pu traiter ce bouton."


def card_ack_timeout_seconds() -> float:
    """The interaction acknowledgement bound, with an env test seam.

    The first callback must reach Discord inside its 3-second window, so this is
    deliberately short rather than sharing the general callback timeout.
    """
    override = os.environ.get("FM_DISCORD_CARD_ACK_TIMEOUT")
    if override:
        try:
            parsed = float(override)
        except ValueError:
            parsed = 0.0
        if parsed > 0:
            return parsed
    return CARD_ACK_TIMEOUT_SECONDS


def card_id_for(nonce: str) -> str:
    return fwl.sha256_text(nonce)[:CARD_ID_HEX_CHARS]


def card_type_for_interaction(shape: str) -> Optional[str]:
    """The card type one captain-interaction shape produces, or None.

    The single owner of the trigger mapping: a shape named in
    ``INTERACTION_CARD_TRIGGERS`` produces that card type, and every other shape
    produces no card. Keeping it a data table makes the mapping inspectable and
    testable instead of scattered through call sites.
    """
    return INTERACTION_CARD_TRIGGERS.get(str(shape or "").strip().lower())


def _card_text(value: Any, field: str, max_chars: int, required: bool = True) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str):
        raise FMError(f"{field} must be a string")
    text = value.strip()
    if not text:
        if required:
            raise FMError(f"{field} must not be empty")
        return ""
    if "\x00" in text:
        raise FMError(f"{field} must not contain a NUL byte")
    if len(text) > max_chars:
        raise FMError(f"{field} must be {max_chars} characters or fewer")
    return text


def parse_card_spec(raw: Dict[str, Any], max_chars: int = DEFAULT_REPLY_MAX_CHARS) -> Dict[str, Any]:
    """Validate one caller-supplied card definition under the reply length bound.

    The caller owns every captain-facing word: the body, the option labels, and
    each decisive option's value. Nothing here derives an option from prose. A
    task card names the captain-held task its press answers; a transcript card
    names the uncertain-transcription request its press confirms, corrects, or
    discards.
    """
    if not isinstance(raw, dict):
        raise FMError("the card file must be a JSON object")
    schema = raw.get("schema", CARD_SCHEMA)
    if schema != CARD_SCHEMA:
        raise FMError(f"unsupported card schema: {schema}")
    kind = raw.get("kind", CARD_KIND_TASK)
    if kind not in CARD_KINDS:
        raise FMError(f"card.kind must be one of: {', '.join(CARD_KINDS)}")
    card_type = str(raw.get("type") or DEFAULT_CARD_TYPE).strip().lower()
    if card_type not in CARD_TYPES:
        raise FMError(f"card.type must be one of: {', '.join(CARD_TYPES)}")
    task_id = ""
    request_id = ""
    if kind == CARD_KIND_TRANSCRIPT:
        request_id = _card_text(raw.get("request_id"), "card.request_id", 200)
        if not fwl.REQUEST_RE.fullmatch(request_id):
            raise FMError("card.request_id must be a discord:<guild>:<channel>:<message> request id")
    else:
        task_id = _card_text(raw.get("task_id"), "card.task_id", 120)
        if not fwl.TASK_ID_RE.fullmatch(task_id):
            raise FMError("card.task_id must be a privacy-safe task id")
    body = _card_text(raw.get("body"), "card.body", MAX_CARD_BODY_CHARS)
    for marker in REFUSED_MARKERS:
        if marker in body:
            raise FMError("card.body must not contain operational text")
    hint = _card_text(raw.get("fallback_hint"), "card.fallback_hint", MAX_CARD_HINT_CHARS, required=False)
    raw_options = raw.get("options")
    if not isinstance(raw_options, list) or not raw_options:
        raise FMError("card.options must be a non-empty list")
    if len(raw_options) > MAX_CARD_OPTIONS:
        raise FMError(f"card.options may carry at most {MAX_CARD_OPTIONS} options")
    options: List[Dict[str, Any]] = []
    labels: set = set()
    for index, item in enumerate(raw_options):
        if not isinstance(item, dict):
            raise FMError(f"card.options[{index}] must be a JSON object")
        label = _card_text(item.get("label"), f"card.options[{index}].label", MAX_CARD_LABEL_CHARS)
        if label.lower() in labels:
            raise FMError(f"card.options[{index}].label duplicates an earlier label")
        labels.add(label.lower())
        action = item.get("action")
        if action not in CARD_ACTIONS:
            raise FMError(f"card.options[{index}].action must be one of: {', '.join(CARD_ACTIONS)}")
        option: Dict[str, Any] = {"label": label, "action": action}
        style = item.get("style", CARD_STYLE_BY_ACTION[action])
        if isinstance(style, bool) or not isinstance(style, int) or style not in CARD_BUTTON_STYLES:
            raise FMError(f"card.options[{index}].style must be one of {', '.join(str(s) for s in CARD_BUTTON_STYLES)}")
        option["style"] = style
        if action in ("answer", "release"):
            option["value"] = _card_text(item.get("value"), f"card.options[{index}].value", MAX_CARD_VALUE_CHARS)
        elif action == "later":
            until = _card_text(item.get("until"), f"card.options[{index}].until", 10)
            if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", until):
                raise FMError(f"card.options[{index}].until must be a YYYY-MM-DD date")
            option["until"] = until
        options.append(option)
    content = body if not hint else f"{body}\n\n{hint}"
    if len(content) > max_chars:
        raise FMError(f"the rendered card is longer than the {max_chars} character reply bound")
    return {
        "kind": kind,
        "type": card_type,
        "task_id": task_id,
        "request_id": request_id,
        "body": body,
        "fallback_hint": hint,
        "options": options,
    }


def render_card_content(spec: Dict[str, Any], suffix: str = "") -> str:
    content = str(spec.get("body") or "")
    hint = str(spec.get("fallback_hint") or "")
    if hint:
        content = f"{content}\n\n{hint}"
    if suffix:
        content = f"{content}\n\n{suffix}"
    return content


def card_components(spec: Dict[str, Any], card_id: str, disabled: bool = False) -> List[Dict[str, Any]]:
    """One action row of up to five custom-id buttons, optionally disabled."""
    buttons: List[Dict[str, Any]] = []
    options = spec.get("options") if isinstance(spec.get("options"), list) else []
    for index, option in enumerate(options):
        style = option.get("style")
        if isinstance(style, bool) or not isinstance(style, int) or style not in CARD_BUTTON_STYLES:
            style = CARD_STYLE_BY_ACTION.get(str(option.get("action")), 2)
        button: Dict[str, Any] = {
            "type": 2,
            "style": style,
            "label": str(option.get("label") or ""),
            "custom_id": card_custom_id(card_id, index),
        }
        if disabled:
            button["disabled"] = True
        buttons.append(button)
    return [{"type": 1, "components": buttons}]


def load_card(env: "fwl.Env", card_id: str) -> Optional[Dict[str, Any]]:
    return fwl.load_existing_json(card_path(env, card_id))


def load_cards(env: "fwl.Env") -> List[Dict[str, Any]]:
    directory = cards_dir(env)
    cards: List[Dict[str, Any]] = []
    if not directory.is_dir():
        return cards
    for path in sorted(directory.glob("*.json")):
        record = fwl.load_existing_json(path)
        if isinstance(record, dict):
            cards.append(record)
    return cards


def open_card_for_task(env: "fwl.Env", task_id: str) -> Optional[Dict[str, Any]]:
    for record in load_cards(env):
        if str(record.get("task_id") or "") == task_id and str(record.get("status") or "open") == "open":
            return record
    return None


def store_card(env: "fwl.Env", card: Dict[str, Any]) -> None:
    stored = dict(card)
    stored["updated_at"] = fwl.utc_now()
    with fwl.state_transaction(env):
        fwl.atomic_json(card_path(env, str(card.get("card_id") or "")), stored)


def load_card_interaction(env: "fwl.Env", interaction_id: str) -> Optional[Dict[str, Any]]:
    try:
        return fwl.load_existing_json(card_interaction_path(env, interaction_id))
    except FMError:
        return None


def store_card_interaction(env: "fwl.Env", interaction_id: str, record: Dict[str, Any]) -> None:
    stored = dict(record)
    stored.update({"schema": CARD_INTERACTION_SCHEMA, "interaction_id": interaction_id, "recorded_at": fwl.utc_now()})
    path = card_interaction_path(env, interaction_id)
    with fwl.state_transaction(env):
        fwl.atomic_json(path, stored)
        prune_card_interactions(path.parent)


def prune_card_interactions(directory: Path) -> None:
    try:
        records = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    except OSError:
        return
    for stale in records[MAX_CARD_INTERACTION_RECORDS:]:
        try:
            stale.unlink()
        except OSError:
            pass


def card_answer_suffix(option: Dict[str, Any]) -> str:
    label = str(option.get("label") or "")
    if str(option.get("action") or "") == "later":
        return "**Report\u00e9 au %s : %s**" % (str(option.get("until") or ""), label)
    return "**R\u00e9pondu : %s**" % label


def card_settled_suffix(card: Dict[str, Any]) -> str:
    answer = card.get("answer") if isinstance(card.get("answer"), dict) else {}
    label = str(answer.get("label") or "")
    if not label:
        return ""
    if str(answer.get("action") or "") == "later":
        return "**Report\u00e9 au %s : %s**" % (str(answer.get("until") or ""), label)
    return "**R\u00e9pondu : %s**" % label


def card_later_reason(option: Dict[str, Any]) -> str:
    label = re.sub(r"[()]", " ", str(option.get("label") or ""))
    label = re.sub(r"\s+", " ", label).strip()
    reason = f"Report\u00e9 par carte Discord : {label}".strip()
    return reason[:200] or "Report\u00e9 par carte Discord"


def write_card_decision_file(value: str) -> str:
    fd, path = tempfile.mkstemp(prefix="fm-card-decision-", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(value)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.unlink(path)
        except OSError:
            pass
        raise
    return path


def run_captain_hold(env: "fwl.Env", argv: List[str]) -> Tuple[int, str]:
    """Feed one card option into the same keyed-answer intake a typed reply uses."""
    command = [str(env.script_dir / "fm-captain-hold.sh")] + argv
    child_env = dict(os.environ)
    child_env["FM_HOME"] = str(env.home)
    child_env["FM_STATE_OVERRIDE"] = str(env.state)
    child_env["FM_DATA_OVERRIDE"] = str(env.data)
    child_env["FM_CONFIG_OVERRIDE"] = str(env.config)
    timeout = CARD_ANSWER_TIMEOUT_SECONDS
    override = os.environ.get("FM_CONSOLE_CARD_TIMEOUT")
    if override:
        try:
            parsed = float(override)
            if parsed > 0:
                timeout = parsed
        except ValueError:
            pass
    try:
        proc = subprocess.run(
            command, env=child_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return 1, "the answer intake did not finish in time"
    except OSError as exc:
        return 1, f"the answer intake could not start: {exc}"
    return proc.returncode, (proc.stdout + proc.stderr).strip()


def run_card_option(env: "fwl.Env", task_id: str, option: Dict[str, Any]) -> Tuple[int, str]:
    action = str(option.get("action") or "")
    decision_path = ""
    try:
        if action in ("answer", "release"):
            decision_path = write_card_decision_file(str(option.get("value") or ""))
        if action == "later":
            argv = ["hold", task_id, "--reason", card_later_reason(option), "--until", str(option.get("until") or "")]
        elif action == "release":
            argv = ["answer", task_id, "--decision-file", decision_path, "--release"]
        else:
            argv = ["answer", task_id, "--decision-file", decision_path]
        return run_captain_hold(env, argv)
    finally:
        if decision_path:
            try:
                os.unlink(decision_path)
            except OSError:
                pass


def card_hold_refusal(task_id: str, code: int, detail: str) -> str:
    """One clear refusal naming the task and why a card may not be posted.

    The hold predicate (``fm-captain-hold.sh open``) is the authoritative state,
    not the card's prose: exit 1 means the task is not an open captain call
    (unheld queued work or an already-closed task), and exit 3 means this home's
    backlog carries no such task at all. Exit 2 is "cannot establish", which is
    never read as permission to post a card whose presses could never validate.
    """
    reason = (detail or "").strip()
    if code == 1:
        return f"task {task_id} is not held for the captain"
    if code == 3:
        return f"task {task_id} is not held for the captain: this home's backlog has no such task"
    if code == 2:
        return f"task {task_id} is not held for the captain: its hold state could not be read" + (
            f" ({reason})" if reason else ""
        )
    return f"task {task_id} is not held for the captain"


def require_captain_held(env: "fwl.Env", task_id: str) -> None:
    """Refuse to post a card for a task that is not currently captain-held.

    The press-time intake stays the second line of defence; this is the first,
    so a posted card is one whose every button can still validate.
    """
    code, output = run_captain_hold(env, ["open", task_id, "--distinguish-absent"])
    if code != 0:
        raise FMError(card_hold_refusal(task_id, code, output))


def card_spec_from_card(card: Dict[str, Any]) -> Dict[str, Any]:
    """The renderable subset of a stored card record."""
    return {
        "body": str(card.get("body") or ""),
        "fallback_hint": str(card.get("fallback_hint") or ""),
        "options": card.get("options") if isinstance(card.get("options"), list) else [],
    }


def card_surfaces(card: Dict[str, Any]) -> List[Tuple[str, str]]:
    """Every (channel_id, message_id) a card identity is currently posted to.

    The originating conversation's surface is always first; the escalation
    mirror, when it landed, is second. Both carry the same card id and custom
    ids, so a press on either resolves the one durable card.
    """
    surfaces: List[Tuple[str, str]] = []
    channel_id = str(card.get("channel_id") or "")
    message_id = str(card.get("message_id") or "")
    if channel_id and message_id:
        surfaces.append((channel_id, message_id))
    escalation = card.get("escalation") if isinstance(card.get("escalation"), dict) else {}
    if escalation.get("delivered"):
        mirror_channel = str(escalation.get("channel_id") or "")
        mirror_message = str(escalation.get("message_id") or "")
        if mirror_channel and mirror_message and (mirror_channel, mirror_message) not in surfaces:
            surfaces.append((mirror_channel, mirror_message))
    return surfaces


def card_matches_surface(card: Dict[str, Any], guild_id: str, channel_id: str, message_id: str) -> bool:
    """Whether a press came from one of a card's recorded surfaces.

    The originating surface also checks the guild id; the escalation mirror is
    matched on its channel and message, which is enough because the card id in
    the custom id and the captain-only check already bind the press.
    """
    if (
        str(card.get("channel_id") or "") == channel_id
        and str(card.get("message_id") or "") == message_id
        and str(card.get("guild_id") or "") == guild_id
    ):
        return True
    return (channel_id, message_id) in card_surfaces(card)


def card_payload(card: Dict[str, Any], suffix: str = "", disabled: bool = False) -> Dict[str, Any]:
    """The rendered card message body used for every edit of one card identity."""
    spec = card_spec_from_card(card)
    return {
        "content": render_card_content(spec, suffix),
        "components": card_components(spec, str(card.get("card_id") or ""), disabled=disabled),
        "allowed_mentions": {"parse": []},
    }


def run_card_escalations(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient") -> Dict[str, int]:
    """Run one bounded escalation pass over open, unanswered task cards.

    A card left unanswered past the configured delay while its task is still an
    open captain call is mirrored once into the dedicated #blocages channel,
    carrying the same durable card identity and custom ids, so a press on either
    surface resolves the one card. The single attempt is recorded on the card
    whether it lands or not, so a broken gateway can never spin; answered,
    closed, already-escalated, and too-young cards get none. A failed or
    undeliverable mirror is recorded as a visible delivery gap, never silently.
    """
    stats = {"scanned": 0, "escalated": 0, "skipped": 0, "failed": 0}
    delay = cfg.card_escalation_delay_seconds
    now = time.time()
    for card in load_cards(env):
        if str(card.get("kind") or CARD_KIND_TASK) != CARD_KIND_TASK:
            continue
        if str(card.get("status") or "open") != "open":
            continue
        stats["scanned"] += 1
        if isinstance(card.get("escalation"), dict):
            stats["skipped"] += 1
            continue
        created = parse_discord_epoch(None, card.get("created_at"))
        if created is None or now - created < delay:
            stats["skipped"] += 1
            continue
        task_id = str(card.get("task_id") or "")
        try:
            require_captain_held(env, task_id)
        except FMError:
            # The call is answered or closed; a mirror's buttons could no
            # longer validate.
            stats["skipped"] += 1
            continue
        target = str(cfg.card_escalation_channel_id or "")
        escalation: Dict[str, Any] = {"at": fwl.utc_now(), "delivered": False}
        if not cfg.live_posting_enabled or not target:
            reason = "posting unavailable" if not cfg.live_posting_enabled else "no #blocages channel configured"
            escalation["reason"] = reason
            record_delivery_gap(
                env, "card-escalation", f"card escalation for task {task_id} not delivered: {reason}"
            )
        else:
            try:
                spec = card_spec_from_card(card)
                message_id = client.post_message(
                    target,
                    render_card_content(spec),
                    card_components(spec, str(card.get("card_id") or "")),
                )
                escalation.update({"delivered": True, "channel_id": target, "message_id": message_id})
            except FMError as exc:
                reason = client.redact(str(exc))
                escalation["reason"] = reason
                record_delivery_gap(
                    env, "card-escalation", f"card escalation for task {task_id} failed: {reason}"
                )
        # The single attempt is consumed whether or not it landed, so a
        # persistent failure can never turn into an escalation loop.
        card["escalation"] = escalation
        store_card(env, card)
        stats["escalated" if escalation["delivered"] else "failed"] += 1
    return stats


def maybe_run_card_escalations(
    env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", state: Dict[str, Any]
) -> None:
    """Run the bounded escalation scan at most once per scan interval.

    Called from the permanent-connection loop, so an unanswered held card is
    mirrored into #blocages without any manual step. A scan failure is recorded
    and never kills the connection loop.
    """
    now = time.monotonic()
    try:
        last = float(state.get("last_card_escalation_scan") or 0.0)
    except (TypeError, ValueError):
        last = 0.0
    if now - last < CARD_ESCALATION_SCAN_INTERVAL_SECONDS:
        return
    state["last_card_escalation_scan"] = now
    try:
        run_card_escalations(env, cfg, client)
    except Exception as exc:  # noqa: BLE001 - the loop must survive any scan failure
        try:
            record_delivery_gap(env, "card-escalation", f"card escalation scan failed: {exc}")
        except Exception:  # noqa: BLE001
            pass


def card_wake_body(task_id: str, option: Dict[str, Any]) -> str:
    """The single durable wake line a validated card press appends.

    It names the task, the recorded option, and that a card was validated, so
    firstmate can act on the recorded answer without guessing.
    """
    action = str(option.get("action") or "answer")
    label = str(option.get("label") or "")
    return f"card {action} {task_id}: {label}".strip()


def announce_card_wake(env: "fwl.Env", body: str, interaction_id: str) -> str:
    """Append exactly one durable wake line through the captain-inbox seam.

    It rides the same captain-inbox seam a typed message uses
    (``bin/fm-inbox.sh note``), so firstmate's ordinary supervision picks the
    recorded press up without the captain saying anything in chat, and the wake
    stays durable. The interaction id is the inbox external id, so a repeated
    delivery of the same press returns the first note and appends no second
    wake. A refused or failed press never reaches here. Returns "" on success,
    or a redacted reason on failure.
    """
    command = [
        str(env.script_dir / "fm-inbox.sh"),
        "note",
        "--source",
        CARD_WAKE_SOURCE,
        "--external-id",
        interaction_id,
        "-",
    ]
    child_env = dict(os.environ)
    child_env["FM_HOME"] = str(env.home)
    child_env["FM_STATE_OVERRIDE"] = str(env.state)
    child_env["FM_DATA_OVERRIDE"] = str(env.data)
    child_env["FM_CONFIG_OVERRIDE"] = str(env.config)
    timeout = CARD_WAKE_TIMEOUT_SECONDS
    override = os.environ.get("FM_CONSOLE_CARD_WAKE_TIMEOUT")
    if override:
        try:
            parsed = float(override)
            if parsed > 0:
                timeout = parsed
        except ValueError:
            pass
    try:
        proc = subprocess.run(
            command,
            env=child_env,
            input=body,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "the card wake did not finish in time"
    except OSError as exc:
        return f"the card wake could not start: {exc}"
    if proc.returncode != 0:
        return ((proc.stdout + proc.stderr).strip() or "the card wake was refused")[:500]
    return ""


def announce_card_answer(env: "fwl.Env", task_id: str, option: Dict[str, Any], interaction_id: str) -> str:
    """Append exactly one durable wake for a validated task-card press."""
    return announce_card_wake(env, card_wake_body(task_id, option), interaction_id)


def transcript_card_wake_body(request_id: str, option: Dict[str, Any]) -> str:
    """The single durable wake line a validated uncertain-reading press appends.

    The key is the transcription request the reading belongs to, not a task:
    an uncertain reading is not a captain-held backlog task and the console
    never mints one, so the wake names the reading's own outcome instead.
    """
    outcome = {
        "answer": "transcript confirmed",
        "release": "transcript reading discarded",
        "chat": "transcript correction requested",
    }.get(str(option.get("action") or "answer"), "transcript card")
    return f"{outcome} {request_id}: {str(option.get('label') or '')}".strip()


def announce_transcript_card_press(env: "fwl.Env", request_id: str, option: Dict[str, Any], interaction_id: str) -> str:
    """Append exactly one durable wake for a validated uncertain-reading press."""
    return announce_card_wake(env, transcript_card_wake_body(request_id, option), interaction_id)


def transcript_card_id(request_id: str) -> str:
    """The confirmation card of one transcription request, derived from it.

    The request id is the nonce, so a replayed capture resolves to the same card
    id and posts no second card.
    """
    return card_id_for(f"transcript:{request_id}")


def build_transcript_card_spec(event: Dict[str, Any], reading: str) -> Dict[str, Any]:
    """The uncertain reading as the three existing card actions it maps onto."""
    body = f"{DEFAULT_TRANSCRIPTION_UNCERTAIN_PREFIX}{reading.strip()}\n\n{TRANSCRIPT_CARD_CONTEXT}"
    options = [
        {
            "label": TRANSCRIPT_CARD_CONFIRM_LABEL,
            "action": "answer",
            "value": reading.strip(),
            "style": TRANSCRIPT_CARD_CONFIRM_STYLE,
        },
        {"label": TRANSCRIPT_CARD_CORRECT_LABEL, "action": "chat", "style": TRANSCRIPT_CARD_CORRECT_STYLE},
        {
            "label": TRANSCRIPT_CARD_DISCARD_LABEL,
            "action": "release",
            "value": reading.strip(),
            "style": TRANSCRIPT_CARD_DISCARD_STYLE,
        },
    ]
    return parse_card_spec(
        {
            "schema": CARD_SCHEMA,
            "kind": CARD_KIND_TRANSCRIPT,
            "request_id": str(event.get("request_id") or ""),
            "body": body,
            "fallback_hint": TRANSCRIPT_CARD_HINT,
            "options": options,
        }
    )


def store_transcript_card_outcome(env: "fwl.Env", request_id: str, card_id: str = "", reason: str = "") -> None:
    """Fold the confirmation card's outcome into the reading's own record.

    The card record is the durable record of the press; this makes the reading's
    transcript record answer whether a card was posted for it and why a card was
    not posted, which is what an operator needs to see when no card appeared.
    It is bookkeeping beside a delivery in progress, so it never raises.
    """
    if not request_id:
        return
    try:
        record = load_transcript_record(env, request_id)
        if not isinstance(record, dict):
            return
        if card_id:
            record["confirm_card"] = {"status": "posted", "card_id": card_id}
        else:
            record["confirm_card"] = {"status": "skipped", "reason": (reason or "no reason recorded")[:200]}
        store_transcript_record(env, request_id, record)
    except FMError:
        return


def record_transcript_confirmation(
    env: "fwl.Env", request_id: str, status: str, option: Dict[str, Any], user_id: str
) -> None:
    """Record the captain's confirmation of the reading on the transcript record.

    A missing or unreadable record is not an error: the card record itself still
    holds the press, so this never raises on the press path.
    """
    if not request_id:
        return
    try:
        record = load_transcript_record(env, request_id)
        if not isinstance(record, dict):
            return
        record["confirmation"] = {
            "status": status,
            "action": str(option.get("action") or ""),
            "label": str(option.get("label") or ""),
            "user_id": user_id,
            "at": fwl.utc_now(),
        }
        store_transcript_record(env, request_id, record)
    except FMError:
        return


def post_transcript_card(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    event: Dict[str, Any],
    reading: str,
) -> Tuple[str, str]:
    """Post the confirmation card for one uncertain reading, or say why not.

    Returns ``(card_id, reason)``: an id once the reading's card exists durably,
    else an empty id and the reason it was not posted. It is posted only where
    its press could arrive - posting on, the permanent connection on and
    registered - because a bounded poll cannot receive an interaction, and it is
    idempotent by request id, so a replayed delivery posts no second card.
    Nothing here ever fails the transcription delivery it accompanies.
    """
    request_id = str(event.get("request_id") or "")
    if not cfg.transcription_confirm_card:
        return "", "the confirmation card is off"
    if not request_id:
        return "", "the audio message carries no request id"
    card_id = transcript_card_id(request_id)
    try:
        existing = load_card(env, card_id)
    except FMError:
        existing = None
    if isinstance(existing, dict) and existing.get("message_id"):
        return card_id, ""
    if not cfg.live_posting_enabled:
        return "", "live posting is off"
    if not cfg.live_gateway_enabled:
        return "", "the permanent connection is off"
    if not (env.state / "procevent" / f"{GATEWAY_SOURCE_ID}.source").is_file():
        return "", "the permanent connection is not registered"
    if not reading.strip():
        return "", "the reading is empty"
    try:
        spec = build_transcript_card_spec(event, reading)
    except FMError as exc:
        return "", client.redact(str(exc))[:200]
    try:
        message_id = client.post_message(
            str(event.get("channel_id") or ""), render_card_content(spec), card_components(spec, card_id)
        )
    except FMError as exc:
        return "", client.redact(str(exc))[:200]
    try:
        store_card(
            env,
            {
                "schema": CARD_SCHEMA,
                "kind": CARD_KIND_TRANSCRIPT,
                "card_id": card_id,
                "nonce": f"transcript:{request_id}",
                "request_id": request_id,
                "task_id": "",
                "guild_id": str(event.get("guild_id") or ""),
                "channel_id": str(event.get("channel_id") or ""),
                "message_id": message_id,
                "body": spec["body"],
                "fallback_hint": spec["fallback_hint"],
                "options": spec["options"],
                "status": "open",
                "created_at": fwl.utc_now(),
            },
        )
    except FMError as exc:
        return "", f"the card was posted but could not be recorded: {client.redact(str(exc))[:200]}"
    return card_id, ""


def card_ephemeral(client: "ConsoleClient", token: str, text: str) -> None:
    """Send one private follow-up message through the interaction webhook.

    The deferred acknowledgement already consumed the interaction callback, so a
    refusal or the free-form option answers as a follow-up instead of a second
    callback, which Discord rejects.
    """
    client.interaction_followup(
        token,
        {"content": text, "flags": CARD_EPHEMERAL_FLAG, "allowed_mentions": {"parse": []}},
    )


def settle_card_surfaces(
    env: "fwl.Env",
    client: "ConsoleClient",
    card: Dict[str, Any],
    token: str,
    pressed_channel_id: str,
    pressed_message_id: str,
    suffix: str = "",
    disabled: bool = False,
) -> None:
    """Reflect one card's resolved state on every surface it was posted to.

    The pressed surface is edited through the interaction webhook, which is the
    only way to update the message a deferred component interaction refers to.
    The escalation mirror, if it landed, is edited through the ordinary message
    endpoint so both surfaces show the same recorded answer and disabled
    buttons. A mirror edit failure is recorded as a delivery gap rather than
    swallowed, and never blocks the interaction's own edit.
    """
    payload = card_payload(card, suffix, disabled)
    try:
        client.interaction_edit_original(token, payload)
    except FMError:
        pass
    for channel_id, message_id in card_surfaces(card):
        if channel_id == pressed_channel_id and message_id == pressed_message_id:
            continue
        try:
            client.edit_message(channel_id, message_id, payload)
        except FMError as exc:
            record_delivery_gap(
                env,
                "card-escalation",
                f"card mirror edit for {card.get('card_id')} failed: {client.redact(str(exc))}",
            )


def handle_card_interaction(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    client: "ConsoleClient",
    interaction_id: str,
    token: str,
    user_id: str,
    custom_id: str,
    guild_id: str,
    channel_id: str,
    message_id: str,
) -> None:
    """Validate one component press, record it, and answer its interaction.

    The deferred acknowledgement is the first thing this handler does, before
    any validation or state read, so it reaches Discord inside its 3-second
    window; a failed acknowledgement is recorded instead of being swallowed.
    Every later answer travels the interaction webhook - a card edit for a
    recorded option, a private follow-up for a refusal or the free-form "answer
    in chat" option - because Discord rejects a second callback. The interaction
    id is recorded durably, so a repeated delivery records no second answer.
    A recorded option, a deferral, and the free-form chat choice each also append
    exactly one durable wake through the captain-inbox seam, idempotent by
    interaction id.
    """
    ack_error = ""

    def record(status: str, **fields: Any) -> None:
        payload = {
            "status": status,
            "user_id": user_id,
            "custom_id": custom_id,
            "guild_id": guild_id,
            "channel_id": channel_id,
            "message_id": message_id,
            **fields,
        }
        if ack_error:
            payload["ack_error"] = ack_error
        store_card_interaction(env, interaction_id, payload)

    def followup(text: str) -> None:
        try:
            card_ephemeral(client, token, text)
        except FMError:
            pass

    def refuse(status: str, reason: str) -> None:
        record(status, reason=reason)
        followup(CARD_REFUSAL_TEXTS.get(reason, CARD_ERROR_TEXT))

    try:
        client.interaction_ack(interaction_id, token)
    except FMError as exc:
        ack_error = client.redact(str(exc))[:500]
        record("ack-failed", reason=ack_error)

    if not user_id:
        # No usable identity is not the same as a known non-captain, so this must
        # not tell the presser that only the captain may answer.
        refuse("unidentified", "missing-user-id")
        return
    if user_id not in cfg.captain_user_ids:
        refuse("refused", "non-captain")
        return
    match = CARD_CUSTOM_ID_RE.fullmatch(custom_id)
    if match is None:
        refuse("refused", "unknown-custom-id")
        return
    card_id, index = match.group(1), int(match.group(2))
    try:
        card = load_card(env, card_id)
    except FMError:
        refuse("refused", "unreadable-card")
        return
    if not isinstance(card, dict):
        refuse("refused", "unknown-card")
        return
    if not card_matches_surface(card, guild_id, channel_id, message_id):
        refuse("refused", "card-mismatch")
        return
    options = card.get("options") if isinstance(card.get("options"), list) else []
    if index >= len(options) or not isinstance(options[index], dict):
        refuse("refused", "unknown-option")
        return
    option = options[index]
    is_transcript = str(card.get("kind") or CARD_KIND_TASK) == CARD_KIND_TRANSCRIPT
    prior = load_card_interaction(env, interaction_id)
    prior_status = str(prior.get("status") or "") if isinstance(prior, dict) else ""
    # A repeated delivery never records twice; it replays the first answer.
    if prior_status in ("recorded", "settled") or str(card.get("status") or "open") != "open":
        if prior_status not in ("recorded", "settled"):
            record("settled", option_index=index)
        try:
            settle_card_surfaces(env, client, card, token, channel_id, message_id, suffix=card_settled_suffix(card), disabled=True)
        except FMError:
            pass
        return
    if prior_status == "chat":
        followup(CARD_CHAT_CONFIRMATION)
        return
    if str(option.get("action") or "") == "chat":
        # No answer is recorded: the captain will answer in the conversation.
        # The wake still fires, so firstmate knows to expect a chat answer.
        task_id = str(card.get("task_id") or "")
        request_id = str(card.get("request_id") or "")
        wake_error = (
            announce_transcript_card_press(env, request_id, option, interaction_id)
            if is_transcript
            else announce_card_answer(env, task_id, option, interaction_id)
        )
        chat_fields: Dict[str, Any] = {"option_index": index}
        if wake_error:
            chat_fields["wake_error"] = client.redact(wake_error)[:500]
        record("chat", **chat_fields)
        if is_transcript:
            record_transcript_confirmation(env, request_id, "correcting", option, user_id)
        followup(CARD_CHAT_CONFIRMATION)
        return
    record("pending", option_index=index)
    if is_transcript:
        # An uncertain reading is not a captain-held task, so a transcript press
        # never touches a hold: it records the outcome on the card and on the
        # reading itself and appends one wake, and it deletes nothing - the
        # transcript record, the second reading, and the audio path are untouched.
        # The console builds exactly the confirm, correct, and discard options,
        # so any other action on a transcript card is recorded as failed rather
        # than acted on.
        action = str(option.get("action") or "")
        if action not in ("answer", "release"):
            record("failed", option_index=index, reason="unsupported-transcript-option")
            return
        task_id = str(card.get("task_id") or "")
        request_id = str(card.get("request_id") or "")
        card["status"] = "answered"
        card["answer"] = {
            "option_index": index,
            "label": str(option.get("label") or ""),
            "action": action,
            "value": str(option.get("value") or ""),
            "until": "",
            "user_id": user_id,
            "answered_at": fwl.utc_now(),
        }
        store_card(env, card)
        record_transcript_confirmation(
            env, request_id, "confirmed" if action == "answer" else "discarded", option, user_id
        )
        wake_error = announce_transcript_card_press(env, request_id, option, interaction_id)
        pressed_fields: Dict[str, Any] = {"option_index": index, "action": action}
        if wake_error:
            pressed_fields["wake_error"] = client.redact(wake_error)[:500]
        record("recorded", **pressed_fields)
        try:
            settle_card_surfaces(env, client, card, token, channel_id, message_id, suffix=card_answer_suffix(option), disabled=True)
        except FMError:
            pass
        return
    task_id = str(card.get("task_id") or "")
    code, output = run_card_option(env, task_id, option)
    if code != 0:
        record("failed", option_index=index, reason=client.redact(output)[:500])
        try:
            settle_card_surfaces(env, client, card, token, channel_id, message_id, suffix=CARD_FAILURE_SUFFIX, disabled=False)
        except FMError:
            pass
        return
    card["status"] = "answered"
    card["answer"] = {
        "option_index": index,
        "label": str(option.get("label") or ""),
        "action": str(option.get("action") or ""),
        "value": str(option.get("value") or ""),
        "until": str(option.get("until") or ""),
        "user_id": user_id,
        "answered_at": fwl.utc_now(),
    }
    store_card(env, card)
    # Announce the recorded answer through the captain-inbox seam before the
    # "recorded" marker, so an interrupted press cannot lose the wake; the
    # interaction id keeps a redelivery from appending a second one.
    wake_error = announce_card_answer(env, task_id, option, interaction_id)
    recorded_fields: Dict[str, Any] = {"option_index": index, "action": str(option.get("action") or "")}
    if wake_error:
        recorded_fields["wake_error"] = client.redact(wake_error)[:500]
    record("recorded", **recorded_fields)
    try:
        settle_card_surfaces(env, client, card, token, channel_id, message_id, suffix=card_answer_suffix(option), disabled=True)
    except FMError:
        pass


# ---------------------------------------------------------------------------
# Discord HTTP helpers
# ---------------------------------------------------------------------------


class ConsoleClient:
    def __init__(self, cfg: "ConsoleConfig", env: "fwl.Env"):
        self.cfg = cfg
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

    def post_message(self, channel_id: str, text: str, components: Optional[List[Dict[str, Any]]] = None) -> str:
        """Post one message; ``components`` carries an action card's buttons.

        Discord-native action buttons are posted as a ``components`` array on the
        message body. The reply path passes none; the ``card`` command passes one
        action row, and refuses unless the permanent connection is registered,
        because a button can only be answered through a gateway interaction.
        """
        body: Dict[str, Any] = {"content": text, "allowed_mentions": {"parse": []}}
        if components:
            body["components"] = components
        sent = self.client.request(
            "POST",
            f"/channels/{channel_id}/messages",
            body,
        )
        message_id = str(sent.get("id") or "") if isinstance(sent, dict) else ""
        if not message_id.isdigit():
            raise FMError("Discord did not return a usable message id for the reply")
        return message_id

    def edit_message(self, channel_id: str, message_id: str, payload: Dict[str, Any]) -> None:
        """Edit one already-posted message by its channel and message id.

        Used to reflect a resolved card on its escalation mirror, which has no
        interaction token; the pressed surface is edited through the interaction
        webhook instead.
        """
        self.client.request("PATCH", f"/channels/{channel_id}/messages/{message_id}", payload)

    def typing(self, channel_id: str) -> None:
        """Emit the Discord typing indicator in one channel (best effort)."""
        self.client.request("POST", f"/channels/{channel_id}/typing")

    def download_attachment(self, url: str, dest: Path, max_bytes: int) -> int:
        """Stream one validated CDN attachment to a local file under the byte cap.

        The destination is a mode-0600 temporary file the caller deletes; the
        byte count is enforced both from Content-Length and while streaming, so
        a lying header cannot exceed the configured bound.
        """
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bot {self.token}",
                "User-Agent": live.USER_AGENT,
                "Accept": "*/*",
            },
        )
        total = 0
        try:
            with urllib.request.urlopen(request, timeout=60.0) as response:
                length = response.headers.get("Content-Length")
                if length is not None:
                    try:
                        if int(length) > max_bytes:
                            raise FMError("audio attachment exceeds the configured size limit")
                    except ValueError:
                        pass
                with open(dest, "wb") as handle:
                    while True:
                        chunk = response.read(65536)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > max_bytes:
                            raise FMError("audio attachment exceeds the configured size limit")
                        handle.write(chunk)
        except urllib.error.HTTPError as exc:
            raise FMError(self.redact(f"audio download failed with HTTP {exc.code}")) from exc
        except urllib.error.URLError as exc:
            raise FMError(self.redact(f"audio download failed: {exc.reason}")) from exc
        if total <= 0:
            raise FMError("the downloaded audio was empty")
        return total

    def channel(self, channel_id: str) -> Dict[str, Any]:
        info = self.client.request("GET", f"/channels/{channel_id}")
        return info if isinstance(info, dict) else {}

    def interaction_ack(self, interaction_id: str, interaction_token: str) -> None:
        """Defer the card update as the first acknowledgement of a press.

        This must reach Discord before its 3-second interaction window closes, so
        it uses a short timeout and is never retried: a retried acknowledgement
        would arrive after Discord already reported the interaction as failed.
        The interaction token in the path is the credential, so no Authorization
        header rides this path.
        """
        self._interaction_request(
            "POST",
            f"/interactions/{interaction_id}/{interaction_token}/callback",
            {"type": CARD_CALLBACK_DEFERRED_UPDATE},
            timeout=card_ack_timeout_seconds(),
            retry=False,
        )

    def interaction_followup(self, interaction_token: str, payload: Dict[str, Any]) -> None:
        """Send one follow-up message through the interaction webhook.

        After the first deferred acknowledgement, a refusal or the free-form
        option answers here rather than through a second callback, which Discord
        would reject.
        """
        self._interaction_request(
            "POST", f"/webhooks/{self.cfg.bot_user_id}/{interaction_token}", payload
        )

    def interaction_edit_original(self, interaction_token: str, payload: Dict[str, Any]) -> None:
        """Edit the card message a deferred component interaction refers to."""
        self._interaction_request(
            "PATCH",
            f"/webhooks/{self.cfg.bot_user_id}/{interaction_token}/messages/@original",
            payload,
        )

    def _interaction_request(
        self,
        method: str,
        path: str,
        body: Dict[str, Any],
        timeout: Optional[float] = None,
        retry: bool = True,
    ) -> Dict[str, Any]:
        data = json.dumps(body).encode("utf-8")
        headers = {
            "User-Agent": live.USER_AGENT,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        url = f"{self.client.base}{path}"
        request_timeout = CARD_CALLBACK_TIMEOUT_SECONDS if timeout is None else timeout
        last_error = ""
        for attempt in range(2 if retry else 1):
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=request_timeout) as response:
                    payload = response.read().decode("utf-8")
                    return json.loads(payload) if payload else {}
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")
                last_error = live.redact(f"Discord interaction {method} failed with HTTP {exc.code}: {detail}", self.token)
                if retry and attempt == 0 and (exc.code == 429 or 500 <= exc.code < 600):
                    time.sleep(self.client._retry_after(detail, exc.headers))
                    continue
                raise FMError(last_error) from exc
            except (urllib.error.URLError, OSError) as exc:
                reason = getattr(exc, "reason", exc)
                last_error = live.redact(f"Discord interaction {method} transport failure: {reason}", self.token)
                # A timed-out request is never retried: the interaction window is
                # already closing, and a late retry could double-answer the press.
                timed_out = isinstance(reason, (socket.timeout, TimeoutError))
                if retry and attempt == 0 and not timed_out:
                    time.sleep(float(os.environ.get("FM_DISCORD_LIVE_RETRY_SLEEP", "1")))
                    continue
                raise FMError(last_error) from exc
        raise FMError(last_error or f"Discord interaction {method} failed")


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
    client: "ConsoleClient",
    channel: ConsoleChannel,
    channel_id: str,
    parent_id: str,
    message: Dict[str, Any],
    transport: str = "",
) -> str:
    """Capture or record one message through the shared path, whichever transport saw it."""
    event = normalize_message(cfg, channel, channel_id, parent_id, message, transport)
    if route_inbound_event(env, cfg, client, event):
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
        event = normalize_message(cfg, channel, target_id, parent_id, message, "polling")
        message_id = str(event.get("message_id") or "")
        if route_inbound_event(env, cfg, client, event):
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
    ingest_message(env, cfg, client, channel, channel_id, parent_id, data, "gateway")


def handle_gateway_interaction(env: "fwl.Env", cfg: "ConsoleConfig", client: "ConsoleClient", data: Dict[str, Any]) -> None:
    """Answer one component-interaction dispatch; a card path never drops the socket.

    The presser is resolved through the shared guild/direct identity fallback
    before any validation, and the interaction is acknowledged as the first
    statement of the card handler so it fits Discord's 3-second window.
    """
    if not isinstance(data, dict) or data.get("type") != CARD_INTERACTION_COMPONENT:
        return
    interaction_id = str(data.get("id") or "")
    token = str(data.get("token") or "")
    if not interaction_id or not token:
        return
    payload = data.get("data") if isinstance(data.get("data"), dict) else {}
    message = data.get("message") if isinstance(data.get("message"), dict) else {}
    try:
        handle_card_interaction(
            env,
            cfg,
            client,
            interaction_id,
            token,
            payload_user_id(data),
            str(payload.get("custom_id") or ""),
            str(data.get("guild_id") or ""),
            str(data.get("channel_id") or ""),
            str(message.get("id") or ""),
        )
    except FMError as exc:
        try:
            store_card_interaction(
                env, interaction_id, {"status": "error", "reason": client.redact(str(exc))[:500]}
            )
        except FMError:
            pass
        try:
            card_ephemeral(client, token, CARD_ERROR_TEXT)
        except FMError:
            pass


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
                elif event_type == "INTERACTION_CREATE":
                    handle_gateway_interaction(env, cfg, client, data)
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
    fallback_noted = False
    started = time.monotonic()
    while True:
        maybe_run_card_escalations(env, cfg, client, state)
        try:
            reached = gateway_connect(env, cfg, client, state)
            if not reached:
                raise GatewaySocketError("gateway connection ended before it was established")
            failures = 0
            backoff = cfg.gateway_backoff_base
            # A live connection ends the fallback episode, so a later drop is a
            # new visible gap rather than a repeat of the silenced one.
            fallback_noted = False
            record_connection_state(
                env, "gateway", "reconnecting", error="connection closed; reconnecting", url=gateway_host_label(cfg.gateway_url)
            )
        except FMError as exc:
            failures += 1
            last_error = client.redact(str(exc))
            if failures >= cfg.gateway_fallback_after_attempts:
                mode, state_name = "polling-fallback", "polling"
                if not fallback_noted:
                    # One gap record per fallback episode, not one per bounded
                    # poll, so the permanent connection going silent stays
                    # visible without spamming the journal.
                    record_delivery_gap(
                        env,
                        "gateway-fallback",
                        f"permanent connection fell back to polling after {failures} failed attempt(s): {last_error[:300]}",
                    )
                    fallback_noted = True
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
    print(f"fast path: {'on' if cfg.fast_path_enabled else 'off'}")
    if cfg.fast_path_enabled:
        print(f"fast-path answers: {'on' if cfg.fast_path_answers_enabled else 'off'}")
        print(f"fast-path acknowledgement: {'on' if cfg.fast_path_ack_enabled else 'off'}")
        print(f"fast-path typing: {'on' if cfg.fast_path_typing_enabled else 'off'}")
        print(f"fast-path classifier: {cfg.fast_path_classifier}")
        print(f"fast-path classifier timeout: {round(cfg.fast_path_timeout, 3)}s")
    print(f"gateway url: {gateway_host_label(cfg.gateway_url)}")
    print(f"session mirror: {'on' if cfg.mirror_enabled else 'off'}")
    if cfg.mirror_channel_id:
        mirror_channel = cfg.channel_for_id(cfg.mirror_channel_id)
        print(
            "mirror channel: %s (%s)"
            % (cfg.mirror_channel_id, mirror_channel.label if mirror_channel else "not a configured channel")
        )
    print(f"mirror bound: {cfg.mirror_max_chars} chars")
    print(f"audio transcription: {'on' if cfg.transcription_enabled else 'off'}")
    if cfg.transcription_enabled:
        print(f"transcription model: {cfg.transcription_model}")
        print(f"transcription language: {cfg.transcription_language}")
        print(f"transcription confidence check: {'on' if cfg.transcription_confidence_check else 'off'}")
        print(f"transcription confirmation card: {'on' if cfg.transcription_confirm_card else 'off'}")
        print(f"transcription key reference: {cfg.transcription_key_env}")
        print(f"transcription audio bound: {cfg.audio_max_bytes} bytes, {cfg.audio_max_duration_secs:g}s")
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
    text = fwl.read_text_file(args.text_file, max_bytes=MAX_REPLY_RAW_BYTES, max_chars=MAX_REPLY_RAW_CHARS).strip()
    for marker in REFUSED_MARKERS:
        if marker in text:
            raise FMError("refusing to post operational text to a conversation channel")
    # The reply path owns the presentation: a short bold label per section,
    # bullet lines, blank lines between sections, and a hard length bound.
    text = render_captain_reply(text, cfg.reply_max_chars)
    if not text:
        raise FMError("the answer is empty after rendering")
    digest = fwl.sha256_text(text)
    anchor = args.request_id or f"discord:{guild_id}:{channel_id}:{message_id or '0'}"
    nonce = args.nonce or f"reply:{anchor}:{digest}"
    target = {"guild_id": guild_id, "channel_id": channel_id}
    if message_id:
        target["message_id"] = message_id
    receipt = fwl.base_receipt("reply", ADAPTER, target, digest)
    # The card that accompanies this reply, when the interaction supports one.
    # Its identity is keyed to the reply anchor and the card content, so a
    # replayed reply converges on the one card instead of minting a second one.
    card_spec = None
    card_nonce = ""
    if getattr(args, "card_file", None):
        card_file = Path(args.card_file).expanduser()
        if not card_file.is_absolute():
            card_file = (Path.cwd() / card_file).resolve()
        card_spec = parse_card_spec(card_spec_with_overrides(fwl.read_json(card_file), args), cfg.reply_max_chars)
        if card_spec["kind"] != CARD_KIND_TASK:
            raise FMError("reply --card-file must name a task card; the uncertain-reading card is posted by the console itself")
        if card_type_for_interaction(card_spec.get("type")) is None:
            raise FMError("no card trigger for interaction %r" % card_spec.get("type"))
        card_nonce = "reply-card:%s:%s:%s" % (
            anchor,
            card_spec["task_id"],
            fwl.sha256_text(json.dumps(card_spec, sort_keys=True))[:CARD_ID_HEX_CHARS],
        )
    if args.dry_run:
        print("Discord conversation reply plan (no network).")
        print(f"destination thread/channel: {channel_id}")
        print(f"reply-to request: {anchor}")
        print(f"allowed_mentions: {json.dumps({'parse': []}, sort_keys=True)}")
        print(f"nonce: {nonce}")
        print(f"rendered reply ({len(text)} chars, bound {cfg.reply_max_chars}):")
        print(text)
        if card_spec is not None:
            print(f"accompanying card: {card_spec.get('type') or DEFAULT_CARD_TYPE} for task {card_spec['task_id']}")
            print(f"card id: {card_id_for(card_nonce)}")
            for index, option in enumerate(card_spec["options"]):
                detail = option.get("value") or option.get("until") or ""
                print(f"  [{index}] {option['label']} -> {option['action']}" + (f" ({detail})" if detail else ""))
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
        stop_typing(env, channel_id)
        if args.request_id:
            update_latency(env, args.request_id, answered_at=time.time(), answer_message_id=str(existing.get("discord_message_id") or ""))
        print(f"receipt exists for nonce {nonce}; no second delivery")
        if card_spec is not None:
            post_reply_card(env, cfg, card_spec, guild_id, channel_id, card_nonce)
        return 0
    client = ConsoleClient(cfg, env)
    try:
        discord_message_id = client.post_message(channel_id, text)
    except FMError as exc:
        print(f"fm-discord-conversation-console: {client.redact(str(exc))}", file=sys.stderr)
        return 1
    # The answer ends the turn, so the typing keeper for this conversation stops.
    stop_typing(env, channel_id)
    if args.request_id:
        update_latency(env, args.request_id, answered_at=time.time(), answer_message_id=discord_message_id)
    print(fwl.record_receipt(env, nonce, receipt, discord_message_id))
    print(f"replied in conversation {channel_id}")
    if card_spec is not None:
        post_reply_card(env, cfg, card_spec, guild_id, channel_id, card_nonce)
    return 0


def post_reply_card(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    spec: Dict[str, Any],
    guild_id: str,
    channel_id: str,
    nonce: str,
) -> None:
    """Post the card a console reply carries; a card failure never fails the reply.

    The phone-friendly reply text has already landed, so a refused or failed
    card is reported on stderr and the reply stands, exactly as a hold keeps its
    call when its card cannot be published.
    """
    try:
        card_id, card_message_id = post_card(env, cfg, spec, guild_id, channel_id, nonce)
    except FMError as exc:
        print(f"fm-discord-conversation-console: the reply card was not published: {exc}", file=sys.stderr)
        return
    if card_message_id:
        print(f"card posted in conversation {channel_id}: {card_id}")
    else:
        print(f"card exists for nonce {nonce}; no second delivery")


def cmd_mirror(args: argparse.Namespace, env: "fwl.Env") -> int:
    """Post one bounded mirrored dialog item into the configured #firstmate channel.

    The native Pi session mirror (``.pi/extensions/fm-discord-session-mirror.ts``)
    owns WHICH dialog is new - a durable cursor over the live session file - and
    this command owns the delivery: the existing console bot identity, the
    configured channel, and the shared nonce-keyed receipt.

    The nonce is derived from the caller's durable ``--item-key``, never from the
    text, so the same source position delivered twice converges on one receipt
    and no second post, while two identical lines from two positions still post
    twice. A restart, a replayed turn, and a cursor lost between the post and its
    cursor write therefore all deliver exactly once.
    """
    cfg = ConsoleConfig.load(env, args.config)
    if not cfg.mirror_enabled:
        raise FMError("the session mirror is disabled; enable mirror.enabled in the conversation console config")
    channel_id = fwl.validate_snowflake(args.channel, "--channel", required=False) or cfg.mirror_channel_id
    if not channel_id:
        raise FMError("no mirror channel is configured; set mirror.channel_id in the conversation console config")
    configured = cfg.channel_for_id(channel_id)
    if configured is None:
        raise FMError("--channel is not a configured #firstmate channel")
    if args.tag not in MIRROR_TAGS:
        raise FMError("--tag must be one of: %s" % ", ".join(MIRROR_TAGS))
    item_key = str(args.item_key or "").strip()
    if not MIRROR_ITEM_KEY_RE.fullmatch(item_key):
        raise FMError("--item-key must be a durable bounded item identity")
    # An empty or blank item is refused before any Discord call, so a partial or
    # empty turn can never reach the captain's channel.
    text = fwl.read_text_file(
        args.text_file, max_bytes=MAX_MIRROR_RAW_BYTES, max_chars=MAX_MIRROR_RAW_CHARS
    )
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    for marker in REFUSED_MARKERS:
        if marker in text:
            # A settled non-delivery, not a failure: the item is machinery or a
            # quotation of it, which is never mirrored, and the caller must move
            # past it rather than retry it forever.
            print(f"mirror skipped item {item_key}: operational text is never mirrored")
            return 0
    body = bound_mirror_text(f"[{args.tag}] {text}", cfg.mirror_max_chars)
    digest = fwl.sha256_text(body)
    nonce = f"mirror:{channel_id}:{item_key}"
    target = {"guild_id": configured.guild_id, "channel_id": channel_id}
    receipt = fwl.base_receipt("mirror", ADAPTER, target, digest)
    if args.dry_run:
        print("Discord session mirror plan (no network).")
        print(f"destination channel: {channel_id}")
        print(f"item: {item_key}")
        print(f"tag: {args.tag}")
        print(f"nonce: {nonce}")
        print(f"rendered item ({len(body)} chars, bound {cfg.mirror_max_chars}):")
        print(body)
        print("dry-run only; no Discord post was made.")
        return 0
    if not cfg.live_posting_enabled:
        raise FMError("live posting is disabled; enable live.posting in the conversation console config")
    existing = fwl.load_existing_json(fwl.receipt_path(env, nonce))
    if existing is not None:
        # The item identity is the durable key, so the recorded receipt is the
        # whole answer: a restart or a replay posts nothing twice.
        print(f"mirror exists for item {item_key}; no second post")
        return 0
    client = ConsoleClient(cfg, env)
    try:
        discord_message_id = client.post_message(channel_id, body)
    except FMError as exc:
        print(f"fm-discord-conversation-console: {client.redact(str(exc))}", file=sys.stderr)
        return 1
    print(fwl.record_receipt(env, nonce, receipt, discord_message_id))
    print(f"mirrored item {item_key} in conversation {channel_id} as message {discord_message_id}")
    return 0


def card_spec_with_overrides(raw: Dict[str, Any], args: argparse.Namespace) -> Dict[str, Any]:
    """Apply the caller's explicit task binding to a card file's definition.

    The command line's ``--task-id`` is authoritative for a task card: the hold
    wrapper passes the id of the call it is opening, so a reused card file can
    never bind a second call's card to the wrong held task. Body, labels, and
    values still come entirely from the file; only the binding is overridden.
    """
    override = str(getattr(args, "task_id", "") or "")
    if not override:
        return raw
    if not isinstance(raw, dict):
        raise FMError("the card file must be a JSON object")
    if str(raw.get("kind") or CARD_KIND_TASK) != CARD_KIND_TASK:
        return raw
    if not fwl.TASK_ID_RE.fullmatch(override):
        raise FMError("--task-id must be a privacy-safe task id")
    updated = dict(raw)
    updated["task_id"] = override
    return updated


def post_card(
    env: "fwl.Env",
    cfg: "ConsoleConfig",
    spec: Dict[str, Any],
    guild_id: str,
    channel_id: str,
    nonce: str,
) -> Tuple[str, str]:
    """Post one validated task card through the one guarded card path.

    Shared by the ``card`` command and by the card a console reply carries, so
    both use the same hold guard, the same one-open-card guard, the same
    nonce-keyed dedup identity, and the same store. Returns ``(card_id,
    message_id)``; an already-delivered card returns an empty ``message_id`` and
    posts nothing. Raises FMError for every refusal, so a caller that must not
    fail on a card (the reply path) can keep its reply and report the card
    failure separately.
    """
    card_id = card_id_for(nonce)
    content = render_card_content(spec)
    components = card_components(spec, card_id)
    existing = load_card(env, card_id)
    if isinstance(existing, dict) and existing.get("message_id"):
        return card_id, ""
    open_card = open_card_for_task(env, spec["task_id"])
    if isinstance(open_card, dict) and str(open_card.get("card_id") or "") != card_id:
        raise FMError(
            "an open card already exists for task %s (card %s); that card must be answered before a new one"
            % (spec["task_id"], open_card.get("card_id"))
        )
    if not cfg.live_posting_enabled:
        raise FMError("live posting is disabled; enable live.posting in the conversation console config")
    if not cfg.live_gateway_enabled:
        raise FMError("action cards need the permanent connection; enable live.gateway in the conversation console config")
    if not (env.state / "procevent" / f"{GATEWAY_SOURCE_ID}.source").is_file():
        raise FMError(
            "the permanent connection is not registered, so a posted card could never receive a press; run start first"
        )
    # First line of defence: a card is only posted while its task is still an
    # open captain call, so the recorded hold state - not the card's prose -
    # decides whether a press could ever validate.
    require_captain_held(env, spec["task_id"])
    client = ConsoleClient(cfg, env)
    try:
        message_id = client.post_message(channel_id, content, components)
    except FMError as exc:
        raise FMError(client.redact(str(exc))) from exc
    card = {
        "schema": CARD_SCHEMA,
        "kind": spec["kind"],
        "type": spec.get("type") or DEFAULT_CARD_TYPE,
        "card_id": card_id,
        "nonce": nonce,
        "task_id": spec["task_id"],
        "guild_id": guild_id,
        "channel_id": channel_id,
        "message_id": message_id,
        "body": spec["body"],
        "fallback_hint": spec["fallback_hint"],
        "options": spec["options"],
        "status": "open",
        "created_at": fwl.utc_now(),
    }
    store_card(env, card)
    return card_id, message_id


def cmd_card(args: argparse.Namespace, env: "fwl.Env") -> int:
    """Post one captain-facing card with labelled option buttons.

    The caller supplies the body and every option; the card path never invents an
    option from prose. The posted card's task id, interaction type, option set,
    and message id are stored durably so a later press can be resolved and shown
    on that message.
    """
    cfg = ConsoleConfig.load(env, args.config)
    guild_id, channel_id, _message_id = resolve_target(cfg, env, args.request_id, args.thread, args.channel)
    card_file = Path(args.card_file).expanduser()
    if not card_file.is_absolute():
        card_file = (Path.cwd() / card_file).resolve()
    spec = parse_card_spec(card_spec_with_overrides(fwl.read_json(card_file), args), cfg.reply_max_chars)
    if spec["kind"] != CARD_KIND_TASK:
        raise FMError(
            "the card command posts task cards; an uncertain-transcription confirmation card is "
            "posted by the console itself when the reading arrives"
        )
    nonce = args.nonce or (
        "card:%s:%s" % (spec["task_id"], fwl.sha256_text(json.dumps(spec, sort_keys=True))[:CARD_ID_HEX_CHARS])
    )
    card_id = card_id_for(nonce)
    content = render_card_content(spec)
    existing = load_card(env, card_id)
    if isinstance(existing, dict) and existing.get("message_id"):
        print(f"card exists for nonce {nonce}; no second delivery")
        return 0
    open_card = open_card_for_task(env, spec["task_id"])
    if isinstance(open_card, dict) and str(open_card.get("card_id") or "") != card_id:
        raise FMError(
            "an open card already exists for task %s (card %s); that card must be answered before a new one"
            % (spec["task_id"], open_card.get("card_id"))
        )
    if args.dry_run:
        print("Discord action card plan (no network).")
        print(f"destination conversation: {channel_id}")
        print(f"card id: {card_id}")
        print(f"task: {spec['task_id']}")
        print(f"interaction type: {spec.get('type') or DEFAULT_CARD_TYPE}")
        print(f"nonce: {nonce}")
        print(f"live posting: {'on' if cfg.live_posting_enabled else 'off'}")
        print(f"permanent connection: {'on' if cfg.live_gateway_enabled else 'off'}")
        print(f"options: {len(spec['options'])}")
        for index, option in enumerate(spec["options"]):
            detail = option.get("value") or option.get("until") or ""
            print(f"  [{index}] {option['label']} -> {option['action']}" + (f" ({detail})" if detail else ""))
        print(f"rendered card ({len(content)} chars):")
        print(content)
        print("dry-run only; no Discord post was made.")
        return 0
    try:
        _card_id, message_id = post_card(env, cfg, spec, guild_id, channel_id, nonce)
    except FMError as exc:
        print(f"fm-discord-conversation-console: {exc}", file=sys.stderr)
        return 1
    print(f"card posted in conversation {channel_id}: {card_id}")
    print(f"card url: https://discord.com/channels/{guild_id}/{channel_id}/{message_id}")
    return 0


def cmd_card_escalations(args: argparse.Namespace, env: "fwl.Env") -> int:
    """Run one bounded escalation pass over open, unanswered held cards.

    Each card past the configured delay whose task is still held is mirrored
    once into the dedicated #blocages channel with the same card identity;
    answered, closed, already-escalated, and too-young cards get none, and a
    failed attempt is recorded as a visible delivery gap.
    """
    cfg = ConsoleConfig.load(env, args.config)
    if args.dry_run:
        delay = cfg.card_escalation_delay_seconds
        print("card escalation plan (no network).")
        for card in load_cards(env):
            if str(card.get("kind") or CARD_KIND_TASK) != CARD_KIND_TASK:
                continue
            if str(card.get("status") or "open") != "open":
                continue
            created = parse_discord_epoch(None, card.get("created_at"))
            eligible = (
                not isinstance(card.get("escalation"), dict)
                and created is not None
                and time.time() - created >= delay
            )
            print(
                "  card %s task %s age%s: %s"
                % (
                    card.get("card_id"),
                    card.get("task_id"),
                    "" if created is None else " %ds" % int(time.time() - created),
                    "eligible" if eligible else "not eligible",
                )
            )
        return 0
    stats = run_card_escalations(env, cfg, ConsoleClient(cfg, env))
    print(
        "card escalations: scanned=%(scanned)s escalated=%(escalated)s failed=%(failed)s skipped=%(skipped)s"
        % stats
    )
    return 0


def cmd_typing(args: argparse.Namespace, env: "fwl.Env") -> int:
    """Hold (or stop) the bounded typing indicator for one conversation.

    With ``--stop`` it only removes the marker and makes no network call. Without
    it, the keeper emits the typing indicator immediately and then every
    interval until the marker is removed or its hard deadline passes, so the
    loop is always bounded.
    """
    cfg = ConsoleConfig.load(env, args.config)
    channel_id = str(args.channel or "")
    if not channel_id.isdigit():
        raise FMError("typing requires a numeric --channel Discord channel id")
    if args.stop:
        removed = stop_typing(env, channel_id)
        print(f"typing {'stopped' if removed else 'already stopped'} for {channel_id}")
        return 0
    if not cfg.live_posting_enabled or not cfg.fast_path_typing_enabled:
        return 0
    interval = args.interval if args.interval is not None else cfg.fast_path_typing_interval
    max_seconds = args.max_seconds if args.max_seconds is not None else cfg.fast_path_typing_max_seconds
    interval = max(MIN_TYPING_INTERVAL_SECONDS, min(float(interval), MAX_TYPING_INTERVAL_SECONDS))
    max_seconds = max(MIN_TYPING_MAX_SECONDS, min(float(max_seconds), MAX_TYPING_MAX_SECONDS))
    client = ConsoleClient(cfg, env)
    own_pid = os.getpid()
    deadline = time.monotonic() + max_seconds
    while True:
        record = read_typing_record(env, channel_id)
        if record is None:
            return 0
        pid = record.get("pid")
        if isinstance(pid, int) and pid not in (0, own_pid):
            # Another keeper already owns this channel; never duplicate it.
            return 0
        expires_at = record.get("expires_at")
        if isinstance(expires_at, (int, float)) and time.time() >= expires_at:
            stop_typing(env, channel_id)
            return 0
        record["schema"] = TYPING_SCHEMA
        record["pid"] = own_pid
        record["updated_at"] = fwl.utc_now()
        try:
            with fwl.state_transaction(env):
                fwl.atomic_json(typing_path(env, channel_id), record)
        except FMError:
            return 0
        try:
            client.typing(channel_id)
        except FMError:
            pass
        if time.monotonic() >= deadline:
            stop_typing(env, channel_id)
            return 0
        time.sleep(interval)


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
    print(f"fast path: {'on' if cfg.fast_path_enabled else 'off'}")
    if cfg.fast_path_enabled:
        print(f"fast-path acknowledgement: {'on' if cfg.fast_path_ack_enabled else 'off'}")
        print(f"fast-path typing: {'on' if cfg.fast_path_typing_enabled else 'off'}")
    print(f"audio transcription: {'on' if cfg.transcription_enabled else 'off'}")
    if cfg.transcription_enabled:
        counts = transcript_counts(env)
        print(f"transcripts recorded: {counts['ok']} ok, {counts['failed']} failed")
        print(f"transcription model: {cfg.transcription_model} ({cfg.transcription_language})")
        print(f"transcription confidence check: {'on' if cfg.transcription_confidence_check else 'off'}")
        print(f"transcription confirmation card: {'on' if cfg.transcription_confirm_card else 'off'}")
    print(f"request preparation: {'on' if cfg.prepare_enabled else 'off'}")
    print(f"session mirror: {'on' if cfg.mirror_enabled else 'off'}")
    if cfg.mirror_channel_id:
        mirror_channel = cfg.channel_for_id(cfg.mirror_channel_id)
        print(
            "mirror channel: %s (%s)"
            % (cfg.mirror_channel_id, mirror_channel.label if mirror_channel else "not a configured channel")
        )
    print(f"mirror bound: {cfg.mirror_max_chars} chars")
    cursor = read_mirror_cursor(env)
    if cursor and cursor.get("file"):
        print(f"mirror cursor: {cursor.get('file')} at entry {cursor.get('index')}")
        if cursor.get("recorded_at"):
            print(f"mirror cursor recorded: {cursor.get('recorded_at')}")
    else:
        print("mirror cursor: none recorded")
    if cfg.prepare_enabled:
        prepared = prepare_counts(env)
        print(f"packets prepared: {prepared['prepared']}")
        print(f"packets skipped: {prepared['fallback']}")
        last_prepared = prepared.get("last") if isinstance(prepared.get("last"), dict) else {}
        if last_prepared.get("status"):
            print(
                "prepare last: %s (%s)"
                % (last_prepared.get("status"), str(last_prepared.get("reason") or "")[:160])
            )
        else:
            print("prepare last: none")
    fast_counts = fast_path_counts(env)
    print(f"fast-path acks: {fast_counts['acks']}")
    print(f"fast-path audited messages: {fast_counts['audits']}")
    typing_dir = console_state_path(env, "typing")
    typing_count = sum(1 for _ in typing_dir.glob("*.json")) if typing_dir.is_dir() else 0
    print(f"typing keepers active: {typing_count}")
    cards: List[Dict[str, Any]] = []
    try:
        cards = load_cards(env)
    except FMError:
        health = "state-malformed"
    open_cards = [record for record in cards if str(record.get("status") or "open") == "open"]
    interaction_dir = console_state_path(env, "cards", "interactions")
    interaction_count = sum(1 for _ in interaction_dir.glob("*.json")) if interaction_dir.is_dir() else 0
    print(f"cards posted: {len(cards)}")
    print(f"cards open: {len(open_cards)}")
    transcript_cards = [record for record in cards if str(record.get("kind") or CARD_KIND_TASK) == CARD_KIND_TRANSCRIPT]
    print(f"transcript confirmation cards: {len(transcript_cards)} posted, {len([record for record in transcript_cards if str(record.get('status') or 'open') == 'open'])} open")
    print(f"card interactions recorded: {interaction_count}")
    last_audit = fast_counts.get("last") or {}
    if isinstance(last_audit, dict) and last_audit.get("path"):
        verdict = last_audit.get("verdict") if isinstance(last_audit.get("verdict"), dict) else {}
        print(
            "fast-path last route: %s (verdict %s, confidence %s)"
            % (last_audit.get("path"), verdict.get("verdict") or "?", verdict.get("confidence"))
        )
    else:
        print("fast-path last route: none")
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
    transports = latency_transport_counts(env)
    recent_rows = latency_rows(env, DEFAULT_LATENCY_REPORT_ROWS)
    medians = latency_medians(recent_rows)
    gaps = delivery_gap_counts(env)
    print(f"latency tracked: {sum(transports.values())}")
    print("latency medians: " + " ".join(f"{key}={_stage_text(medians[key])}" for key in sorted(medians)))
    if recent_rows:
        last = recent_rows[0]
        print(
            f"latency last: {last['message_id'] or last['request_id']} transport={last['transport'] or '?'} "
            f"stage3(wake)={_stage_text(last['stage3_wake'])} total={_stage_text(last['total'])}"
        )
    else:
        print("latency last: none")
    print(f"deliveries by transport: {json.dumps(transports, sort_keys=True)}")
    print(
        f"delivery gaps: {gaps['count']} (polling-capture={gaps['polling-capture']} "
        f"gateway-fallback={gaps['gateway-fallback']})"
    )
    if gaps.get("last"):
        print(f"delivery gap last: {gaps['last'].get('at')} {gaps['last'].get('kind')} {gaps['last'].get('detail')}")
    if cfg.live_gateway_enabled and not transports.get("gateway"):
        print("gateway proof: no gateway-tagged capture is recorded yet")
    return 0


def _stage_text(value: Any) -> str:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return "-"
    return f"{float(value):.3f}s"


def cmd_latency(args: argparse.Namespace, env: "fwl.Env") -> int:
    """Side-effect-free per-stage latency report, safe to run in a loop."""
    rows = latency_rows(env, args.limit)
    medians = latency_medians(rows)
    gaps = delivery_gap_counts(env)
    if args.json:
        print(json.dumps({"rows": rows, "medians": medians, "delivery_gaps": gaps}, indent=2, sort_keys=True))
        return 0
    print("discord conversation console latency")
    print("stage1=discord->console stage2=console stage3=wake stage4=session-activation stage5=turn")
    if not rows:
        print("no tracked captain messages yet")
    for row in rows:
        print(
            f"{row['request_id'] or row['message_id']}: transport={row['transport'] or '?'} path={row['path'] or '?'} "
            f"s1={_stage_text(row['stage1_discord_to_console'])} s2={_stage_text(row['stage2_console_handling'])} "
            f"s3={_stage_text(row['stage3_wake'])} s4={_stage_text(row['stage4_session_activation'])} "
            f"s5={_stage_text(row['stage5_turn'])} total={_stage_text(row['total'])} "
            f"prepare={row['prepare_status'] or 'off'}"
        )
    print("medians: " + " ".join(f"{key}={_stage_text(medians[key])}" for key in sorted(medians)))
    print(f"transports: {json.dumps(latency_transport_counts(env), sort_keys=True)}")
    print(
        f"delivery gaps: {gaps['count']} (polling-capture={gaps['polling-capture']} "
        f"gateway-fallback={gaps['gateway-fallback']})"
    )
    if gaps.get("last"):
        print(f"delivery gap last: {gaps['last'].get('at')} {gaps['last'].get('kind')} {gaps['last'].get('detail')}")
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
    p.add_argument("--card-file")
    p.add_argument("--task-id")
    p.add_argument("--nonce")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_reply)
    p = sub.add_parser("mirror")
    add_config_argument(p)
    p.add_argument("--text-file", required=True)
    p.add_argument("--item-key", required=True)
    p.add_argument("--tag", default="captain")
    p.add_argument("--channel")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_mirror)
    p = sub.add_parser("card")
    add_config_argument(p)
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--request-id")
    target.add_argument("--thread")
    target.add_argument("--channel")
    p.add_argument("--card-file", required=True)
    p.add_argument("--task-id")
    p.add_argument("--nonce")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_card)
    p = sub.add_parser("card-escalate")
    add_config_argument(p)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_card_escalations)
    p = sub.add_parser("typing")
    add_config_argument(p)
    p.add_argument("--channel", required=True)
    p.add_argument("--stop", action="store_true")
    p.add_argument("--interval", type=float)
    p.add_argument("--max-seconds", type=float)
    p.set_defaults(func=cmd_typing)
    p = sub.add_parser("status")
    add_config_argument(p)
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("latency")
    add_config_argument(p)
    p.add_argument("--limit", type=int, default=DEFAULT_LATENCY_REPORT_ROWS)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_latency)
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
