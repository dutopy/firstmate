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
    artifact [--config <json>] --task <id> --kind <report|patch|pr> --title <t> --body-file <f> [--dry-run]
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
import subprocess
import sys
import tempfile
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
# thing. Catch both so a live refusal prints one bounded line, never a traceback.
ERRTYPES = (FMError, fdl.FMError)
Env = fwl.Env
die = fwl.die

CONFIG_SCHEMA = "fm-discord-session-mirror.config.v1"
SESSION_SCHEMA = "fm-discord-session-mirror.session.v1"
REQUEST_SCHEMA = "fm-discord-session-mirror.request.v1"
ARTIFACT_SCHEMA = "fm-discord-session-mirror.artifact.v1"

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
ARTIFACT_KINDS = ("report", "patch", "pr")

TITLE_LIMIT = 100
BODY_LIMIT = 2000
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


class MirrorProject:
    def __init__(self, key: str, raw: Dict[str, Any], seen_ids: Dict[str, str]) -> None:
        self.key = key
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
                    raise FMError(f"{prefix}.artifact_tags has an unsupported kind: {kind}")
            for kind, tag in raw_tags.items():
                self.artifact_tags[kind] = validate_tag_name(tag, f"{prefix}.artifact_tags.{kind}")
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
        self.state_tags = validate_state_tag_map(raw.get("state_tags"))
        self.session_tag = validate_tag_name(raw.get("session_tag", DEFAULT_SESSION_TAG), "session_tag")
        self.worktree_tag = validate_tag_name(raw.get("worktree_tag", DEFAULT_WORKTREE_TAG), "worktree_tag")
        bounds = raw.get("bounds", {})
        if not isinstance(bounds, dict):
            raise FMError("bounds must be a JSON object")
        self.max_tasks_per_pass = validate_positive_int(bounds.get("max_tasks_per_pass", MAX_TASKS_DEFAULT), "bounds.max_tasks_per_pass", 500)
        self.max_thread_listing = validate_positive_int(bounds.get("max_thread_listing", MAX_BOUND_DEFAULT), "bounds.max_thread_listing", 1000)
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
            self.projects[normalized] = MirrorProject(normalized, value, seen_ids)

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
    return "\n".join(lines)


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
        self._tag_cache: Dict[str, List[Dict[str, str]]] = {}

    def note(self, line: str) -> None:
        self.lines.append(line)

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

    def resolve_tags(self, env: Env, forum_id: str, wanted: List[str]) -> Tuple[List[str], List[str]]:
        """Map wanted tag names to ids using the forum's live tag vocabulary."""
        available = self.available_tags(env, forum_id)
        by_name = {tag["name"]: tag["id"] for tag in available}
        ids: List[str] = []
        missing: List[str] = []
        for name in wanted:
            if name in by_name:
                if by_name[name] not in ids:
                    ids.append(by_name[name])
            else:
                missing.append(name)
        return ids, missing

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
            sync_task(passing, cfg, env, state, task)
        except ERRTYPES as exc:
            # One task's failure never hides the rest of the pass, and it never
            # looks like success: the reasons are printed and the pass exits 1.
            message = passing.client.redact(str(exc)) if passing.client is not None else str(exc)
            passing.failures += 1
            passing.note(f"{task['task']}: error: {message}")
    for line in passing.lines:
        print(line)
    print(
        f"mirror pass complete: live={'yes' if live else 'no'} tasks={len(tasks)} "
        f"failed={passing.failures} api_calls={passing.client.calls if passing.client else 0}"
    )
    return 1 if passing.failures else 0


def sync_task(passing: Pass, cfg: MirrorConfig, env: Env, state: MirrorState, task: Dict[str, str]) -> None:
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
    if record is not None and record.get("project") != project.key:
        passing.note(f"{task_id}: skipped, recorded thread belongs to project {record.get('project')} but the task now reports {project.key}")
        return
    if record is None:
        record = {
            "schema": SESSION_SCHEMA,
            "task": task_id,
            "project": project.key,
            "guild_id": project.guild_id,
            "forum_id": project.sessions_forum_id,
            "thread_id": "",
            "thread_name": title,
            "created_thread": False,
            "card_message_id": "",
            "worktree": worktree,
            "registered_at": utc_now(),
        }
    if not record.get("thread_id"):
        if not passing.live:
            passing.note(f"{task_id}: would create thread '{title}' in forum {project.sessions_forum_id}")
            return
        existing = passing.forum_threads(env, project, project.sessions_forum_id).get(title)
        if existing is not None:
            record["thread_id"] = str(existing.get("id") or "")
            record["created_thread"] = False
            record["card_message_id"] = record["thread_id"]
            record["applied_tag_ids"] = [str(tag) for tag in (existing.get("applied_tags") or [])]
            try:
                starter = passing.client_for(env).starter_message(record["thread_id"])
                record["card_sha256"] = fwl.sha256_text(str(starter.get("content") or ""))
            except FMError:
                # A missing or unreadable starter message only means the card is
                # rewritten on this pass; it never authorizes a second thread.
                record.pop("card_sha256", None)
            passing.note(f"{task_id}: adopted existing thread {record['thread_id']} by exact title")
        else:
            card = render_card(project, task_id, worktree, worktree_branch(task["worktree"]), state_name)
            tag_ids, missing = passing.resolve_tags(env, project.sessions_forum_id, [cfg.session_tag, cfg.worktree_tag, state_tag])
            if missing:
                passing.note(f"{task_id}: skipped, forum {project.sessions_forum_id} lacks tag(s): {', '.join(missing)}")
                return
            created = passing.client_for(env).create_forum_thread(project.sessions_forum_id, title, card, tag_ids)
            record["thread_id"] = str(created["id"])
            record["created_thread"] = True
            record["card_message_id"] = record["thread_id"]
            record["card_sha256"] = fwl.sha256_text(card)
            record["applied_tag_ids"] = tag_ids
            record["state"] = state_name
            record["state_tag"] = state_tag
            passing.note(f"{task_id}: created thread {record['thread_id']} ({title})")
    if not passing.live:
        passing.note(f"{task_id}: would reconcile state={state_name} tag={state_tag} (thread {record.get('thread_id') or 'none'})")
        return
    worktree = record.get("worktree") or worktree
    tag_ids, missing = passing.resolve_tags(env, project.sessions_forum_id, [cfg.session_tag, cfg.worktree_tag, state_tag])
    if missing:
        passing.note(f"{task_id}: state tag not reconciled, forum lacks tag(s): {', '.join(missing)}")
    elif sorted(str(x) for x in (record.get("applied_tag_ids") or [])) != sorted(tag_ids):
        passing.client_for(env).set_thread_tags(record["thread_id"], tag_ids)
        record["applied_tag_ids"] = tag_ids
        passing.note(f"{task_id}: tags now {cfg.session_tag}, {cfg.worktree_tag}, {state_tag}")
    card = render_card(project, task_id, worktree, worktree_branch(task["worktree"]), state_name)
    card_digest = fwl.sha256_text(card)
    card_message_id = str(record.get("card_message_id") or "")
    if not card_message_id:
        posted = passing.client_for(env).post_message(record["thread_id"], card)
        record["card_message_id"] = str(posted["id"])
        record["card_sha256"] = card_digest
        passing.note(f"{task_id}: session card posted in {record['thread_id']}")
    elif record.get("card_sha256") != card_digest:
        passing.client_for(env).edit_message(record["thread_id"], card_message_id, card)
        record["card_sha256"] = card_digest
        passing.note(f"{task_id}: session card updated in place in {record['thread_id']}")
    record["schema"] = SESSION_SCHEMA
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
    for key in sorted(cfg.projects):
        project = cfg.projects[key]
        artifact = project.artifact_forum_id or "(none configured)"
        print(f"- {key}: guild {project.guild_id} sessions {project.sessions_forum_id} artifacts {artifact} paths {', '.join(project.paths)}")
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
    client = passing.client_for(env)
    if record is None:
        existing = passing.forum_threads(env, project, project.artifact_forum_id).get(thread_title)
        if existing is not None:
            thread_id = str(existing.get("id") or "")
            created = False
        else:
            wanted = [artifact_tag] if artifact_tag else []
            tag_ids, missing = passing.resolve_tags(env, project.artifact_forum_id, wanted)
            if missing:
                raise FMError(f"artifact forum {project.artifact_forum_id} lacks tag(s): {', '.join(missing)}")
            posted = client.create_forum_thread(project.artifact_forum_id, thread_title, f"**{title}**\n\n{body}", tag_ids)
            thread_id = str(posted["id"])
            created = True
        record = {
            "schema": ARTIFACT_SCHEMA,
            "task": task["task"],
            "project": project.key,
            "kind": kind,
            "title": title,
            "guild_id": project.guild_id,
            "forum_id": project.artifact_forum_id,
            "thread_id": thread_id,
            "thread_name": thread_title,
            "created_thread": created,
            "body_sha256": fwl.sha256_text(body),
            "nonce": nonce,
            "created_at": utc_now(),
        }
        state.save_artifact(nonce_digest, record)
        print(f"artifact thread {thread_id} recorded ({'created' if created else 'adopted'})")
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
    message = client.post_message(session["thread_id"], f"Artefact ({kind}) : {title}\nhttps://discord.com/channels/{project.guild_id}/{thread_id}")
    record["link_message_id"] = str(message["id"])
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
    channel = client.thread(thread_id)
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
    client = passing.client_for(env)
    channel = client.thread(thread_id)
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
    card = render_card(project, task["task"], worktree, worktree_branch(task["worktree"]) if task["worktree"] else "", state_name)
    card_message_id = str(record.get("card_message_id") or "")
    if card_message_id:
        client.edit_message(thread_id, card_message_id, card)
    else:
        posted = client.post_message(thread_id, card)
        card_message_id = str(posted["id"])
    record["card_message_id"] = card_message_id
    record["card_sha256"] = fwl.sha256_text(card)
    record["state"] = state_name
    record["state_tag"] = cfg.state_tags[state_name]
    tag_ids, missing = passing.resolve_tags(env, project.sessions_forum_id, [cfg.session_tag, cfg.worktree_tag, cfg.state_tags[state_name]])
    if missing:
        print(f"warning: forum lacks tag(s) {', '.join(missing)}; the session is bound without them")
    else:
        record["applied_tag_ids"] = tag_ids
        if sorted(str(x) for x in (channel.get("applied_tags") or [])) != sorted(tag_ids):
            client.set_thread_tags(thread_id, tag_ids)
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
    print(f"config ok: {cfg.path}")
    print(f"secret file: {cfg.secret_file} (key {cfg.token_key})")
    print(f"live posting: {'enabled' if cfg.live_posting else 'disabled'}")
    print("session tags: " + ", ".join([cfg.session_tag, cfg.worktree_tag, *sorted(set(cfg.state_tags.values()))]))
    print("state tags: " + ", ".join(f"{key}={cfg.state_tags[key]}" for key in REQUIRED_STATE_KEYS))
    for key in sorted(cfg.projects):
        project = cfg.projects[key]
        print(f"project {key}: label={project.label} guild={project.guild_id} sessions={project.sessions_forum_id} artifacts={project.artifact_forum_id or '(none)'} paths={', '.join(project.paths)}")
    return 0


def add_config_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", help="non-secret Discord session mirror config JSON")


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
    p = sub.add_parser("sync")
    add_config_argument(p)
    p.add_argument("--task", action="append")
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
    env = Env(argv[1])
    parser = build_parser()
    args = parser.parse_args(argv[2:])
    try:
        return int(args.func(args, env))
    except ERRTYPES as exc:
        print(f"fm-discord-session-mirror: {exc}", file=sys.stderr)
        return 1
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
