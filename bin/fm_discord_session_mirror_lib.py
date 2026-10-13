#!/usr/bin/env python3
"""Firstmate-side Discord session mirror for the per-project server structure.

This module owns the Firstmate half of the project Discord structure: one
forum thread per live Firstmate session inside the sessions forum of the
project that session belongs to, one tagged artifact thread per durable
deliverable, and the intake that turns a captain-created thread (or an
explicit plain-language request) into a session bound to that thread.

It reuses, and never reimplements:
  * bin/fm_discord_workspace_lib.py for config shape, state safety, atomic
    JSON, locks, receipts, and bounded text reads;
  * bin/fm_discord_live.py for the Discord client, token decryption, retries,
    and token redaction;
  * bin/fm-crew-state.sh for the reconciled current state of a task.

The mirror follows reconciliation, never the append-only status log: every
state tag and card comes from bin/fm-crew-state.sh. Posting is idempotent by a
durable per-task session record plus a deterministic thread name lookup, so a
restart never replays what a previous pass already posted, and no pass ever
creates a second thread for one task.

Project-to-forum mapping, tag vocabulary, and the reconciled-state-to-tag table
live in the non-secret config file, never in this code.

Usage (via bin/fm-discord-session-mirror.sh):
    sample-config
    config-check [--config <json>]
    report [--config <json>] [--task <id>]...
    sync [--config <json>] [--task <id>]... [--dry-run]
    artifact [--config <json>] --task <id> --kind <report|patch|pr|livrable|rapport|lien|test> --title <t> --body-file <f> [--dry-run]
    request [--config <json>] --thread <id> [--text-file <f>] [--dry-run]
    bind [--config <json>] --thread <id> --task <id> [--dry-run]

Test seams: FM_DISCORD_MIRROR_STATE_CMD overrides the reconciled-state command
and FM_DISCORD_MIRROR_TREEHOUSE_ROOT overrides the treehouse pool root used to
derive a worktree name. Neither changes what is posted or how it is deduplicated.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent


def _load_module(name: str, filename: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fwl = _load_module("fwl", "fm_discord_workspace_lib.py")
fdl = _load_module("fdl", "fm_discord_live.py")

FMError = fwl.FMError
# The live layer loads its own copy of the workspace library, so its error
# class object is not identical to this module's even though both mean the same
# thing. Catch both, plus OSError, so a live or filesystem refusal prints one
# bounded line, never a traceback.
ERRTYPES = (FMError, fdl.FMError, OSError)
Env = fwl.Env
die = fwl.die

CONFIG_SCHEMA = "fm-discord-session-mirror.config.v1"
SESSION_SCHEMA = "fm-discord-session-mirror.session.v1"
REQUEST_SCHEMA = "fm-discord-session-mirror.request.v1"
ARTIFACT_SCHEMA = "fm-discord-session-mirror.artifact.v1"
ENSURE_SCHEMA = "fm-discord-session-mirror.ensure.v1"
REFUSED_GUILDS_KEY = "refused_guild_ids"

PROJECT_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
STATE_LINE_RE = re.compile(r"^state:\s*([a-z]+)\b")
TOKEN_LIKE_RE = re.compile(r"[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{20,}")
OPERATIONAL_MARKERS = ("FIRSTMATE WATCHER WAKE", "FIRSTMATE_OP:", "\u2063", "\u26f5")

# Reconciled firstmate state -> the single Discord forum tag it carries.
DEFAULT_STATE_TAGS = {
    "working": "actif",
    "parked": "en-attente",
    "paused": "en-attente",
    "blocked": "bloque",
    "failed": "bloque",
    "done": "termine",
    "unknown": "en-attente",
}
REQUIRED_STATE_KEYS = tuple(DEFAULT_STATE_TAGS)
DEFAULT_SESSION_TAG = "session"
DEFAULT_WORKTREE_TAG = "worktree"
# The configured artifact vocabulary is the captain's, not the code's: the
# English kind names stay accepted for existing configs, and the French
# livrable / rapport / lien / test names are accepted alongside them.
ARTIFACT_KINDS = ("report", "patch", "pr", "livrable", "rapport", "lien", "test")
DEFAULT_WEBHOOK_FILE = "config/discord-webhooks.json"
TRANSPORT_CHOICES = ("auto", "webhook", "bot")
WEBHOOK_KINDS = ("sessions", "artifacts", "emails")
WEBHOOK_URL_RE = re.compile(
    r"^https://(?:canary\.|ptb\.)?discord(?:app)?\.com/api/(?:v[0-9]+/)?webhooks/([0-9]{5,32})/([A-Za-z0-9_.\-]{20,200})$"
)
# Discord's hard per-forum cap on available_tags; a forum that would exceed it
# is refused rather than silently trimmed.
TAG_CAP = 20
# A forum channel is the only channel kind that carries available_tags.
FORUM_TYPES = (15, 16)
WEBHOOK_MAX_RETRIES = 3
WEBHOOK_API_BASE = "https://discord.com/api/v10"
WEBHOOK_NAME_LIMIT = 80
DEFAULT_WEBHOOK_NAME_PREFIX = "firstmate"
WEBHOOK_USER_AGENT = "firstmate-discord-session-mirror (bounded webhook transport, +https://localhost)"
USERNAME_LIMIT = 80
# Discord rejects a webhook username containing either of these words, whatever
# the case; a task id or project label commonly contains "discord".
USERNAME_FORBIDDEN_WORDS = ("discord", "clyde")

TITLE_LIMIT = 100
BODY_LIMIT = 2000
# Discord's own limit for one message's content. The artifact post composes its
# body with the title, and the session card composes several fields, so bounding
# any one input alone still lets the composed content fail live.
MESSAGE_LIMIT = 2000
CREW_STATE_TIMEOUT = 25
MAX_TASKS_DEFAULT = 25
MAX_BOUND_DEFAULT = 200
CARD_FOOTER = "_Session suivie par Firstmate ; les modifications d'etat restent dans ce meme fil._"

STATE_ROOT_PARTS = ("session-mirror",)


def mirror_state_path(env: Env, *parts: str) -> Path:
    return fwl.discord_state_path(env, *STATE_ROOT_PARTS, *parts)


def utc_now() -> str:
    return fwl.utc_now()


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------


def bounded_text(value: Any, field: str, limit: int, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise FMError(f"{field} must be a string")
    text = value.strip()
    if not text and not allow_empty:
        raise FMError(f"{field} must not be empty")
    if len(text) > limit:
        raise FMError(f"{field} must be at most {limit} characters")
    if any(ord(character) < 32 and character not in ("\n", "\t") for character in text):
        raise FMError(f"{field} contains an unsupported control character")
    return text


def validate_tag_name(value: Any, field: str) -> str:
    if not isinstance(value, str) or not fwl.TAG_RE.fullmatch(value):
        raise FMError(f"{field} must be a Discord forum tag name")
    return value


def validate_artifact_tag(value: Any, field: str) -> str:
    """A configured artifact tag is either a forum tag name or its numeric id.

    A webhook cannot read a forum's tag vocabulary, so the captain may put the
    tag id directly in artifact_tags; a member-bot config may keep the name.
    """
    if isinstance(value, str) and (fwl.TAG_RE.fullmatch(value) or fwl.ID_RE.fullmatch(value)):
        return value
    raise FMError(f"{field} must be a Discord forum tag name or numeric tag id")


def validate_state_tag_map(raw: Any) -> Dict[str, str]:
    if raw is None:
        return dict(DEFAULT_STATE_TAGS)
    if not isinstance(raw, dict):
        raise FMError("state_tags must be a JSON object")
    out: Dict[str, str] = {}
    for key in REQUIRED_STATE_KEYS:
        if key not in raw:
            raise FMError(f"state_tags must map every reconciled state; missing {key}")
        out[key] = validate_tag_name(raw[key], f"state_tags.{key}")
    for key in raw:
        if key not in REQUIRED_STATE_KEYS:
            raise FMError(f"state_tags has an unsupported state key: {key}")
    return out


def validate_positive_int(value: Any, field: str, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise FMError(f"{field} must be a positive JSON integer")
    if value > maximum:
        raise FMError(f"{field} must be no more than {maximum}")
    return value


def validate_transport(value: Any, field: str) -> str:
    """auto prefers a configured webhook, webhook requires one, bot forces membership."""
    if value is None:
        return "auto"
    if not isinstance(value, str) or value not in TRANSPORT_CHOICES:
        raise FMError(f"{field} must be one of {', '.join(TRANSPORT_CHOICES)}")
    return value


def validate_config_file_reference(value: Any, field: str, home: Path) -> str:
    """A non-secret JSON config reference under the home's config directory."""
    if not isinstance(value, str):
        raise FMError(f"{field} must be a normalized JSON file reference under config/")
    parts = value.split("/")
    if (
        Path(value).is_absolute()
        or len(parts) < 2
        or parts[0] != "config"
        or any(part in ("", ".", "..") for part in parts)
        or not value.endswith(".json")
    ):
        raise FMError(f"{field} must be a normalized .json file reference under config/")
    candidate = (home / value).resolve()
    config_root = (home / "config").resolve()
    try:
        candidate.relative_to(config_root)
    except ValueError as exc:
        raise FMError(f"{field} must not escape the config directory through symlinks") from exc
    return value


def validate_refused_guilds(raw: Any) -> Dict[str, str]:
    """Guilds this capability must never touch, each with the recorded reason.

    The refusal is configuration, not a code constant, so no captain-private
    guild id is committed to a public repository; it is enforced at config load,
    so a later project entry that points at a refused guild cannot quietly
    reverse it - every command stops instead.
    """
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise FMError(f"{REFUSED_GUILDS_KEY} must be a JSON object mapping a guild id to its refusal reason")
    out: Dict[str, str] = {}
    for guild_id, reason in raw.items():
        sid = fwl.validate_snowflake(guild_id, f"{REFUSED_GUILDS_KEY} key")
        assert sid is not None
        out[sid] = bounded_text(reason, f"{REFUSED_GUILDS_KEY}.{sid}", 200)
    return out


class MirrorProject:
    def __init__(self, key: str, raw: Dict[str, Any], seen_ids: Dict[str, str], raw_key: str = "") -> None:
        self.key = key
        self.raw_key = raw_key or key
        prefix = f"projects.{key}"
        if not isinstance(raw, dict):
            raise FMError(f"{prefix} must be a JSON object")
        self.label = bounded_text(raw.get("label"), f"{prefix}.label", 60)
        self.guild_id = fwl.validate_snowflake(raw.get("guild_id"), f"{prefix}.guild_id") or ""
        self.sessions_forum_id = fwl.validate_snowflake(raw.get("sessions_forum_id"), f"{prefix}.sessions_forum_id") or ""
        self.artifact_forum_id = fwl.validate_snowflake(
            raw.get("artifact_forum_id"), f"{prefix}.artifact_forum_id", required=False
        ) or ""
        for field_name, sid in (("sessions_forum_id", self.sessions_forum_id), ("artifact_forum_id", self.artifact_forum_id)):
            if not sid:
                continue
            owner = seen_ids.get(sid)
            if owner:
                raise FMError(f"duplicate Discord forum id {sid} appears in {owner} and {prefix}.{field_name}")
            seen_ids[sid] = f"{prefix}.{field_name}"
        raw_tags = raw.get("artifact_tags")
        self.artifact_tags: Dict[str, str] = {}
        if raw_tags is not None:
            if not isinstance(raw_tags, dict):
                raise FMError(f"{prefix}.artifact_tags must be a JSON object")
            for kind in raw_tags:
                if kind not in ARTIFACT_KINDS:
                    raise FMError(
                        f"{prefix}.artifact_tags has an unsupported kind: {kind} (allowed: {', '.join(ARTIFACT_KINDS)})"
                    )
            for kind, tag in raw_tags.items():
                self.artifact_tags[kind] = validate_artifact_tag(tag, f"{prefix}.artifact_tags.{kind}")
        raw_paths = raw.get("paths")
        if not isinstance(raw_paths, list) or not raw_paths:
            raise FMError(f"{prefix}.paths must be a non-empty list of absolute project paths")
        self.paths: List[str] = []
        for index, value in enumerate(raw_paths):
            label = f"{prefix}.paths[{index}]"
            if not isinstance(value, str) or not value.strip():
                raise FMError(f"{label} must be a non-empty JSON string")
            expanded = Path(value).expanduser()
            if not expanded.is_absolute() or any(part in (".", "..") for part in expanded.parts):
                raise FMError(f"{label} must be an absolute path without dot components")
            self.paths.append(os.path.realpath(str(expanded)))
        self.transport = validate_transport(raw.get("transport"), f"{prefix}.transport")
        raw_tag_ids = raw.get("tag_ids")
        self.tag_ids: Dict[str, str] = {}
        if raw_tag_ids is not None:
            if not isinstance(raw_tag_ids, dict):
                raise FMError(f"{prefix}.tag_ids must be a JSON object mapping a forum tag name to its id")
            for name, value in raw_tag_ids.items():
                tag_name = validate_tag_name(name, f"{prefix}.tag_ids key")
                sid = fwl.validate_snowflake(value, f"{prefix}.tag_ids.{name}")
                assert sid is not None
                self.tag_ids[tag_name] = sid

    def artifact_tag_for(self, kind: str) -> Optional[str]:
        return self.artifact_tags.get(kind)


class MirrorConfig:
    def __init__(self, path: Path, raw: Dict[str, Any], home: Path) -> None:
        self.path = path
        self.raw = raw
        if not isinstance(raw, dict):
            raise FMError("config root must be a JSON object")
        fwl.reject_inline_secret_values(raw)
        schema = raw.get("schema", CONFIG_SCHEMA)
        if schema != CONFIG_SCHEMA:
            raise FMError(f"unsupported config schema: {schema}")
        secret_file = raw.get("secret_file", "config/discord-workspace.secrets.sops.yaml")
        fwl.validate_secret_file_reference(secret_file, "secret_file", home)
        self.secret_file = secret_file
        token_key = raw.get("discord_bot_token_key", "FIRSTMATE_DISCORD_BOT_TOKEN")
        if not isinstance(token_key, str) or not fwl.SECRET_REFERENCE_RE.fullmatch(token_key):
            raise FMError("discord_bot_token_key must be an uppercase secret reference name")
        self.token_key = token_key
        self.captain_user_ids: List[str] = []
        for user_id in fwl.as_list(raw.get("captain_user_ids"), "captain_user_ids"):
            sid = fwl.validate_snowflake(user_id, "captain_user_ids[]")
            assert sid is not None
            if sid in self.captain_user_ids:
                raise FMError(f"captain_user_ids has duplicate id: {sid}")
            self.captain_user_ids.append(sid)
        if not self.captain_user_ids:
            raise FMError("captain_user_ids must contain at least one captain Discord user id")
        self.live_posting = fwl.bool_from_path(raw, ["live.posting"], False)
        # A webhook cannot read a forum's tag vocabulary, so tag ids come from
        # config. With this opt-in the mirror still publishes the session thread
        # when they are unconfigured, and says so, instead of leaving the session
        # invisible; without it an unconfigured tag vocabulary blocks the post.
        self.allow_untagged = fwl.bool_from_path(raw, ["allow_untagged"], False)
        # auto prefers a configured webhook for the target forum, webhook
        # requires one, and bot forces the member-bot transport - the only one
        # that can read a channel or change an existing thread's tags.
        self.transport = validate_transport(raw.get("transport"), "transport")
        self.state_tags = validate_state_tag_map(raw.get("state_tags"))
        self.session_tag = validate_tag_name(raw.get("session_tag", DEFAULT_SESSION_TAG), "session_tag")
        self.worktree_tag = validate_tag_name(raw.get("worktree_tag", DEFAULT_WORKTREE_TAG), "worktree_tag")
        bounds = raw.get("bounds", {})
        if not isinstance(bounds, dict):
            raise FMError("bounds must be a JSON object")
        self.max_tasks_per_pass = validate_positive_int(bounds.get("max_tasks_per_pass", MAX_TASKS_DEFAULT), "bounds.max_tasks_per_pass", 500)
        self.max_thread_listing = validate_positive_int(bounds.get("max_thread_listing", MAX_BOUND_DEFAULT), "bounds.max_thread_listing", 1000)
        self.webhook_file = validate_config_file_reference(
            raw.get("webhook_file", DEFAULT_WEBHOOK_FILE), "webhook_file", home
        )
        self.refused_guilds = validate_refused_guilds(raw.get(REFUSED_GUILDS_KEY))
        projects = raw.get("projects")
        if not isinstance(projects, dict) or not projects:
            raise FMError("projects must be a non-empty JSON object mapping a project key to its Discord forums")
        seen_ids: Dict[str, str] = {}
        self.projects: Dict[str, MirrorProject] = {}
        for key, value in projects.items():
            normalized = str(key).strip().lower()
            if not PROJECT_KEY_RE.fullmatch(normalized):
                raise FMError(f"projects key {key!r} must be a lowercase project identifier")
            if normalized in self.projects:
                raise FMError(f"projects has duplicate normalized key: {normalized}")
            self.projects[normalized] = MirrorProject(normalized, value, seen_ids, str(key))
        for key in sorted(self.projects):
            project = self.projects[key]
            reason = self.refused_guilds.get(project.guild_id)
            if reason:
                raise FMError(
                    f"projects.{key}.guild_id {project.guild_id} is a refused guild ({reason}); "
                    "this capability never reads or writes it"
                )

    def project_for_path(self, path_text: str) -> Optional[MirrorProject]:
        candidate = os.path.realpath(str(Path(path_text).expanduser()))
        best: Optional[MirrorProject] = None
        best_length = -1
        for project in self.projects.values():
            for root in project.paths:
                if candidate == root or candidate.startswith(root.rstrip("/") + "/"):
                    if len(root) > best_length:
                        best_length = len(root)
                        best = project
        return best

    def project_for_sessions_forum(self, forum_id: str) -> Optional[MirrorProject]:
        for project in self.projects.values():
            if project.sessions_forum_id == forum_id:
                return project
        return None

    def project_for_any_forum(self, forum_id: str) -> Optional[Tuple[MirrorProject, str]]:
        for project in self.projects.values():
            if project.sessions_forum_id == forum_id:
                return project, "sessions"
            if project.artifact_forum_id and project.artifact_forum_id == forum_id:
                return project, "artifacts"
        return None

    def project_by_key(self, key: str) -> MirrorProject:
        normalized = key.strip().lower()
        project = self.projects.get(normalized)
        if project is None:
            raise FMError(f"unknown project key {key!r}; configured projects: {', '.join(sorted(self.projects))}")
        return project


def sample_config() -> Dict[str, Any]:
    return {
        "schema": CONFIG_SCHEMA,
        "secret_file": "config/discord-workspace.secrets.sops.yaml",
        "discord_bot_token_key": "FIRSTMATE_DISCORD_BOT_TOKEN",
        "captain_user_ids": ["000000000000000001"],
        "live": {"posting": False},
        "allow_untagged": False,
        "transport": "auto",
        REFUSED_GUILDS_KEY: {},
        "webhook_file": DEFAULT_WEBHOOK_FILE,
        "session_tag": DEFAULT_SESSION_TAG,
        "worktree_tag": DEFAULT_WORKTREE_TAG,
        "state_tags": dict(DEFAULT_STATE_TAGS),
        "bounds": {"max_tasks_per_pass": MAX_TASKS_DEFAULT, "max_thread_listing": MAX_BOUND_DEFAULT},
        "projects": {
            "example-project": {
                "label": "Example project",
                "guild_id": "000000000000000001",
                "sessions_forum_id": "000000000000000002",
                "artifact_forum_id": "000000000000000003",
                "artifact_tags": {"report": "rapport", "patch": "patch", "pr": "pr"},
                "transport": "auto",
                "tag_ids": {
                    "session": "000000000000000010",
                    "worktree": "000000000000000011",
                    "actif": "000000000000000012",
                    "en-attente": "000000000000000013",
                    "bloque": "000000000000000014",
                    "termine": "000000000000000015",
                },
                "paths": ["/absolute/path/to/example-project"],
            }
        },
    }


def load_config(env: Env, path_text: Optional[str]) -> MirrorConfig:
    path = Path(path_text).expanduser() if path_text else env.config / "discord-session-mirror.json"
    if path.is_symlink() or not path.is_file():
        raise FMError(f"config file is missing: {path}")
    return MirrorConfig(path, fwl.read_json(path), env.home)


# --------------------------------------------------------------------------
# presentation helpers
# --------------------------------------------------------------------------


def truncate(text: str, limit: int) -> str:
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text
    if limit == 1:
        return text[:1]
    return text[: limit - 1] + "\u2026"


def render_thread_title(label: str, task_id: str, worktree: str) -> str:
    """Deterministic forum thread name: '<project> - <task> - <worktree-name>'."""
    separators = len(" - ") * 2
    task = truncate(task_id, max(TITLE_LIMIT - separators - 8, 16))
    budget = TITLE_LIMIT - separators - len(task)
    if budget < 8:
        return truncate(f"{label} - {task} - {worktree}", TITLE_LIMIT)
    half = budget // 2
    label_part = truncate(label, half)
    worktree_part = truncate(worktree, budget - len(label_part))
    title = f"{label_part} - {task} - {worktree_part}"
    return truncate(title, TITLE_LIMIT)


def worktree_name(worktree_text: str) -> str:
    """Readable, stable worktree identity for the thread title and card.

    A pooled treehouse worktree under `<pool>/<project>-<hash>/<slot>/<repo>`
    reads as `<project>-<slot>` (for example `atelier-24`); anything else falls
    back to the worktree directory name.
    """
    real = Path(worktree_text).expanduser().resolve()
    root = os.environ.get("FM_DISCORD_MIRROR_TREEHOUSE_ROOT") or str(Path.home() / ".treehouse")
    treehouse = Path(root).expanduser().resolve()
    try:
        relative = real.relative_to(treehouse)
    except ValueError:
        relative = None
    if relative is not None and len(relative.parts) >= 2:
        pool = relative.parts[0]
        slot = relative.parts[1]
        repo = relative.parts[-1]
        stem = re.sub(r"-[0-9a-f]{6,}$", "", pool) or repo
        return f"{stem}-{slot}"
    return real.name


def worktree_branch(worktree_path: str) -> str:
    real = Path(worktree_path).expanduser()
    if not real.is_dir():
        return ""
    try:
        proc = subprocess.run(
            ["git", "-C", str(real), "rev-parse", "--abbrev-ref", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if proc.returncode != 0:
        return ""
    branch = proc.stdout.strip()
    if not branch or branch == "HEAD" or len(branch) > 80:
        return ""
    if any(ord(character) < 32 for character in branch):
        return ""
    return branch


def render_card(project: MirrorProject, task_id: str, worktree: str, branch: str, state: str) -> str:
    lines = [
        f"**Projet :** {project.label}",
        f"**Session :** {task_id}",
        f"**Worktree :** {worktree}",
    ]
    if branch:
        lines.append(f"**Branche :** {branch}")
    lines.append(f"**Etat :** {state}")
    lines.append(CARD_FOOTER)
    return bounded_post_content("\n".join(lines), "the session card")


def session_identity(project: MirrorProject, worktree: str) -> str:
    """The readable speaker label the captain sees in a session thread.

    A webhook username is a Discord-validated field: it may not contain
    `discord` or `clyde`, and a task id or project label commonly does. The
    forbidden word is dropped and the seam it leaves is closed, so the post
    still carries a readable identity instead of being refused outright.
    """
    label = f"{project.label} - {worktree}"
    for word in USERNAME_FORBIDDEN_WORDS:
        label = re.sub(word, "", label, flags=re.IGNORECASE)
    label = re.sub(r"-{2,}", "-", label)
    label = re.sub(r"(?:\s*-\s*){2,}", " - ", label)
    label = re.sub(r"[ \t]{2,}", " ", label).strip(" -")
    return truncate(label, USERNAME_LIMIT) or "Firstmate"


def bounded_post_content(content: str, field: str) -> str:
    """The one bound every posted Discord content string passes through.

    Discord rejects a message whose content exceeds its own 2000-character
    limit, and the callers compose content from several inputs, so a bound on
    any single input is not enough. Refusing here names the exact budget
    instead of surfacing Discord's opaque form error after the call.
    """
    if len(content) > MESSAGE_LIMIT:
        raise FMError(
            f"{field} would post {len(content)} characters of content; Discord accepts at most {MESSAGE_LIMIT}"
        )
    return content


def assert_publishable(text: str, field: str) -> str:
    bounded = bounded_text(text, field, BODY_LIMIT)
    for marker in OPERATIONAL_MARKERS:
        if marker in bounded:
            raise FMError(f"{field} contains operational supervision text; refusing to publish it")
    if TOKEN_LIKE_RE.search(bounded):
        raise FMError(f"{field} looks like it contains a token or key; refusing to publish it")
    for marker in ("-----BEGIN", "Bearer ", "sops:", "password=", "api_key"):
        if marker in bounded:
            raise FMError(f"{field} looks like it contains secret material; refusing to publish it")
    return bounded


# --------------------------------------------------------------------------
# live client
# --------------------------------------------------------------------------


class MirrorClient:
    """Thin bounded wrapper over the workspace live client."""

    def __init__(self, token: str) -> None:
        self._client = fdl.DiscordClient(token)
        self._active_threads: Dict[str, List[Dict[str, Any]]] = {}
        self._channels: Dict[str, Dict[str, Any]] = {}
        self._archived: Dict[str, List[Dict[str, Any]]] = {}
        self._guilds: Dict[str, Dict[str, Any]] = {}
        self._guild_webhooks: Dict[str, List[Dict[str, Any]]] = {}
        self.calls = 0

    @property
    def token(self) -> str:
        return self._client.token

    def redact(self, text: str) -> str:
        return fdl.redact(text, self._client.token)

    def _request(self, method: str, path: str, body: Optional[Dict[str, Any]] = None, params: Optional[Dict[str, str]] = None) -> Any:
        self.calls += 1
        return self._client.request(method, path, body, params)

    def channel(self, channel_id: str) -> Dict[str, Any]:
        if channel_id not in self._channels:
            data = self._request("GET", f"/channels/{channel_id}")
            if not isinstance(data, dict):
                raise FMError(f"channel lookup for {channel_id} was malformed")
            self._channels[channel_id] = data
        return self._channels[channel_id]

    def active_threads(self, guild_id: str) -> List[Dict[str, Any]]:
        if guild_id not in self._active_threads:
            data = self._request("GET", f"/guilds/{guild_id}/threads/active")
            threads = data.get("threads") if isinstance(data, dict) else None
            if threads is None:
                raise FMError(f"active thread listing for guild {guild_id} was malformed")
            if not isinstance(threads, list):
                raise FMError(f"active thread listing for guild {guild_id} was malformed")
            self._active_threads[guild_id] = [t for t in threads if isinstance(t, dict)]
        return self._active_threads[guild_id]

    def archived_threads(self, forum_id: str, limit: int) -> List[Dict[str, Any]]:
        if forum_id not in self._archived:
            data = self._request("GET", f"/channels/{forum_id}/threads/archived/public", params={"limit": str(limit)})
            threads = data.get("threads") if isinstance(data, dict) else None
            if not isinstance(threads, list):
                self._archived[forum_id] = []
            else:
                self._archived[forum_id] = [t for t in threads if isinstance(t, dict)]
        return self._archived[forum_id]

    def create_forum_thread(self, forum_id: str, title: str, content: str, applied_tags: List[str]) -> Dict[str, Any]:
        body: Dict[str, Any] = {
            "name": title,
            "auto_archive_duration": 10080,
            "message": {"content": content, "allowed_mentions": {"parse": []}},
        }
        if applied_tags:
            body["applied_tags"] = applied_tags
        data = self._request("POST", f"/channels/{forum_id}/threads", body)
        if not isinstance(data, dict) or not str(data.get("id") or "").isdigit():
            raise FMError("Discord did not return a usable thread id")
        return data

    def set_thread_tags(self, thread_id: str, applied_tags: List[str]) -> None:
        self._request("PATCH", f"/channels/{thread_id}", {"applied_tags": applied_tags})

    def post_message(self, channel_id: str, content: str) -> Dict[str, Any]:
        data = self._request(
            "POST",
            f"/channels/{channel_id}/messages",
            {"content": content, "allowed_mentions": {"parse": []}},
        )
        if not isinstance(data, dict) or not str(data.get("id") or "").isdigit():
            raise FMError("Discord did not return a usable message id")
        return data

    def edit_message(self, channel_id: str, message_id: str, content: str) -> None:
        self._request("PATCH", f"/channels/{channel_id}/messages/{message_id}", {"content": content})

    def thread(self, thread_id: str) -> Dict[str, Any]:
        return self.channel(thread_id)

    def starter_message(self, thread_id: str) -> Dict[str, Any]:
        data = self._request("GET", f"/channels/{thread_id}/messages/{thread_id}")
        if not isinstance(data, dict):
            raise FMError(f"thread starter message for {thread_id} was malformed")
        return data

    def guild(self, guild_id: str) -> Dict[str, Any]:
        if guild_id not in self._guilds:
            data = self._request("GET", f"/guilds/{guild_id}")
            if not isinstance(data, dict):
                raise FMError(f"guild lookup for {guild_id} was malformed")
            self._guilds[guild_id] = data
        return self._guilds[guild_id]

    def guild_webhooks(self, guild_id: str) -> List[Dict[str, Any]]:
        if guild_id not in self._guild_webhooks:
            data = self._request("GET", f"/guilds/{guild_id}/webhooks")
            if not isinstance(data, list):
                raise FMError(f"webhook listing for guild {guild_id} was malformed")
            self._guild_webhooks[guild_id] = [item for item in data if isinstance(item, dict)]
        return self._guild_webhooks[guild_id]

    def create_channel_webhook(self, channel_id: str, name: str) -> Dict[str, Any]:
        data = self._request("POST", f"/channels/{channel_id}/webhooks", {"name": name})
        if not isinstance(data, dict) or not str(data.get("id") or "").isdigit() or not data.get("token"):
            raise FMError(f"Discord did not return a usable webhook for channel {channel_id}")
        return data

    def set_channel_tags(self, channel_id: str, available_tags: List[Dict[str, str]]) -> None:
        self._request("PATCH", f"/channels/{channel_id}", {"available_tags": available_tags})
        self._channels.pop(channel_id, None)


# --------------------------------------------------------------------------
# webhook transport
# --------------------------------------------------------------------------


class WebhookEntry:
    """One project forum webhook from the captain-owned webhook file.

    The execute url and its token are secrets: they are read at runtime, kept
    only in memory, and never printed, logged, or written into mirror state.
    """

    def __init__(self, raw: Dict[str, Any], index: int) -> None:
        prefix = f"webhooks[{index}]"
        if not isinstance(raw, dict):
            raise FMError(f"{prefix} must be a JSON object")
        self.guild = bounded_text(raw.get("guild", ""), f"{prefix}.guild", 80, allow_empty=True)
        self.guild_slug = bounded_text(raw.get("guild_slug", ""), f"{prefix}.guild_slug", 40, allow_empty=True)
        self.project = bounded_text(raw.get("project", ""), f"{prefix}.project", 80, allow_empty=True)
        self.kind = str(raw.get("kind") or "")
        if self.kind not in WEBHOOK_KINDS:
            raise FMError(f"{prefix}.kind must be one of {', '.join(WEBHOOK_KINDS)}")
        self.channel_id = fwl.validate_snowflake(raw.get("channel_id"), f"{prefix}.channel_id") or ""
        self.webhook_id = fwl.validate_snowflake(raw.get("webhook_id"), f"{prefix}.webhook_id", required=False) or ""
        match = WEBHOOK_URL_RE.fullmatch(str(raw.get("url") or ""))
        if match is None:
            raise FMError(f"{prefix}.url must be a Discord webhook execute url")
        self.token = match.group(2)
        if self.webhook_id and self.webhook_id != match.group(1):
            raise FMError(f"{prefix}.webhook_id does not match the execute url")
        self.webhook_id = self.webhook_id or match.group(1)
        # Only the identity and the token are kept: the execute url is composed
        # at call time, so no url is ever stored, printed, or written to state.

    @property
    def api_base(self) -> str:
        return (os.environ.get("FM_DISCORD_MIRROR_WEBHOOK_API_BASE") or WEBHOOK_API_BASE).rstrip("/")

    @property
    def execute_url(self) -> str:
        return f"{self.api_base}/webhooks/{self.webhook_id}/{self.token}"

    def redact(self, text: str) -> str:
        return text.replace(self.token, "[REDACTED]").replace(self.execute_url, "[webhook]")


class WebhookStore:
    """The captain-owned webhook file; a missing file simply means no webhooks."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.entries: List[WebhookEntry] = []
        self.error = ""
        if path.is_symlink():
            raise FMError(f"refusing unsafe webhook file: {path}")
        if not path.exists():
            return
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise FMError(f"webhook file is malformed: {path}") from exc
        items = raw.get("webhooks") if isinstance(raw, dict) else raw
        if not isinstance(items, list):
            raise FMError(f"webhook file must hold a list of webhooks: {path}")
        for index, item in enumerate(items):
            self.entries.append(WebhookEntry(item, index))

    def for_channel(self, kind: str, channel_id: str) -> Optional[WebhookEntry]:
        if not channel_id:
            return None
        for entry in self.entries:
            if entry.kind == kind and entry.channel_id == channel_id:
                return entry
        return None


class WebhookClient:
    """Bounded webhook transport: create a forum post, edit it, post a link."""

    def __init__(self, entry: WebhookEntry) -> None:
        self.entry = entry
        self.calls = 0

    def _request(self, method: str, path: str, body: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        url = f"{self.entry.execute_url}{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Content-Type": "application/json", "User-Agent": WEBHOOK_USER_AGENT, "Accept": "application/json"}
        last = ""
        for attempt in range(WEBHOOK_MAX_RETRIES + 1):
            self.calls += 1
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request) as response:
                    payload = response.read().decode("utf-8")
                    return json.loads(payload) if payload else {}
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace")
                if exc.code == 429 and attempt < WEBHOOK_MAX_RETRIES:
                    time.sleep(self._retry_after(exc.headers))
                    continue
                if 500 <= exc.code < 600 and attempt < WEBHOOK_MAX_RETRIES:
                    time.sleep(0.5)
                    continue
                raise FMError(self.entry.redact(f"Discord webhook {method} {path or '/'} failed with HTTP {exc.code}: {detail}"))
            except urllib.error.URLError as exc:
                last = self.entry.redact(f"Discord webhook transport failure: {exc.reason}")
                if attempt < WEBHOOK_MAX_RETRIES:
                    time.sleep(0.5)
                    continue
                raise FMError(last)
        raise FMError(last or "Discord webhook call failed")

    @staticmethod
    def _retry_after(headers: Any) -> float:
        try:
            value = headers.get("Retry-After")
            if value:
                return min(float(value) / 1000.0, 30.0)
        except (TypeError, ValueError):
            pass
        return 0.5

    def create_forum_post(
        self, thread_name: str, content: str, username: str, applied_tags: List[str]
    ) -> Dict[str, Any]:
        body: Dict[str, Any] = {
            "content": content,
            "username": truncate(username, USERNAME_LIMIT),
            "thread_name": thread_name,
            "allowed_mentions": {"parse": []},
        }
        if applied_tags:
            body["applied_tags"] = applied_tags
        data = self._request("POST", "?wait=true", body)
        if not isinstance(data, dict) or not str(data.get("id") or "").isdigit():
            raise FMError("Discord did not return a usable forum post id")
        return data

    def edit_message(self, message_id: str, thread_id: str, content: str) -> None:
        self._request("PATCH", f"/messages/{message_id}?thread_id={thread_id}", {"content": content})

    def post_message(self, thread_id: str, content: str) -> Dict[str, Any]:
        data = self._request(
            "POST",
            f"?thread_id={thread_id}&wait=true",
            {"content": content, "allowed_mentions": {"parse": []}},
        )
        if not isinstance(data, dict) or not str(data.get("id") or "").isdigit():
            raise FMError("Discord did not return a usable message id")
        return data


class Transport:
    """One posting identity for one project forum.

    A configured webhook for that exact (kind, forum) is the primary transport
    and needs no bot membership. It is bounded by design: it can create a forum
    post, edit the message it created, and post a link message, but it cannot
    read a channel and it cannot change an existing thread's tags. Everything
    that needs reading or re-tagging falls back to the member-bot transport.
    """

    def __init__(
        self,
        passing: "Pass",
        project: MirrorProject,
        kind: str,
        forum_id: str,
        forced: str = "auto",
    ) -> None:
        self.passing = passing
        self.project = project
        self.kind = kind
        self.forum_id = forum_id
        self.forced = forced if forced != "auto" else (project.transport if project.transport != "auto" else passing.cfg.transport)
        entry = passing.webhooks.for_channel(kind, forum_id)
        if self.forced == "bot":
            entry = None
        elif self.forced == "webhook" and entry is None:
            raise FMError(
                f"transport=webhook is configured for {kind} forum {forum_id} but the webhook file has no matching entry"
            )
        self.webhook = entry
        self.webhook_client: Optional[WebhookClient] = WebhookClient(self.webhook) if self.webhook is not None else None
        self._bot: Optional[MirrorClient] = None

    @property
    def name(self) -> str:
        return "webhook" if self.webhook is not None else "bot"

    @property
    def identity(self) -> str:
        if self.webhook is not None:
            return self.webhook.webhook_id
        return self.project.guild_id

    def bot(self, env: Env) -> MirrorClient:
        if self._bot is None:
            self._bot = self.passing.client_for(env)
        return self._bot

    def redact(self, text: str) -> str:
        if self.webhook is not None:
            text = self.webhook.redact(text)
        if self._bot is not None:
            text = self._bot.redact(text)
        return text

    def resolve_tag_ids(self, env: Env, wanted: List[str]) -> Tuple[List[str], List[str]]:
        if self.webhook is not None:
            ids: List[str] = []
            missing: List[str] = []
            for name in wanted:
                # A configured numeric tag id needs no name-to-id lookup; a
                # webhook cannot read the forum's vocabulary anyway.
                if fwl.ID_RE.fullmatch(name):
                    tag_id = name
                else:
                    tag_id = self.project.tag_ids.get(name)
                if tag_id:
                    if tag_id not in ids:
                        ids.append(tag_id)
                else:
                    missing.append(name)
            return ids, missing
        available = self.passing.available_tags(env, self.forum_id)
        by_name = {tag["name"]: tag["id"] for tag in available}
        ids = []
        missing = []
        for name in wanted:
            tag_id = name if fwl.ID_RE.fullmatch(name) else by_name.get(name)
            if tag_id:
                if tag_id not in ids:
                    ids.append(tag_id)
            else:
                missing.append(name)
        return ids, missing

    def create_forum_post(self, env: Env, title: str, content: str, tag_ids: List[str], username: str) -> Tuple[str, str]:
        """Create the forum post, returning (thread id, posting identity)."""
        if self.webhook_client is not None:
            posted = self.webhook_client.create_forum_post(title, content, username, tag_ids)
            author = posted.get("author") if isinstance(posted.get("author"), dict) else {}
            return str(posted["id"]), str(author.get("username") or "")
        created = self.bot(env).create_forum_thread(self.forum_id, title, content, tag_ids)
        return str(created["id"]), ""

    def edit_card(self, env: Env, thread_id: str, message_id: str, content: str) -> None:
        if self.webhook_client is not None:
            self.webhook_client.edit_message(message_id, thread_id, content)
            return
        self.bot(env).edit_message(thread_id, message_id, content)

    def post_message(self, env: Env, thread_id: str, content: str) -> str:
        if self.webhook_client is not None:
            return str(self.webhook_client.post_message(thread_id, content)["id"])
        return str(self.bot(env).post_message(thread_id, content)["id"])

    def set_thread_tags(self, env: Env, thread_id: str, tag_ids: List[str]) -> bool:
        """Only a member bot can re-tag an existing thread; a webhook cannot."""
        if self.webhook is not None:
            return False
        self.bot(env).set_thread_tags(thread_id, tag_ids)
        return True

    def reads_channels(self) -> bool:
        return self.webhook is None

    def forum_threads(self, env: Env) -> Dict[str, Dict[str, Any]]:
        """Existing threads by name; empty when the transport cannot read."""
        if self.webhook is not None:
            return {}
        return self.passing.forum_threads(env, self.project, self.forum_id)

    def thread(self, env: Env, thread_id: str) -> Dict[str, Any]:
        if self.webhook is not None:
            raise FMError(
                "recognizing a thread needs a reading identity; invite the Firstmate bot to the guild "
                "or bind the thread explicitly with bind --thread <id> --task <id>"
            )
        return self.bot(env).thread(thread_id)

    def starter_message(self, env: Env, thread_id: str) -> Dict[str, Any]:
        if self.webhook is not None:
            raise FMError("a webhook transport cannot read a thread starter message")
        return self.bot(env).starter_message(thread_id)


# --------------------------------------------------------------------------
# task inventory and reconciled state
# --------------------------------------------------------------------------


def meta_value(meta_text: str, key: str) -> str:
    for line in meta_text.splitlines():
        if line.startswith(f"{key}="):
            return line[len(key) + 1 :]
    return ""


def live_tasks(env: Env) -> List[Dict[str, str]]:
    tasks: List[Dict[str, str]] = []
    state_dir = env.state
    if not state_dir.is_dir():
        return tasks
    for meta_path in sorted(state_dir.glob("*.meta")):
        if meta_path.is_symlink() or not meta_path.is_file():
            continue
        task_id = meta_path.name[: -len(".meta")]
        if not fwl.TASK_ID_RE.fullmatch(task_id):
            continue
        try:
            text = meta_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        kind = meta_value(text, "kind")
        if kind not in ("ship", "scout"):
            continue
        project = meta_value(text, "project")
        worktree = meta_value(text, "worktree")
        if not project or not worktree:
            continue
        tasks.append({"task": task_id, "project": project, "worktree": worktree, "kind": kind})
    tasks.sort(key=lambda row: row["task"])
    return tasks


def reconciled_state(env: Env, task_id: str) -> str:
    """The task's reconciled current state, owned by bin/fm-crew-state.sh."""
    command = os.environ.get("FM_DISCORD_MIRROR_STATE_CMD") or str(env.script_dir / "fm-crew-state.sh")
    child_env = dict(os.environ)
    child_env["FM_HOME"] = str(env.home)
    child_env["FM_CREW_STATE_NO_FORGE"] = "1"
    try:
        proc = subprocess.run(
            [command, task_id],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=CREW_STATE_TIMEOUT,
            env=child_env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    if proc.returncode != 0:
        return "unknown"
    match = STATE_LINE_RE.match(proc.stdout.strip())
    if not match:
        return "unknown"
    state = match.group(1)
    return state if state in REQUIRED_STATE_KEYS else "unknown"


# --------------------------------------------------------------------------
# state records
# --------------------------------------------------------------------------


class MirrorState:
    """Durable mirror state; one owner per file, written atomically."""

    def __init__(self, env: Env) -> None:
        self.env = env

    def path(self, *parts: str) -> Path:
        return mirror_state_path(self.env, *parts)

    def load(self, *parts: str) -> Optional[Dict[str, Any]]:
        path = self.path(*parts)
        if not path.exists():
            return None
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise FMError(f"mirror state file is malformed: {path}") from exc
        if not isinstance(data, dict):
            raise FMError(f"mirror state file is malformed: {path}")
        return data

    def save(self, *parts: str, data: Dict[str, Any]) -> str:
        path = self.path(*parts)
        previous = self.load(*parts)
        if previous is None:
            result = "recorded"
        elif {k: v for k, v in previous.items() if k != "updated_at"} == {k: v for k, v in data.items() if k != "updated_at"}:
            return "unchanged"
        else:
            result = "updated"
        data = dict(data)
        data["updated_at"] = utc_now()
        with fwl.state_transaction(self.env):
            fwl.atomic_json(path, data)
        return result

    def session_record(self, task_id: str) -> Optional[Dict[str, Any]]:
        return self.load("sessions", f"{task_id}.json")

    def save_session(self, task_id: str, data: Dict[str, Any]) -> str:
        return self.save("sessions", f"{task_id}.json", data=data)

    def request_record(self, request_id: str) -> Optional[Dict[str, Any]]:
        return self.load("requests", f"{request_id}.json")

    def save_request(self, request_id: str, data: Dict[str, Any]) -> str:
        return self.save("requests", f"{request_id}.json", data=data)

    def artifact_record(self, nonce_digest: str) -> Optional[Dict[str, Any]]:
        return self.load("artifacts", f"{nonce_digest}.json")

    def save_artifact(self, nonce_digest: str, data: Dict[str, Any]) -> str:
        return self.save("artifacts", f"{nonce_digest}.json", data=data)

    def session_records(self) -> List[Dict[str, Any]]:
        return self._records("sessions")

    def request_records(self) -> List[Dict[str, Any]]:
        return self._records("requests")

    def artifact_records(self) -> List[Dict[str, Any]]:
        return self._records("artifacts")

    def _records(self, kind: str) -> List[Dict[str, Any]]:
        directory = self.path(kind)
        out: List[Dict[str, Any]] = []
        if not directory.is_dir():
            return out
        for path in sorted(directory.glob("*.json")):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(data, dict):
                out.append(data)
        return out


# --------------------------------------------------------------------------
# pass planning and execution
# --------------------------------------------------------------------------


class Pass:
    """One bounded mirror pass; collects a deterministic plan then applies it."""

    def __init__(self, cfg: MirrorConfig, state: MirrorState, live: bool) -> None:
        self.cfg = cfg
        self.state = state
        self.live = live
        self.lines: List[str] = []
        self.client: Optional[MirrorClient] = None
        self.failures = 0
        self.transport_names: List[str] = []
        self._transports: List[Transport] = []
        self._tag_cache: Dict[str, List[Dict[str, str]]] = {}
        self.webhooks = WebhookStore(state.env.home / cfg.webhook_file)

    def note(self, line: str) -> None:
        self.lines.append(line)

    def redact(self, text: str) -> str:
        for transport in self._transports:
            text = transport.redact(text)
        if self.client is not None:
            text = self.client.redact(text)
        return text

    def transport(self, project: MirrorProject, kind: str, forum_id: str, forced: str = "auto") -> Transport:
        transport = Transport(self, project, kind, forum_id, forced)
        if transport.name not in self.transport_names:
            self.transport_names.append(transport.name)
        self._transports.append(transport)
        return transport

    def client_for(self, env: Env) -> MirrorClient:
        if self.client is None:
            token = fdl.decrypt_token_from(env, self.cfg.secret_file, self.cfg.token_key)
            self.client = MirrorClient(token)
        return self.client

    def available_tags(self, env: Env, forum_id: str) -> List[Dict[str, str]]:
        if forum_id not in self._tag_cache:
            channel = self.client_for(env).channel(forum_id)
            raw = channel.get("available_tags")
            tags: List[Dict[str, str]] = []
            if isinstance(raw, list):
                for item in raw:
                    if isinstance(item, dict) and item.get("id") and item.get("name"):
                        tags.append({"id": str(item["id"]), "name": str(item["name"])})
            self._tag_cache[forum_id] = tags
        return self._tag_cache[forum_id]

    def forum_threads(self, env: Env, project: MirrorProject, forum_id: str) -> Dict[str, Dict[str, Any]]:
        client = self.client_for(env)
        found: Dict[str, Dict[str, Any]] = {}
        for thread in client.active_threads(project.guild_id):
            if str(thread.get("parent_id") or "") == forum_id:
                found[str(thread.get("name") or "")] = thread
        if not found:
            for thread in client.archived_threads(forum_id, self.cfg.max_thread_listing):
                if str(thread.get("parent_id") or "") == forum_id:
                    found.setdefault(str(thread.get("name") or ""), thread)
        return found

    def api_calls(self) -> int:
        total = self.client.calls if self.client is not None else 0
        seen: set[int] = set()
        for transport in self._transports:
            client = transport.webhook_client
            if client is not None and id(client) not in seen:
                seen.add(id(client))
                total += client.calls
        return total


def cmd_sync(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    state = MirrorState(env)
    tasks = live_tasks(env)
    if args.task:
        wanted = set(args.task)
        tasks = [row for row in tasks if row["task"] in wanted]
    live = bool(cfg.live_posting and not args.dry_run)
    passing = Pass(cfg, state, live)
    if not live:
        passing.note("dry-run: no Discord write is attempted (enable live.posting or drop --dry-run)")
    deferred = tasks[cfg.max_tasks_per_pass :]
    tasks = tasks[: cfg.max_tasks_per_pass]
    if deferred:
        passing.note(f"deferred {len(deferred)} task(s) beyond bounds.max_tasks_per_pass: " + ", ".join(row["task"] for row in deferred))
    for task in tasks:
        try:
            sync_task(passing, cfg, env, state, task, args.transport)
        except ERRTYPES as exc:
            # One task's failure never hides the rest of the pass, and it never
            # looks like success: the reasons are printed and the pass exits 1.
            passing.failures += 1
            passing.note(f"{task['task']}: error: {passing.redact(str(exc))}")
    for line in passing.lines:
        print(line)
    print(
        f"mirror pass complete: live={'yes' if live else 'no'} tasks={len(tasks)} "
        f"failed={passing.failures} transports={','.join(passing.transport_names) or 'none'} api_calls={passing.api_calls()}"
    )
    return 1 if passing.failures else 0


def sync_task(passing: Pass, cfg: MirrorConfig, env: Env, state: MirrorState, task: Dict[str, str], forced_transport: str = "auto") -> None:
    task_id = task["task"]
    project = cfg.project_for_path(task["project"])
    if project is None:
        passing.note(f"{task_id}: skipped, no configured project mapping for {task['project']}")
        return
    worktree = worktree_name(task["worktree"])
    state_name = reconciled_state(env, task_id)
    state_tag = cfg.state_tags[state_name]
    record = state.session_record(task_id)
    title = render_thread_title(project.label, task_id, worktree)
    # The transport that created the card message owns every later card edit,
    # because Discord only lets the author edit its own message. Tag updates are
    # separate: only a member bot can change an existing thread's tags, so a
    # webhook-authored thread still gets its tags from the member-bot transport.
    created_with = record.get("transport") if record is not None else ""
    forced = forced_transport if forced_transport in ("webhook", "bot") else ""
    card_mode = created_with if created_with in ("webhook", "bot") else (forced or "auto")
    if forced and created_with in ("webhook", "bot") and forced != created_with:
        # Discord only lets the message author edit it, so the recorded creator
        # keeps the card; the requested transport is honored for tag updates.
        passing.note(f"{task_id}: the card was posted by the {created_with} transport, so its edits stay there ({forced} requested)")
    transport = passing.transport(project, "sessions", project.sessions_forum_id, card_mode)
    if record is not None and record.get("project") != project.key:
        passing.note(f"{task_id}: skipped, recorded thread belongs to project {record.get('project')} but the task now reports {project.key}")
        return
    if record is not None and record.get("create_intent"):
        passing.note(
            f"{task_id}: unresolved create intent from {record.get('create_intent')}; the webhook transport cannot read the "
            f"forum, so verify the thread and record it with bind --task {task_id} --thread <id> instead of risking a duplicate"
        )
        return
    if record is None:
        record = {
            "schema": SESSION_SCHEMA,
            "task": task_id,
            "project": project.key,
            "guild_id": project.guild_id,
            "forum_id": project.sessions_forum_id,
            "transport": transport.name,
            "thread_id": "",
            "thread_name": title,
            "created_thread": False,
            "card_message_id": "",
            "worktree": worktree,
            "registered_at": utc_now(),
        }
    if not record.get("thread_id"):
        if not passing.live:
            passing.note(f"{task_id}: would create thread '{title}' in forum {project.sessions_forum_id} via the {transport.name} transport")
            return
        existing = transport.forum_threads(env).get(title)
        if existing is not None:
            record["thread_id"] = str(existing.get("id") or "")
            record["created_thread"] = False
            record["card_message_id"] = record["thread_id"]
            record["applied_tag_ids"] = [str(tag) for tag in (existing.get("applied_tags") or [])]
            try:
                starter = transport.starter_message(env, record["thread_id"])
                record["card_sha256"] = fwl.sha256_text(str(starter.get("content") or ""))
            except ERRTYPES:
                # A missing or unreadable starter message only means the card is
                # rewritten on this pass; it never authorizes a second thread.
                record.pop("card_sha256", None)
            passing.note(f"{task_id}: adopted existing thread {record['thread_id']} by exact title")
        else:
            card = render_card(project, task_id, worktree, worktree_branch(task["worktree"]), state_name)
            tag_ids, missing = transport.resolve_tag_ids(env, [cfg.session_tag, cfg.worktree_tag, state_tag])
            if missing and not (transport.webhook is not None and cfg.allow_untagged):
                missing_label = "has no configured tag id for" if transport.webhook is not None else "lacks tag(s):"
                passing.note(f"{task_id}: skipped, forum {project.sessions_forum_id} {missing_label} {', '.join(missing)}")
                return
            if missing:
                passing.note(
                    f"{task_id}: posting without tags; no configured tag id for {', '.join(missing)} - add "
                    f"projects.{project.key}.tag_ids (a webhook cannot read a forum's tag vocabulary), then tag the thread once "
                    f"a member bot is available"
                )
            if transport.webhook is not None:
                # The webhook transport cannot read the forum back, so the intent
                # is durable before the call: a crash in that window is reported
                # for verification instead of risking a duplicate thread.
                record["create_intent"] = utc_now()
                state.save_session(task_id, record)
            thread_id, posting_identity = transport.create_forum_post(
                env, title, card, tag_ids, session_identity(project, worktree)
            )
            if posting_identity:
                record["posting_identity"] = posting_identity
            record["thread_id"] = thread_id
            record["created_thread"] = True
            record["card_message_id"] = thread_id
            record["card_sha256"] = fwl.sha256_text(card)
            record["applied_tag_ids"] = tag_ids
            record["state"] = state_name
            record["state_tag"] = state_tag
            record.pop("create_intent", None)
            passing.note(f"{task_id}: created thread {thread_id} ({title}) via the {transport.name} transport")
    if not passing.live:
        passing.note(f"{task_id}: would reconcile state={state_name} tag={state_tag} (thread {record.get('thread_id') or 'none'})")
        return
    worktree = record.get("worktree") or worktree
    tagger = transport if transport.reads_channels() else passing.transport(project, "sessions", project.sessions_forum_id, "bot")
    # Tag id resolution stays with the card transport: a webhook takes them from
    # the config, a member bot reads the live vocabulary. The member-bot tagger is
    # only exercised when a tag actually has to change on an existing thread.
    tag_source = transport
    tag_ids, missing = tag_source.resolve_tag_ids(env, [cfg.session_tag, cfg.worktree_tag, state_tag])
    if missing:
        if transport.webhook is not None and cfg.allow_untagged:
            # Already reported when the thread was created; the card carries the
            # state and no webhook can re-tag an existing thread.
            pass
        else:
            missing_label = "has no configured tag id for" if tag_source.webhook is not None else "lacks tag(s):"
            passing.note(f"{task_id}: state tag not reconciled, forum {project.sessions_forum_id} {missing_label} {', '.join(missing)}")
    elif sorted(str(x) for x in (record.get("applied_tag_ids") or [])) != sorted(tag_ids):
        if not tagger.reads_channels():
            record["applied_tag_ids"] = tag_ids
            passing.note(
                f"{task_id}: state {state_name} is in the card; a webhook cannot re-tag an existing thread, "
                f"so the tags stay {cfg.session_tag}, {cfg.worktree_tag} until a member bot is available"
            )
        else:
            try:
                tagger.set_thread_tags(env, record["thread_id"], tag_ids)
            except ERRTYPES as exc:
                limit = (
                    "; a webhook cannot re-tag an existing thread, so the card carries the state"
                    if transport.webhook is not None
                    else ""
                )
                passing.note(f"{task_id}: could not update the thread tags: {tagger.redact(str(exc))}{limit}")
            else:
                record["applied_tag_ids"] = tag_ids
                passing.note(f"{task_id}: tags now {cfg.session_tag}, {cfg.worktree_tag}, {state_tag}")
    card = render_card(project, task_id, worktree, worktree_branch(task["worktree"]), state_name)
    card_digest = fwl.sha256_text(card)
    card_message_id = str(record.get("card_message_id") or "")
    if not card_message_id:
        record["card_message_id"] = transport.post_message(env, record["thread_id"], card)
        record["card_sha256"] = card_digest
        passing.note(f"{task_id}: session card posted in {record['thread_id']}")
    elif record.get("card_sha256") != card_digest:
        transport.edit_card(env, record["thread_id"], card_message_id, card)
        record["card_sha256"] = card_digest
        passing.note(f"{task_id}: session card updated in place in {record['thread_id']}")
    record["schema"] = SESSION_SCHEMA
    # The card owner is fixed when the card is first posted: Discord only lets
    # that identity edit it, so a later pass through another transport must not
    # move it.
    record.setdefault("transport", transport.name)
    record["state"] = state_name
    record["state_tag"] = state_tag
    record["worktree"] = worktree
    record["thread_name"] = title
    result = state.save_session(task_id, record)
    passing.note(f"{task_id}: session record {result} (state={state_name})")


def cmd_report(args: argparse.Namespace, env: Env) -> int:
    """Side-effect-free current mirror state; reads local records only."""
    cfg = load_config(env, args.config)
    state = MirrorState(env)
    records = {str(record.get("task")): record for record in state.session_records()}
    tasks = live_tasks(env)
    if args.task:
        wanted = set(args.task)
        tasks = [row for row in tasks if row["task"] in wanted]
    print("discord session mirror - local state (no network call)")
    print(f"config: {cfg.path}")
    print(f"live posting: {'enabled' if cfg.live_posting else 'disabled'}")
    print("projects:")
    webhooks = WebhookStore(env.home / cfg.webhook_file)
    print(f"webhook file: {cfg.webhook_file} ({len(webhooks.entries)} entries; urls never printed)")
    for key in sorted(cfg.projects):
        project = cfg.projects[key]
        artifact = project.artifact_forum_id or "(none configured)"
        sessions_transport = "webhook" if webhooks.for_channel("sessions", project.sessions_forum_id) else "bot"
        print(f"- {key}: guild {project.guild_id} sessions {project.sessions_forum_id} ({sessions_transport}) artifacts {artifact} paths {', '.join(project.paths)}")
    seen: set[str] = set()
    print("sessions:")
    for task in tasks:
        task_id = task["task"]
        seen.add(task_id)
        project = cfg.project_for_path(task["project"])
        if project is None:
            print(f"- {task_id}: unmapped project {task['project']}")
            continue
        record = records.get(task_id)
        worktree = worktree_name(task["worktree"])
        state_name = reconciled_state(env, task_id)
        thread = str((record or {}).get("thread_id") or "none")
        title = str((record or {}).get("thread_name") or render_thread_title(project.label, task_id, worktree))
        print(f"- {task_id}: project={project.key} worktree={worktree} state={state_name} tag={cfg.state_tags[state_name]} thread={thread} title={title}")
    for task_id, record in sorted(records.items()):
        if task_id in seen:
            continue
        print(f"- {task_id}: orphaned record (no live task) thread={record.get('thread_id') or 'none'}")
    requests = state.request_records()
    print(f"requests: {len(requests)}")
    for record in sorted(requests, key=lambda item: str(item.get("request_id"))):
        print(f"- {record.get('request_id')}: outcome={record.get('outcome')} project={record.get('project') or 'unknown'} thread={record.get('thread_id')} task={record.get('task') or 'unbound'}")
    artifacts = state.artifact_records()
    print(f"artifacts: {len(artifacts)}")
    for record in sorted(artifacts, key=lambda item: (str(item.get("task")), str(item.get("kind")))):
        print(f"- {record.get('task')}: kind={record.get('kind')} thread={record.get('thread_id')}")
    return 0


# --------------------------------------------------------------------------
# artifacts
# --------------------------------------------------------------------------


def task_row(env: Env, task_id: str) -> Dict[str, str]:
    if not fwl.TASK_ID_RE.fullmatch(task_id):
        raise FMError(f"invalid task id: {task_id}")
    meta_path = env.state / f"{task_id}.meta"
    if meta_path.is_symlink() or not meta_path.is_file():
        raise FMError(f"no task record for {task_id}")
    text = meta_path.read_text(encoding="utf-8", errors="replace")
    project = meta_value(text, "project")
    worktree = meta_value(text, "worktree")
    if not project:
        raise FMError(f"task record for {task_id} has no project")
    return {"task": task_id, "project": project, "worktree": worktree}


def cmd_artifact(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    state = MirrorState(env)
    task = task_row(env, args.task)
    project = cfg.project_for_path(task["project"])
    if project is None:
        raise FMError(f"no configured project mapping for {task['project']}")
    if not project.artifact_forum_id:
        raise FMError(f"project {project.key} has no artifact forum configured; refusing to post an artifact")
    kind = args.kind
    title = assert_publishable(args.title, "--title")
    body = assert_publishable(fwl.read_text_file(args.body_file), "--body-file")
    artifact_tag = project.artifact_tag_for(kind)
    thread_title = truncate(f"{project.label} - {task['task']} - {kind}", TITLE_LIMIT)
    digest = fwl.sha256_text(f"{kind}\n{title}\n{body}")
    nonce = f"artifact:{task['task']}:{kind}:{digest}"
    nonce_digest = fwl.sha256_text(nonce)
    record = state.artifact_record(nonce_digest)
    live = bool(cfg.live_posting and not args.dry_run)
    if not live:
        print(f"dry-run: would post artifact kind={kind} tag={artifact_tag or '(none)'} to forum {project.artifact_forum_id} and link it from the session thread")
        return 0
    passing = Pass(cfg, state, live)
    if record is None:
        artifact_transport = passing.transport(project, "artifacts", project.artifact_forum_id)
        existing = artifact_transport.forum_threads(env).get(thread_title)
        if existing is not None:
            thread_id = str(existing.get("id") or "")
            created = False
        else:
            wanted = [artifact_tag] if artifact_tag else []
            tag_ids, missing = artifact_transport.resolve_tag_ids(env, wanted)
            if missing:
                missing_label = "has no configured tag id for" if artifact_transport.webhook is not None else "lacks tag(s):"
                raise FMError(f"artifact forum {project.artifact_forum_id} {missing_label} {', '.join(missing)}")
            thread_id, _identity = artifact_transport.create_forum_post(
                env,
                thread_title,
                bounded_post_content(f"**{title}**\n\n{body}", "the artifact title and --body-file together"),
                tag_ids,
                session_identity(project, task["task"]),
            )
            created = True
        record = {
            "schema": ARTIFACT_SCHEMA,
            "task": task["task"],
            "project": project.key,
            "kind": kind,
            "title": title,
            "guild_id": project.guild_id,
            "forum_id": project.artifact_forum_id,
            "transport": artifact_transport.name,
            "thread_id": thread_id,
            "thread_name": thread_title,
            "created_thread": created,
            "body_sha256": fwl.sha256_text(body),
            "nonce": nonce,
            "created_at": utc_now(),
        }
        state.save_artifact(nonce_digest, record)
        print(f"artifact thread {thread_id} recorded ({'created' if created else 'adopted'}) via the {artifact_transport.name} transport")
    else:
        thread_id = str(record.get("thread_id") or "")
        print(f"artifact already recorded for this content: thread {thread_id}")
    session = state.session_record(task["task"])
    if session is None or not session.get("thread_id"):
        print("session thread is not mirrored yet; the artifact stands alone and no link was posted")
        return 0
    link_digest = fwl.sha256_text(f"artifact-link:{task['task']}:{thread_id}")
    if record.get("link_message_id"):
        print("session thread already links this artifact")
        return 0
    session_transport = passing.transport(project, "sessions", project.sessions_forum_id)
    message_id = session_transport.post_message(
        env,
        session["thread_id"],
        f"Artefact ({kind}) : {title}\nhttps://discord.com/channels/{project.guild_id}/{thread_id}",
    )
    record["link_message_id"] = message_id
    record["link_digest"] = link_digest
    state.save_artifact(nonce_digest, record)
    print(f"session thread {session['thread_id']} now links artifact {thread_id}")
    return 0


# --------------------------------------------------------------------------
# thread as a session request
# --------------------------------------------------------------------------


def request_id_for(thread_id: str) -> str:
    return fwl.sha256_text(f"discord-session-request:{thread_id}")[:32]


THREAD_TYPES = {10, 11, 12}


def cmd_request(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    state = MirrorState(env)
    thread_id = fwl.validate_snowflake(args.thread, "--thread") or ""
    request_id = request_id_for(thread_id)
    live = bool(cfg.live_posting and not args.dry_run)
    if not live:
        print(f"dry-run: would recognize thread {thread_id} as a session request and bind it to a configured project sessions forum")
        return 0
    passing = Pass(cfg, state, live)
    client = passing.client_for(env)
    try:
        channel = client.thread(thread_id)
    except ERRTYPES as exc:
        raise FMError(
            f"cannot read thread {thread_id} to recognize it ({client.redact(str(exc))}); recognition needs a "
            "reading identity, so bind the thread explicitly with bind --thread <id> --task <id> instead"
        ) from exc
    parent_id = str(channel.get("parent_id") or "")
    thread_type = int(channel.get("type") or -1)
    project = cfg.project_for_sessions_forum(parent_id) if thread_type in THREAD_TYPES else None
    outcome = "refused"
    reason = ""
    if thread_type not in THREAD_TYPES:
        reason = "this is not a forum thread"
    elif not parent_id:
        reason = "this thread has no parent forum"
    elif project is None:
        reason = "this thread is not in a configured project sessions forum"
    ask = ""
    author_id = ""
    if not reason:
        starter = client.starter_message(thread_id)
        author = starter.get("author") if isinstance(starter.get("author"), dict) else {}
        author_id = str(author.get("id") or "")
        if bool(author.get("bot")):
            reason = "the thread was not started by the captain"
        elif author_id not in cfg.captain_user_ids:
            reason = "the thread was not started by a configured captain account"
        else:
            ask = assert_publishable(str(starter.get("content") or ""), "thread starter message")
    if not reason and args.text_file:
        ask = assert_publishable(fwl.read_text_file(args.text_file), "--text-file")
    if not reason:
        outcome = "accepted"
    record = {
        "schema": REQUEST_SCHEMA,
        "request_id": request_id,
        "thread_id": thread_id,
        "guild_id": str(channel.get("guild_id") or ""),
        "forum_id": parent_id,
        "project": project.key if project is not None else "",
        "outcome": outcome,
        "reason": reason,
        "captain_author_id": author_id,
        "ask_sha256": fwl.sha256_text(ask) if ask else "",
        "task": "",
        "created_at": utc_now(),
    }
    existing = state.request_record(request_id)
    if existing is not None and existing.get("outcome") == outcome and existing.get("reason") == reason:
        record = existing
        already = True
    else:
        already = False
    if outcome == "refused":
        message = (
            "Demande de session refusee : "
            + reason
            + ".\nAucune session n'a ete ouverte. Forums reconnus : "
            + ", ".join(f"{key} ({project.sessions_forum_id})" for key, project in sorted(cfg.projects.items()))
        )
        if not already:
            posted = client.post_message(thread_id, message)
            record["refusal_message_id"] = str(posted["id"])
        state.save_request(request_id, record)
        print(f"request {request_id}: refused ({reason})")
        return 0
    note_id = str(existing.get("note_id") or "") if existing else ""
    if not note_id:
        note_id = feed_inbox(env, thread_id, record, ask)
        record["note_id"] = note_id
    state.save_request(request_id, record)
    print(f"request {request_id}: accepted for project {project.key}; session will be bound to thread {thread_id}")
    return 0


def feed_inbox(env: Env, thread_id: str, record: Dict[str, Any], ask: str) -> str:
    """Wake firstmate through the existing captain-inbox seam."""
    metadata_dir = mirror_state_path(env, "metadata-staging")
    metadata_dir.mkdir(parents=True, exist_ok=True)
    fd, meta_tmp = tempfile.mkstemp(prefix=".request.", suffix=".json", dir=str(metadata_dir))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "schema": REQUEST_SCHEMA,
                    "request_id": record["request_id"],
                    "thread_id": thread_id,
                    "forum_id": record["forum_id"],
                    "project": record["project"],
                },
                handle,
                indent=2,
                sort_keys=True,
            )
            handle.write("\n")
        os.chmod(meta_tmp, 0o600)
        body = (
            f"Discord session request in thread {thread_id} (project {record['project']}).\n"
            f"Ask: {ask}\n"
            f"Bind a session with: bin/fm-discord-session-mirror.sh bind --thread {thread_id} --task <task-id>"
        )
        proc = subprocess.run(
            [
                str(env.script_dir / "fm-inbox.sh"),
                "note",
                "--source",
                "discord-session-mirror",
                "--external-id",
                thread_id,
                "--metadata-file",
                meta_tmp,
                "-",
            ],
            input=body,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise FMError(f"could not record the session request wake: {proc.stderr.strip() or proc.stdout.strip()}")
        for line in proc.stdout.splitlines():
            if line.startswith("queued "):
                return line.split(None, 1)[1].strip()
        raise FMError("the captain-inbox seam did not report a queued note id")
    finally:
        try:
            os.unlink(meta_tmp)
        except FileNotFoundError:
            pass


def cmd_bind(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    state = MirrorState(env)
    thread_id = fwl.validate_snowflake(args.thread, "--thread") or ""
    task = task_row(env, args.task)
    project = cfg.project_for_path(task["project"])
    if project is None:
        raise FMError(f"no configured project mapping for {task['project']}")
    live = bool(cfg.live_posting and not args.dry_run)
    request_id = request_id_for(thread_id)
    request = state.request_record(request_id)
    if request is not None and request.get("outcome") != "accepted":
        raise FMError(f"thread {thread_id} was refused as a session request; refusing to bind it")
    if not live:
        print(f"dry-run: would bind task {task['task']} to thread {thread_id} in project {project.key}")
        return 0
    passing = Pass(cfg, state, live)
    transport = passing.transport(project, "sessions", project.sessions_forum_id)
    channel: Dict[str, Any] = {}
    if transport.reads_channels():
        channel = transport.thread(env, thread_id)
        parent_id = str(channel.get("parent_id") or "")
        if parent_id != project.sessions_forum_id:
            raise FMError(f"thread {thread_id} is not in project {project.key} sessions forum {project.sessions_forum_id}")
    worktree = worktree_name(task["worktree"]) if task["worktree"] else task["task"]
    state_name = reconciled_state(env, task["task"])
    record = state.session_record(task["task"]) or {
        "schema": SESSION_SCHEMA,
        "task": task["task"],
        "project": project.key,
        "guild_id": project.guild_id,
        "forum_id": project.sessions_forum_id,
        "transport": transport.name,
        "thread_id": thread_id,
        "created_thread": False,
        "card_message_id": "",
        "worktree": worktree,
        "registered_at": utc_now(),
    }
    if record.get("thread_id") and record["thread_id"] != thread_id:
        raise FMError(f"task {task['task']} is already mirrored in thread {record['thread_id']}; refusing a second thread")
    record["thread_id"] = thread_id
    record["thread_name"] = str(channel.get("name") or render_thread_title(project.label, task["task"], worktree))
    record["worktree"] = worktree
    record.pop("create_intent", None)
    card = render_card(project, task["task"], worktree, worktree_branch(task["worktree"]) if task["worktree"] else "", state_name)
    card_message_id = str(record.get("card_message_id") or "")
    if card_message_id:
        transport.edit_card(env, thread_id, card_message_id, card)
    else:
        card_message_id = transport.post_message(env, thread_id, card)
    record["card_message_id"] = card_message_id
    record["card_sha256"] = fwl.sha256_text(card)
    record["state"] = state_name
    record["state_tag"] = cfg.state_tags[state_name]
    tag_ids, missing = transport.resolve_tag_ids(env, [cfg.session_tag, cfg.worktree_tag, cfg.state_tags[state_name]])
    if missing:
        print(f"warning: forum lacks tag(s) {', '.join(missing)}; the session is bound without them")
    else:
        record["applied_tag_ids"] = tag_ids
        if transport.reads_channels():
            if sorted(str(x) for x in (channel.get("applied_tags") or [])) != sorted(tag_ids):
                transport.set_thread_tags(env, thread_id, tag_ids)
        elif not record.get("thread_created_with_tags"):
            print("warning: a webhook cannot re-tag an existing thread; the bound card carries the state")
    record.setdefault("transport", transport.name)
    state.save_session(task["task"], record)
    if request is not None:
        request["task"] = task["task"]
        request["bound_at"] = utc_now()
        state.save_request(request_id, request)
    print(f"task {task['task']} now bound to thread {thread_id} in project {project.key}")
    return 0


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------


def cmd_sample_config(args: argparse.Namespace, env: Env) -> int:
    print(json.dumps(sample_config(), indent=2, sort_keys=True))
    return 0


def cmd_config_check(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    webhooks = WebhookStore(env.home / cfg.webhook_file)
    print(f"config ok: {cfg.path}")
    print(f"secret file: {cfg.secret_file} (key {cfg.token_key})")
    print(f"webhook file: {cfg.webhook_file} ({len(webhooks.entries)} entr{'y' if len(webhooks.entries) == 1 else 'ies'}, urls never printed)")
    print(f"live posting: {'enabled' if cfg.live_posting else 'disabled'}")
    print(f"refused guilds: {len(cfg.refused_guilds)} (never read or written)")
    print("session tags: " + ", ".join([cfg.session_tag, cfg.worktree_tag, *sorted(set(cfg.state_tags.values()))]))
    print("state tags: " + ", ".join(f"{key}={cfg.state_tags[key]}" for key in REQUIRED_STATE_KEYS))
    for key in sorted(cfg.projects):
        project = cfg.projects[key]
        sessions_transport = "webhook" if webhooks.for_channel("sessions", project.sessions_forum_id) else "bot"
        artifacts_transport = "-"
        if project.artifact_forum_id:
            artifacts_transport = "webhook" if webhooks.for_channel("artifacts", project.artifact_forum_id) else "bot"
        print(
            f"project {key}: label={project.label} guild={project.guild_id} sessions={project.sessions_forum_id} "
            f"artifacts={project.artifact_forum_id or '(none)'} transports=sessions:{sessions_transport}/artifacts:{artifacts_transport} "
            f"tag_ids={len(project.tag_ids)} paths={', '.join(project.paths)}"
        )
    return 0


def add_config_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", help="non-secret Discord session mirror config JSON")


# --------------------------------------------------------------------------
# ensure: the live preconditions the configured forums must already satisfy
# --------------------------------------------------------------------------


def target_forums(cfg: MirrorConfig) -> List[Tuple[MirrorProject, str, str]]:
    """Every forum the mirror posts into, in project-key order."""
    out: List[Tuple[MirrorProject, str, str]] = []
    for key in sorted(cfg.projects):
        project = cfg.projects[key]
        if project.sessions_forum_id:
            out.append((project, "sessions", project.sessions_forum_id))
        if project.artifact_forum_id:
            out.append((project, "artifacts", project.artifact_forum_id))
    return out


def required_tag_names(cfg: MirrorConfig, project: MirrorProject, kind: str) -> List[str]:
    """The forum tag vocabulary this capability's own contract requires there.

    A sessions forum is always named. An artifacts forum may declare a tag by
    name, which is created here when the forum lacks it, or by numeric id, which
    is already the direct instruction and is verified instead.
    """
    if kind == "sessions":
        return [cfg.session_tag, cfg.worktree_tag, *sorted(set(cfg.state_tags.values()))]
    tokens: List[str] = []
    for key in sorted(project.artifact_tags):
        tag = project.artifact_tags[key]
        if tag not in tokens:
            tokens.append(tag)
    return tokens


def slugify(text: str, limit: int = 24) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", str(text).strip().lower()).strip("-")
    return slug[:limit].strip("-") or "guild"


def webhook_records(path: Path) -> List[Dict[str, Any]]:
    """The raw webhook file records, kept verbatim so a rewrite preserves them."""
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    items = raw.get("webhooks") if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        return []
    return [item for item in items if isinstance(item, dict)]


def available_tag_list(channel: Dict[str, Any]) -> List[Dict[str, str]]:
    tags: List[Dict[str, str]] = []
    for item in channel.get("available_tags") or []:
        if isinstance(item, dict) and item.get("id") and item.get("name"):
            tags.append({"id": str(item["id"]), "name": str(item["name"])})
    return tags


def cmd_ensure(args: argparse.Namespace, env: Env) -> int:
    """Reconcile the live preconditions the configured forums must satisfy.

    A webhook cannot read a channel and cannot create a tag, so the tags and the
    webhook a target forum needs cannot be established by a normal publishing
    pass. This bounded pass does that once: it creates only the tags the config
    declares and one webhook per target forum, writes the resulting non-secret
    ids back to the config, and records the exact undo of every live change.
    """
    cfg = load_config(env, args.config)
    webhook_path = env.home / cfg.webhook_file
    store = WebhookStore(webhook_path)
    live = bool(cfg.live_posting and not args.dry_run)
    plan = target_forums(cfg)
    print(f"ensure: {len(plan)} configured forum(s) across {len(cfg.projects)} project(s)")
    for project, kind, forum_id in plan:
        names = required_tag_names(cfg, project, kind)
        declared = ", ".join(names) if names else "(none declared; artifact posts stay untagged)"
        present = "present" if store.for_channel(kind, forum_id) is not None else "missing"
        print(f"  {project.key} {kind} forum {forum_id}: tags={declared} webhook={present}")
    if not live:
        reason = "dry-run" if args.dry_run else "live posting is disabled"
        print(f"{reason}: no tag, webhook, config, or Discord write was made")
        return 0
    passing = Pass(cfg, MirrorState(env), live)
    client = passing.client_for(env)
    records = webhook_records(webhook_path)
    config_changed = False
    records_changed = False
    tag_changes: List[Dict[str, Any]] = []
    webhook_changes: List[Dict[str, Any]] = []
    guild_names: Dict[str, str] = {}
    guild_slugs: Dict[str, str] = {}
    # Phase one reads every target forum and refuses the whole pass before any
    # write when one of them cannot satisfy the contract, so a refusal never
    # leaves half a reconciliation behind.
    planned: List[Dict[str, Any]] = []
    for project, kind, forum_id in plan:
        channel = client.channel(forum_id)
        if str(channel.get("guild_id") or "") != project.guild_id:
            raise FMError(
                f"forum {forum_id} belongs to guild {channel.get('guild_id')}, not the configured {project.guild_id}; refusing to touch it"
            )
        if channel.get("type") not in FORUM_TYPES:
            raise FMError(f"channel {forum_id} is not a forum channel (type {channel.get('type')}); refusing to set tags")
        existing = available_tag_list(channel)
        names = required_tag_names(cfg, project, kind)
        present_names = {tag["name"] for tag in existing}
        present_ids = {tag["id"] for tag in existing}
        absent_ids = [token for token in names if fwl.ID_RE.fullmatch(token) and token not in present_ids]
        if absent_ids:
            raise FMError(
                f"forum {forum_id} does not carry the configured tag id(s) {', '.join(absent_ids)}; refusing"
            )
        missing = [token for token in names if not fwl.ID_RE.fullmatch(token) and token not in present_names]
        if missing and len(existing) + len(missing) > TAG_CAP:
            raise FMError(
                f"forum {forum_id} would need {len(existing) + len(missing)} tags, over Discord's {TAG_CAP}-tag cap; "
                "refusing to add them - prune the forum's tag vocabulary first"
            )
        planned.append(
            {"project": project, "kind": kind, "forum_id": forum_id, "names": names, "missing": missing}
        )
    for row in planned:
        project, kind, forum_id = row["project"], row["kind"], row["forum_id"]
        names, missing = row["names"], row["missing"]
        channel = client.channel(forum_id)
        existing = available_tag_list(channel)
        if missing:
            previous = list(existing)
            client.set_channel_tags(forum_id, existing + [{"name": name} for name in missing])
            channel = client.channel(forum_id)
            existing = available_tag_list(channel)
            tag_changes.append(
                {
                    "forum_id": forum_id,
                    "project": project.key,
                    "kind": kind,
                    "names": missing,
                    "previous_available_tags": previous,
                }
            )
            print(f"  {project.key} {kind}: created tag(s) {', '.join(missing)} on forum {forum_id}")
        by_name = {tag["name"]: tag["id"] for tag in existing}
        by_id = {tag["id"]: tag["name"] for tag in existing}
        for token in names:
            if fwl.ID_RE.fullmatch(token):
                if token not in by_id:
                    raise FMError(f"forum {forum_id} no longer carries tag id {token} after the update")
            elif token not in by_name:
                raise FMError(f"forum {forum_id} still lacks tag {token} after the update")
        project_raw = cfg.raw["projects"][project.raw_key]
        if kind == "sessions":
            tag_ids = dict(project_raw.get("tag_ids") or {})
            for name in names:
                if tag_ids.get(name) != by_name[name]:
                    tag_ids[name] = by_name[name]
                    config_changed = True
            project_raw["tag_ids"] = {name: tag_ids[name] for name in sorted(tag_ids)}
        else:
            artifact_tags = dict(project_raw.get("artifact_tags") or {})
            for kind_key, tag in project.artifact_tags.items():
                resolved = tag if fwl.ID_RE.fullmatch(tag) else by_name.get(tag)
                if resolved and artifact_tags.get(kind_key) != resolved:
                    artifact_tags[kind_key] = resolved
                    config_changed = True
            project_raw["artifact_tags"] = {key: artifact_tags[key] for key in sorted(artifact_tags)}
        if store.for_channel(kind, forum_id) is not None:
            continue
        guild_name = guild_names.get(project.guild_id) or str(client.guild(project.guild_id).get("name") or project.label)
        guild_names[project.guild_id] = guild_name
        slug = guild_slugs.get(project.guild_id) or ""
        if not slug:
            slug = next(
                (
                    str(record.get("guild_slug") or "")
                    for record in records
                    if str(record.get("guild") or "") == guild_name and record.get("guild_slug")
                ),
                "",
            )
            slug = slug or slugify(guild_name)
            guild_slugs[project.guild_id] = slug
        name = truncate(f"{DEFAULT_WEBHOOK_NAME_PREFIX}-{slug}-{kind}", WEBHOOK_NAME_LIMIT)
        adopted = next(
            (
                hook
                for hook in client.guild_webhooks(project.guild_id)
                if str(hook.get("channel_id") or "") == forum_id
                and str(hook.get("name") or "") == name
                and hook.get("token")
            ),
            None,
        )
        if adopted is not None:
            webhook_id, token, created = str(adopted["id"]), str(adopted["token"]), False
        else:
            created_hook = client.create_channel_webhook(forum_id, name)
            webhook_id, token, created = str(created_hook["id"]), str(created_hook["token"]), True
        records.append(
            {
                "guild": guild_name,
                "guild_slug": slug,
                "project": project.label,
                "kind": kind,
                "channel_id": forum_id,
                "webhook_id": webhook_id,
                "url": f"{WEBHOOK_API_BASE}/webhooks/{webhook_id}/{token}",
            }
        )
        records_changed = True
        if created:
            webhook_changes.append(
                {
                    "id": webhook_id,
                    "name": name,
                    "channel_id": forum_id,
                    "kind": kind,
                    "project": project.key,
                    "guild_id": project.guild_id,
                }
            )
        print(f"  {project.key} {kind}: webhook {webhook_id} {'created' if created else 'adopted'} for forum {forum_id}")
    if not (config_changed or records_changed or tag_changes or webhook_changes):
        print("ensure: every configured forum already satisfies the mirror contract; nothing to do")
        return 0
    stamp = utc_now().replace(":", "").replace("-", "")
    backups: List[Tuple[str, str]] = []
    if config_changed:
        backup = cfg.path.with_name(f"{cfg.path.name}.pre-ensure-{stamp}")
        shutil.copy2(cfg.path, backup)
        os.chmod(backup, 0o600)
        backups.append((str(backup), str(cfg.path)))
        fwl.atomic_json(cfg.path, cfg.raw, mode=0o600)
    if records_changed:
        if webhook_path.exists():
            backup = webhook_path.with_name(f"{webhook_path.name}.pre-ensure-{stamp}")
            shutil.copy2(webhook_path, backup)
            os.chmod(backup, 0o600)
            backups.append((str(backup), str(webhook_path)))
        fwl.atomic_json(webhook_path, {"webhooks": records}, mode=0o600)
    undo: List[str] = []
    for change in tag_changes:
        undo.append(
            "Discord REST PATCH /channels/"
            + change["forum_id"]
            + " with available_tags="
            + json.dumps(change["previous_available_tags"], ensure_ascii=False)
            + f"  (restores the pre-run tag vocabulary of {change['project']} {change['kind']})"
        )
    for change in webhook_changes:
        undo.append(f"Discord REST DELETE /webhooks/{change['id']}  (removes the webhook this run created)")
    for backup, original in backups:
        undo.append(f"cp {backup} {original}  (restores the pre-run non-secret config)")
    record = {
        "schema": ENSURE_SCHEMA,
        "at": utc_now(),
        "config": str(cfg.path),
        "webhook_file": cfg.webhook_file,
        "tags_created": tag_changes,
        "webhooks_created": webhook_changes,
        "backups": [backup for backup, _ in backups],
        "undo": undo,
    }
    journal = mirror_state_path(env, "ensure") / f"{fwl.sha256_text(stamp + str(cfg.path))[:16]}.json"
    fwl.atomic_json(journal, record, mode=0o600)
    print(
        f"ensure: {sum(len(change['names']) for change in tag_changes)} tag(s) created, "
        f"{len(webhook_changes)} webhook(s) created; undo recorded in {journal}"
    )
    for line in undo:
        print(f"  undo: {line}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-discord-session-mirror.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("sample-config")
    p.set_defaults(func=cmd_sample_config)
    p = sub.add_parser("config-check")
    add_config_argument(p)
    p.set_defaults(func=cmd_config_check)
    p = sub.add_parser("report")
    add_config_argument(p)
    p.add_argument("--task", action="append")
    p.set_defaults(func=cmd_report)
    p = sub.add_parser("ensure")
    add_config_argument(p)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_ensure)
    p = sub.add_parser("sync")
    add_config_argument(p)
    p.add_argument("--task", action="append")
    p.add_argument("--transport", choices=TRANSPORT_CHOICES, default="auto")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_sync)
    p = sub.add_parser("artifact")
    add_config_argument(p)
    p.add_argument("--task", required=True)
    p.add_argument("--kind", required=True, choices=ARTIFACT_KINDS)
    p.add_argument("--title", required=True)
    p.add_argument("--body-file", required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_artifact)
    p = sub.add_parser("request")
    add_config_argument(p)
    p.add_argument("--thread", required=True)
    p.add_argument("--text-file")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_request)
    p = sub.add_parser("bind")
    add_config_argument(p)
    p.add_argument("--thread", required=True)
    p.add_argument("--task", required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_bind)
    return parser


def main(argv: List[str]) -> int:
    if len(argv) < 3:
        print("usage: fm_discord_session_mirror_lib.py <script-dir> <command> ...", file=sys.stderr)
        return 2
    parser = build_parser()
    args = parser.parse_args(argv[2:])
    try:
        env = Env(argv[1])
        return int(args.func(args, env))
    except BrokenPipeError:
        # Before ERRTYPES: BrokenPipeError is an OSError, and a closed reader
        # must stay silent rather than print a spurious failure line.
        return 1
    except ERRTYPES as exc:
        print(f"fm-discord-session-mirror: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
