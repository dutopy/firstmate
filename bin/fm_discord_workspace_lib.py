#!/usr/bin/env python3
"""Offline support code for Firstmate's private Discord operations workspace.

The shell entrypoints are the public interface.
This module contains the shared parsing and planning logic so the outbound owner and process-event adapter enforce the same non-secret config contract.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import mimetypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlparse

SCHEMA = "fm-discord-workspace.config.v1"
EVENT_SCHEMA = "fm-discord-workspace-event.v1"
RECEIPT_SCHEMA = "fm-discord-workspace-receipt.v1"
REQUEST_SCHEMA = "fm-discord-workspace-request.v1"
TASK_LINK_SCHEMA = "fm-discord-workspace-task-link.v1"
PENDING_SCHEMA = "fm-discord-workspace-pending-followup.v1"
ARTIFACT_SCHEMA = "fm-discord-workspace-artifact.v1"
ARTIFACT_INDEX_SCHEMA = "fm-discord-workspace-artifact-source-index.v1"

ACTIVE_PROFILE_KEYS = ["proapplis", "folium", "arfal"]
ACTIVE_PROFILE_LABELS = {
    "proapplis": "ProApplis",
    "folium": "Folium",
    "arfal": "ARFAL",
}
DISABLED_PROFILE_KEYS = ["lbdb", "maratone-labs"]
DEFAULT_EXCHANGE_TAGS = ["request", "decision", "work", "status", "blocked", "done"]
DEFAULT_ARTIFACT_TAGS = ["report", "board", "document", "image", "audio", "draft", "final", "expired"]
DEFAULT_CDN_HOSTS = ["cdn.discordapp.com", "media.discordapp.net", "media.discordapp.com"]
VOICE_MESSAGE_FLAG = 1 << 13
STEADY_PERMISSION = 101376
STEADY_THREADS_PERMISSION = 274878008320
SETUP_PERMISSION = 268536848
SETUP_THREADS_PERMISSION = 275146443792
DIRECT_ATTACHMENT_MAX = 8 * 1024 * 1024
AUDIO_MAX_BYTES = 25 * 1024 * 1024
AUDIO_MAX_DURATION_SECS = 600
DISCORD_SOURCE_ID = "discord-workspace"

ID_RE = re.compile(r"^[0-9]{5,32}$")
PROFILE_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
TASK_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ -]{0,49}$")
SOURCE_RE = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
REQUEST_RE = re.compile(r"^discord:([0-9]{5,32}):([0-9]{5,32}):([0-9]{5,32})$")
SECRETISH_RE = re.compile(
    r"(^|[._-])(env|secret|secrets|token|tokens|key|keys|credential|credentials|cookie|cookies|cert|certificate|private)([._-]|$)",
    re.IGNORECASE,
)
BLOCKED_EXTENSIONS = {
    ".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".7z", ".rar", ".zst",
    ".sqlite", ".sqlite3", ".db", ".dump", ".sql", ".log", ".har", ".pem",
    ".p12", ".pfx", ".key", ".crt", ".cer",
}
ALLOWED_TEXT_EXTENSIONS = {".md", ".markdown", ".txt"}
ALLOWED_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp"}
ALLOWED_DOCUMENT_EXTENSIONS = {".pdf"}
ALLOWED_DIRECT_EXTENSIONS = ALLOWED_TEXT_EXTENSIONS | ALLOWED_IMAGE_EXTENSIONS | ALLOWED_DOCUMENT_EXTENSIONS
ALLOWED_AUDIO_MIME_PREFIXES = ("audio/",)
ALLOWED_AUDIO_EXTENSIONS = {".wav", ".ogg", ".opus", ".mp3", ".m4a", ".flac", ".webm"}
EXIT_NO_RESULT = 75


class FMError(Exception):
    """A user-facing refusal that should not show a traceback."""


class Env:
    def __init__(self, script_dir: str):
        self.script_dir = Path(script_dir).resolve()
        self.root = self.script_dir.parent
        self.home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or self.root).resolve()
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE") or self.home / "state").resolve()
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE") or self.home / "data").resolve()
        self.config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or self.home / "config").resolve()

    @property
    def default_config(self) -> Path:
        return self.config / "discord-workspace.json"

    @property
    def discord_state(self) -> Path:
        return self.state / "discord-workspace"

    @property
    def inbox(self) -> Path:
        return self.state / "inbox"


def die(message: str, code: int = 1) -> None:
    print(f"fm-discord-workspace: {message}", file=sys.stderr)
    raise SystemExit(code)


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_digest_path(root: Path, digest_input: str, suffix: str = ".json") -> Path:
    return root / f"{sha256_text(digest_input)}{suffix}"


def atomic_json(path: Path, data: Dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def read_json(path: Path) -> Dict[str, Any]:
    if not path.exists():
        raise FMError(f"config file is missing: {path}")
    if path.is_symlink() or not path.is_file():
        raise FMError(f"refusing unsafe config path: {path}")
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        raise FMError(f"config is not valid JSON: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise FMError("config root must be a JSON object")
    return data


def json_load_file(path: Path) -> Any:
    if path.is_symlink() or not path.is_file():
        raise FMError(f"refusing unsafe JSON path: {path}")
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def as_list(value: Any, field: str) -> List[Any]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise FMError(f"{field} must be a list")
    return value


def validate_snowflake(value: Any, field: str, *, required: bool = True) -> Optional[str]:
    if value is None or value == "":
        if required:
            raise FMError(f"{field} is required")
        return None
    if not isinstance(value, str):
        raise FMError(f"{field} must be a string Discord id")
    if not ID_RE.fullmatch(value):
        raise FMError(f"{field} must be a decimal Discord id")
    return value


def validate_bool(value: Any, field: str, *, default: bool = False) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        raise FMError(f"{field} must be true or false")
    return value


def bool_from_path(obj: Dict[str, Any], names: Iterable[str], default: bool = False) -> bool:
    for name in names:
        cur: Any = obj
        ok = True
        for part in name.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                ok = False
                break
        if ok:
            return validate_bool(cur, name, default=default)
    return default


def validate_tags(raw: Any, default: List[str], field: str) -> List[str]:
    values = default if raw is None else as_list(raw, field)
    out: List[str] = []
    seen: set[str] = set()
    for item in values:
        if not isinstance(item, str) or not TAG_RE.fullmatch(item):
            raise FMError(f"{field} contains an invalid forum tag")
        key = item.lower()
        if key in seen:
            raise FMError(f"{field} contains duplicate forum tag: {item}")
        seen.add(key)
        out.append(item)
    if not out:
        raise FMError(f"{field} must contain at least one forum tag")
    return out


def normalize_profile_key(key: str) -> str:
    lowered = key.strip().lower().replace("_", "-").replace(" ", "-")
    aliases = {
        "pro-applis": "proapplis",
        "maratone": "maratone-labs",
        "maratone-labs": "maratone-labs",
    }
    return aliases.get(lowered, lowered)


def extract_profile(raw_profiles: Dict[str, Any], key: str) -> Dict[str, Any]:
    for raw_key, value in raw_profiles.items():
        if normalize_profile_key(raw_key) == key:
            if not isinstance(value, dict):
                raise FMError(f"profiles.{raw_key} must be an object")
            return value
    return {}


def thread_ids_for(profile: Dict[str, Any], kind: str, field_prefix: str) -> List[str]:
    raw = None
    threads = profile.get("thread_ids")
    if isinstance(threads, dict) and kind in threads:
        raw = threads[kind]
    if raw is None:
        raw = profile.get(f"{kind}_thread_ids")
    out: List[str] = []
    seen: set[str] = set()
    for item in as_list(raw, f"{field_prefix}.thread_ids.{kind}"):
        sid = validate_snowflake(item, f"{field_prefix}.thread_ids.{kind}[]")
        assert sid is not None
        if sid in seen:
            raise FMError(f"{field_prefix}.thread_ids.{kind} has duplicate thread id: {sid}")
        seen.add(sid)
        out.append(sid)
    return out


def maybe_id(profile: Dict[str, Any], *names: str) -> Any:
    for name in names:
        if name in profile:
            return profile[name]
    return None


INLINE_SECRET_KEYS = {"token", "bot_token", "discord_bot_token", "groq_api_key", "api_key_value", "secret", "password", "client_secret"}


def reject_inline_secret_values(value: Any, path: str = "config") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            lowered = key_text.lower().replace("-", "_")
            if lowered in INLINE_SECRET_KEYS:
                raise FMError(f"{path}.{key_text} appears to contain an inline secret; store only secret file paths and key names")
            reject_inline_secret_values(child, f"{path}.{key_text}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_inline_secret_values(child, f"{path}[{index}]")


def config_secret_references(cfg: Dict[str, Any]) -> List[str]:
    refs: List[str] = []
    tx = cfg.get("transcription") if isinstance(cfg.get("transcription"), dict) else {}
    secret_file = cfg.get("secret_file") or cfg.get("secrets_file") or tx.get("secret_file") or tx.get("secrets_file")
    if isinstance(secret_file, str) and secret_file:
        refs.append(f"secret file: {secret_file}")
    token_key = cfg.get("discord_bot_token_key") or tx.get("discord_bot_token_key")
    if isinstance(token_key, str) and token_key:
        refs.append(f"Discord bot token key: {token_key}")
    api_key = tx.get("api_key") or tx.get("api_key_name")
    if isinstance(api_key, str) and api_key:
        refs.append(f"transcription key name: {api_key}")
    return refs


class WorkspaceConfig:
    def __init__(self, path: Path, raw: Dict[str, Any]):
        self.path = path
        self.raw = raw
        reject_inline_secret_values(raw)
        schema = raw.get("schema", SCHEMA)
        if schema != SCHEMA:
            raise FMError(f"unsupported config schema: {schema}")
        guild_obj = raw.get("guild") if isinstance(raw.get("guild"), dict) else {}
        bot_obj = raw.get("bot") if isinstance(raw.get("bot"), dict) else {}
        self.guild_id = validate_snowflake(raw.get("guild_id") or guild_obj.get("id"), "guild.id") or ""
        self.bot_application_id = validate_snowflake(
            raw.get("bot_application_id") or bot_obj.get("application_id"),
            "bot.application_id",
        ) or ""
        self.bot_user_id = validate_snowflake(raw.get("bot_user_id") or bot_obj.get("user_id"), "bot.user_id") or ""
        self.captain_user_ids = []
        for user_id in as_list(raw.get("captain_user_ids"), "captain_user_ids"):
            sid = validate_snowflake(user_id, "captain_user_ids[]")
            assert sid is not None
            if sid == self.bot_user_id:
                raise FMError("captain_user_ids must not include the bot user id")
            self.captain_user_ids.append(sid)
        if not self.captain_user_ids:
            raise FMError("captain_user_ids must contain at least one captain Discord user id")
        disabled = raw.get("disabled_profiles", DISABLED_PROFILE_KEYS)
        self.disabled_profiles = [normalize_profile_key(str(x)) for x in as_list(disabled, "disabled_profiles")]
        missing_disabled = [p for p in DISABLED_PROFILE_KEYS if p not in self.disabled_profiles]
        if missing_disabled:
            raise FMError(f"disabled_profiles must include dormant profile(s): {', '.join(missing_disabled)}")
        tags_obj = raw.get("tags") if isinstance(raw.get("tags"), dict) else {}
        self.exchange_tags = validate_tags(tags_obj.get("exchange"), DEFAULT_EXCHANGE_TAGS, "tags.exchange")
        self.artifact_tags = validate_tags(tags_obj.get("artifacts", tags_obj.get("artifact")), DEFAULT_ARTIFACT_TAGS, "tags.artifacts")
        self.profiles: Dict[str, Dict[str, Any]] = {}
        raw_profiles = raw.get("profiles")
        if not isinstance(raw_profiles, dict):
            raise FMError("profiles must be an object")
        seen_ids: Dict[str, str] = {}
        for key in ACTIVE_PROFILE_KEYS:
            p = extract_profile(raw_profiles, key)
            if not p:
                raise FMError(f"profiles.{key} is required")
            if not validate_bool(p.get("enabled", True), f"profiles.{key}.enabled", default=True):
                raise FMError(f"profiles.{key} must be enabled for this phase")
            category_id = validate_snowflake(p.get("category_id"), f"profiles.{key}.category_id") or ""
            exchange_forum_id = validate_snowflake(
                maybe_id(p, "exchange_forum_id", "exchanges_forum_id"),
                f"profiles.{key}.exchange_forum_id",
            ) or ""
            artifact_forum_id = validate_snowflake(
                maybe_id(p, "artifact_forum_id", "artifacts_forum_id"),
                f"profiles.{key}.artifact_forum_id",
            ) or ""
            for field_name, sid in [
                ("category_id", category_id),
                ("exchange_forum_id", exchange_forum_id),
                ("artifact_forum_id", artifact_forum_id),
            ]:
                owner = seen_ids.get(sid)
                if owner:
                    raise FMError(f"duplicate Discord id {sid} appears in {owner} and profiles.{key}.{field_name}")
                seen_ids[sid] = f"profiles.{key}.{field_name}"
            label = p.get("label") if isinstance(p.get("label"), str) else ACTIVE_PROFILE_LABELS[key]
            exchange_threads = thread_ids_for(p, "exchange", f"profiles.{key}")
            artifact_threads = thread_ids_for(p, "artifacts", f"profiles.{key}")
            artifact_threads += [x for x in thread_ids_for(p, "artifact", f"profiles.{key}") if x not in artifact_threads]
            for tid in exchange_threads:
                owner = seen_ids.get(tid)
                if owner:
                    raise FMError(f"duplicate Discord id {tid} appears in {owner} and profiles.{key}.thread_ids.exchange")
                seen_ids[tid] = f"profiles.{key}.thread_ids.exchange"
            for tid in artifact_threads:
                owner = seen_ids.get(tid)
                if owner:
                    raise FMError(f"duplicate Discord id {tid} appears in {owner} and profiles.{key}.thread_ids.artifacts")
                seen_ids[tid] = f"profiles.{key}.thread_ids.artifacts"
            self.profiles[key] = {
                "key": key,
                "label": label,
                "category_id": category_id,
                "exchange_forum_id": exchange_forum_id,
                "artifact_forum_id": artifact_forum_id,
                "exchange_thread_ids": exchange_threads,
                "artifact_thread_ids": artifact_threads,
                "category_name": p.get("category_name") or label,
                "exchange_forum_name": p.get("exchange_forum_name") or f"{key}-exchanges",
                "artifact_forum_name": p.get("artifact_forum_name") or f"{key}-artifacts",
            }
        for disabled_key in DISABLED_PROFILE_KEYS:
            p = extract_profile(raw_profiles, disabled_key)
            if not p:
                continue
            enabled = validate_bool(p.get("enabled", False), f"profiles.{disabled_key}.enabled", default=False)
            channelish = [name for name in ("category_id", "exchange_forum_id", "artifact_forum_id", "artifacts_forum_id") if p.get(name)]
            if enabled or channelish:
                raise FMError(f"disabled profile {disabled_key} must not be enabled or carry channel ids")
        approvals = raw.get("approvals") if isinstance(raw.get("approvals"), dict) else {}
        live = raw.get("live") if isinstance(raw.get("live"), dict) else {}
        self.message_content_enabled = bool_from_path(raw, ["message_content", "message_content_intent", "approvals.message_content", "live.message_content"], False)
        self.live_posting_enabled = bool_from_path(raw, ["live_posting", "approvals.live_posting", "outbound.live_posting", "live.posting"], False)
        self.live_polling_enabled = bool_from_path(raw, ["live_polling", "approvals.live_polling", "live.polling"], False)
        self.temporary_setup_permissions = bool_from_path(raw, ["temporary_setup_permissions", "approvals.temporary_setup_permissions", "live.temporary_setup_permissions"], False)
        self.community_mode_required = bool_from_path(raw, ["community_mode_required", "approvals.community_mode_required", "live.community_mode_required"], False)
        self.host_choice = str(raw.get("host") or live.get("host") or approvals.get("host") or "disabled")
        outbound = raw.get("outbound") if isinstance(raw.get("outbound"), dict) else {}
        self.final_replies_required = validate_bool(outbound.get("final_replies_required", True), "outbound.final_replies_required", default=True)
        artifacts = raw.get("artifacts") if isinstance(raw.get("artifacts"), dict) else {}
        self.artifact_access = str(artifacts.get("access") or artifacts.get("access_mode") or "disabled")
        self.artifact_default_expiry = str(artifacts.get("default_expiry") or "7d")
        self.client_confidential_allowed = validate_bool(artifacts.get("client_confidential_allowed", False), "artifacts.client_confidential_allowed", default=False)
        self.direct_attachment_max_bytes = int(artifacts.get("direct_attachment_max_bytes", DIRECT_ATTACHMENT_MAX))
        if self.direct_attachment_max_bytes <= 0 or self.direct_attachment_max_bytes > 10 * 1024 * 1024:
            raise FMError("artifacts.direct_attachment_max_bytes must be positive and no more than 10 MiB in this phase")
        allowed_roots_raw = artifacts.get("allowed_roots", ["data"])
        self.allowed_roots = [str(x) for x in as_list(allowed_roots_raw, "artifacts.allowed_roots")]
        audio = raw.get("audio") if isinstance(raw.get("audio"), dict) else {}
        self.audio_max_bytes = int(audio.get("max_bytes", AUDIO_MAX_BYTES))
        self.audio_max_duration_secs = float(audio.get("max_duration_secs", AUDIO_MAX_DURATION_SECS))
        self.audio_delete_raw = validate_bool(audio.get("delete_temporary_raw", audio.get("delete_raw", True)), "audio.delete_temporary_raw", default=True)
        self.cdn_hosts = [str(x).lower() for x in as_list(audio.get("allowed_cdn_hosts", DEFAULT_CDN_HOSTS), "audio.allowed_cdn_hosts")]
        if not self.cdn_hosts:
            raise FMError("audio.allowed_cdn_hosts must not be empty")
        transcription = raw.get("transcription") if isinstance(raw.get("transcription"), dict) else {}
        self.transcription = transcription
        self.transcription_provider = str(transcription.get("provider") or "disabled")
        self.hosted_groq_enabled = self.transcription_provider == "groq" or bool_from_path(raw, ["hosted_groq", "approvals.hosted_groq", "transcription.hosted_groq"], False)
        if self.host_choice not in ("disabled", "none", "dry-run", "omarchy", "vps"):
            raise FMError("host must be disabled, omarchy, or vps")
        if self.artifact_access not in ("disabled", "tailnet", "cloudflare-access", "local"):
            raise FMError("artifacts.access must be disabled, tailnet, cloudflare-access, or local")

    @classmethod
    def load(cls, env: Env, path_text: Optional[str]) -> "WorkspaceConfig":
        path = Path(path_text).expanduser() if path_text else env.default_config
        if not path.is_absolute():
            path = (Path.cwd() / path).resolve()
        raw = read_json(path)
        return cls(path.resolve(), raw)

    def profile_for_channel(self, channel_id: str, parent_id: Optional[str] = None, *, allow_forums: bool = False) -> Optional[Tuple[str, str, str]]:
        for key, p in self.profiles.items():
            if allow_forums and channel_id == p["exchange_forum_id"]:
                return key, "exchange", p["exchange_forum_id"]
            if allow_forums and channel_id == p["artifact_forum_id"]:
                return key, "artifact", p["artifact_forum_id"]
            if channel_id in p["exchange_thread_ids"]:
                if parent_id and parent_id != p["exchange_forum_id"]:
                    return None
                return key, "exchange", p["exchange_forum_id"]
            if channel_id in p["artifact_thread_ids"]:
                if parent_id and parent_id != p["artifact_forum_id"]:
                    return None
                return key, "artifact", p["artifact_forum_id"]
        return None

    def profile_for_request_id(self, request_id: str) -> Tuple[str, str, str, str, str]:
        match = REQUEST_RE.fullmatch(request_id)
        if not match:
            raise FMError("request id must be discord:<guild_id>:<channel_or_thread_id>:<message_id>")
        guild_id, channel_id, message_id = match.groups()
        if guild_id != self.guild_id:
            raise FMError("request id names a guild outside the configured operations guild")
        profile = self.profile_for_channel(channel_id)
        if profile is None:
            raise FMError("request id names a channel/thread outside the configured allowlist")
        profile_key, forum_kind, forum_id = profile
        return guild_id, channel_id, message_id, profile_key, forum_kind

    def thread_summary(self) -> List[str]:
        rows: List[str] = []
        for key in ACTIVE_PROFILE_KEYS:
            p = self.profiles[key]
            rows.append(f"{p['label']}: exchange threads {len(p['exchange_thread_ids'])}, artifact threads {len(p['artifact_thread_ids'])}")
        return rows


def sample_config() -> Dict[str, Any]:
    return {
        "schema": SCHEMA,
        "guild": {"id": "111111111111111111"},
        "bot": {"application_id": "222222222222222222", "user_id": "333333333333333333"},
        "captain_user_ids": ["444444444444444444"],
        "disabled_profiles": DISABLED_PROFILE_KEYS,
        "profiles": {
            "proapplis": {
                "enabled": True,
                "label": "ProApplis",
                "category_id": "555555555555555551",
                "exchange_forum_id": "555555555555555552",
                "artifact_forum_id": "555555555555555553",
                "thread_ids": {"exchange": [], "artifacts": []},
            },
            "folium": {
                "enabled": True,
                "label": "Folium",
                "category_id": "666666666666666661",
                "exchange_forum_id": "666666666666666662",
                "artifact_forum_id": "666666666666666663",
                "thread_ids": {"exchange": [], "artifacts": []},
            },
            "arfal": {
                "enabled": True,
                "label": "ARFAL",
                "category_id": "777777777777777771",
                "exchange_forum_id": "777777777777777772",
                "artifact_forum_id": "777777777777777773",
                "thread_ids": {"exchange": [], "artifacts": []},
            },
            "lbdb": {"enabled": False},
            "maratone-labs": {"enabled": False},
        },
        "tags": {"exchange": DEFAULT_EXCHANGE_TAGS, "artifacts": DEFAULT_ARTIFACT_TAGS},
        "outbound": {"final_replies_required": True, "live_posting": False},
        "artifacts": {
            "direct_attachment_max_bytes": DIRECT_ATTACHMENT_MAX,
            "allowed_roots": ["data"],
            "access": "disabled",
            "default_expiry": "7d",
            "client_confidential_allowed": False,
        },
        "audio": {
            "max_bytes": AUDIO_MAX_BYTES,
            "max_duration_secs": AUDIO_MAX_DURATION_SECS,
            "delete_temporary_raw": True,
            "allowed_cdn_hosts": DEFAULT_CDN_HOSTS,
        },
        "transcription": {
            "provider": "disabled",
            "secret_file": "config/discord-workspace.secrets.sops.yaml",
            "discord_bot_token_key": "FIRSTMATE_DISCORD_BOT_TOKEN",
            "api_key": "FIRSTMATE_DISCORD_GROQ_API_KEY",
        },
        "approvals": {
            "message_content": False,
            "temporary_setup_permissions": False,
            "hosted_groq": False,
            "community_mode_required": False,
        },
        "live": {"polling": False, "posting": False, "host": "disabled"},
    }


def load_config(env: Env, path_text: Optional[str]) -> WorkspaceConfig:
    return WorkspaceConfig.load(env, path_text)


def print_config_ok(cfg: WorkspaceConfig) -> None:
    print(f"config ok: {cfg.path}")
    print(f"guild: {cfg.guild_id}")
    print("active profiles: " + ", ".join(ACTIVE_PROFILE_KEYS))
    print("disabled profiles: " + ", ".join(DISABLED_PROFILE_KEYS))
    print("exchange forum tags: " + ", ".join(cfg.exchange_tags))
    print("artifact forum tags: " + ", ".join(cfg.artifact_tags))
    for row in cfg.thread_summary():
        print("thread allowlist: " + row)


def cmd_sample_config(args: argparse.Namespace, env: Env) -> int:
    print(json.dumps(sample_config(), indent=2, sort_keys=True))
    return 0


def cmd_config_check(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    print_config_ok(cfg)
    return 0


def setup_remaining_unapproved(cfg: WorkspaceConfig) -> List[str]:
    remaining = [
        "live Discord setup/apply is intentionally disabled in this repository phase",
        "no category, forum channel, thread, or tag will be created",
        "Discord MESSAGE_CONTENT is configured but inactive" if cfg.message_content_enabled else "Discord MESSAGE_CONTENT approval is not active",
        "host choice is unset for live service execution" if cfg.host_choice in ("disabled", "none", "dry-run") else f"host {cfg.host_choice} is configured but not activated",
        "hosted Groq transcription is configured but inactive" if cfg.hosted_groq_enabled else "hosted Groq transcription consent and limits are not active",
        "artifact access is dry-run only" if cfg.artifact_access == "disabled" else f"artifact access {cfg.artifact_access} with expiry {cfg.artifact_default_expiry} is configured but inactive",
        "temporary setup permissions are configured but unusable in this phase" if cfg.temporary_setup_permissions else "temporary setup permissions are not approved",
        "Community-mode requirement remains an operator check" if cfg.community_mode_required else "Community-mode requirement is not active",
        "live posting is configured but refused in this phase" if cfg.live_posting_enabled else "live posting is disabled",
        "live process-event polling is configured but refused in this phase" if cfg.live_polling_enabled else "live process-event polling is disabled",
    ]
    return remaining


def cmd_setup(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    if args.apply:
        raise FMError("setup --apply is not available in this offline phase; run setup --dry-run for a non-network plan")
    if not args.dry_run:
        raise FMError("setup requires --dry-run; apply mode intentionally refuses in this phase")
    print("Discord workspace setup dry-run (no network).")
    print(f"operations guild: {cfg.guild_id}")
    thread_support = any(cfg.profiles[p]["exchange_thread_ids"] or cfg.profiles[p]["artifact_thread_ids"] for p in ACTIVE_PROFILE_KEYS)
    print(f"temporary setup permission integer: {SETUP_THREADS_PERMISSION if thread_support else SETUP_PERMISSION}")
    print(f"steady-state permission integer: {STEADY_THREADS_PERMISSION if thread_support else STEADY_PERMISSION}")
    print("steady-state permissions exclude administrator, message management, webhooks, and live voice permissions.")
    for key in ACTIVE_PROFILE_KEYS:
        p = cfg.profiles[key]
        print(f"profile {p['label']} category id {p['category_id']} name {p['category_name']}")
        print(f"  exchanges forum id {p['exchange_forum_id']} name {p['exchange_forum_name']}")
        print(f"  artifacts forum id {p['artifact_forum_id']} name {p['artifact_forum_name']}")
        print(f"  exchange allowed thread ids: {', '.join(p['exchange_thread_ids']) or '(none yet)'}")
        print(f"  artifact allowed thread ids: {', '.join(p['artifact_thread_ids']) or '(none yet)'}")
    print("exchange draft tag vocabulary: " + ", ".join(cfg.exchange_tags))
    print("artifact draft tag vocabulary: " + ", ".join(cfg.artifact_tags))
    print("remaining unapproved live choices:")
    for item in setup_remaining_unapproved(cfg):
        print(f"- {item}")
    return 0


def cmd_health(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    if args.secrets:
        refs = config_secret_references(cfg.raw)
        print("secrets health dry-run only; no secret was decrypted or printed.")
        if refs:
            for ref in refs:
                print(ref)
        else:
            print("secret references are not configured.")
        raise FMError("live secret validation is disabled until activation supplies approval")
    if args.discord:
        raise FMError("live Discord health is disabled in this phase; no network call was made")
    if args.transcription:
        print("transcription health is dry-run only; fake transcription fixtures are supported for tests.")
        print("ffmpeg, sops, and age are reported but not installed or invoked for live work.")
        for tool in ("ffmpeg", "sops", "age"):
            print(f"{tool}: {'found' if shutil.which(tool) else 'not found'}")
        raise FMError("live transcription health is disabled until hosted/local transcription is approved")
    if args.process_event:
        source = env.state / "procevent" / f"{DISCORD_SOURCE_ID}.source"
        print(f"process-event source {DISCORD_SOURCE_ID}: {'registered' if source.exists() else 'not registered'}")
    print("local health ok; no network call was made.")
    print_config_ok(cfg)
    print(f"state root: {env.discord_state}")
    print("required live tools are not installed by this command.")
    return 0


def read_text_file(path_text: str, max_bytes: int = 4000) -> str:
    path = Path(path_text).expanduser()
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    if path.is_symlink() or not path.is_file():
        raise FMError(f"refusing unsafe text file: {path}")
    data = path.read_bytes()
    if len(data) > max_bytes:
        raise FMError(f"text file is too large for a Discord phase-1 message: {path}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FMError(f"text file must be UTF-8: {path}") from exc
    if "\x00" in text:
        raise FMError("text file contains a NUL byte")
    if not text.strip():
        raise FMError("text file is empty")
    if len(text) > 2000:
        raise FMError("Discord message text exceeds the 2000 character phase-1 limit")
    return text


def receipt_path(env: Env, nonce: str) -> Path:
    return safe_digest_path(env.discord_state / "receipts", nonce)


def load_existing_json(path: Path) -> Optional[Dict[str, Any]]:
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise FMError(f"refusing unsafe state path: {path}")
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise FMError(f"state file is malformed: {path}")
    return data


def record_receipt(env: Env, nonce: str, payload: Dict[str, Any], discord_message_id: str) -> str:
    path = receipt_path(env, nonce)
    existing = load_existing_json(path)
    payload = dict(payload)
    payload.update({"schema": RECEIPT_SCHEMA, "nonce": nonce, "discord_message_id": discord_message_id})
    if existing:
        comparable = dict(existing)
        comparable.pop("recorded_at", None)
        candidate = dict(payload)
        if comparable == candidate:
            return "receipt exists"
        raise FMError("refusing to overwrite a different Discord outbound receipt for the same nonce")
    payload["recorded_at"] = utc_now()
    atomic_json(path, payload)
    return "receipt recorded"


def base_receipt(kind: str, profile: str, target: Dict[str, Any], text_digest: str) -> Dict[str, Any]:
    return {
        "kind": kind,
        "profile": profile,
        "target": target,
        "text_sha256": text_digest,
        "allowed_mentions": {"parse": []},
    }


def cmd_reply(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    text = read_text_file(args.text_file)
    guild_id, channel_id, message_id, profile_key, forum_kind = cfg.profile_for_request_id(args.request_id)
    if forum_kind != "exchange":
        raise FMError("replies must target an allowlisted exchange forum thread")
    text_digest = sha256_text(text)
    nonce = args.nonce or f"reply:{args.request_id}:{text_digest}"
    target = {"guild_id": guild_id, "channel_id": channel_id, "message_id": message_id, "request_id": args.request_id}
    receipt = base_receipt("reply", profile_key, target, text_digest)
    print("Discord reply plan (no network).")
    print(f"profile: {profile_key}")
    print(f"destination thread/channel: {channel_id}")
    print(f"reply-to request: {args.request_id}")
    print(f"allowed_mentions: {json.dumps({'parse': []}, sort_keys=True)}")
    print(f"nonce: {nonce}")
    if args.record_discord_message_id:
        msg_id = validate_snowflake(args.record_discord_message_id, "--record-discord-message-id") or ""
        print(record_receipt(env, nonce, receipt, msg_id))
    else:
        print("dry-run only; no receipt was written and no Discord post was made.")
    return 0


def cmd_status(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    text = read_text_file(args.text_file)
    if args.profile not in cfg.profiles:
        raise FMError("status profile must be one of the active configured profiles")
    profile = cfg.profiles[args.profile]
    channel_id = args.thread or profile["exchange_forum_id"]
    if args.thread and args.thread not in profile["exchange_thread_ids"]:
        raise FMError("status thread is not allowlisted for the selected profile")
    text_digest = sha256_text(text)
    nonce = args.nonce or f"status:{args.profile}:{channel_id}:{text_digest}"
    target = {"guild_id": cfg.guild_id, "channel_id": channel_id}
    receipt = base_receipt("status", args.profile, target, text_digest)
    print("Discord status plan (no network).")
    print(f"profile: {args.profile}")
    print(f"destination thread/channel: {channel_id}")
    print(f"allowed_mentions: {json.dumps({'parse': []}, sort_keys=True)}")
    print(f"nonce: {nonce}")
    if args.record_discord_message_id:
        msg_id = validate_snowflake(args.record_discord_message_id, "--record-discord-message-id") or ""
        print(record_receipt(env, nonce, receipt, msg_id))
    else:
        print("dry-run only; no receipt was written and no Discord post was made.")
    return 0


def root_for_name(env: Env, name: str) -> Path:
    if name == "data":
        return env.data
    if name == "state-discord-workspace":
        return env.discord_state
    raw = Path(name)
    if raw.is_absolute():
        return raw.resolve()
    return (env.home / raw).resolve()


def path_under(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def sniff_mime(path: Path) -> str:
    ext = path.suffix.lower()
    head = path.read_bytes()[:32]
    if ext in ALLOWED_TEXT_EXTENSIONS:
        data = path.read_bytes()
        if b"\x00" in data:
            raise FMError("text artifact contains a NUL byte")
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise FMError("text artifact must be UTF-8") from exc
        return "text/markdown" if ext in {".md", ".markdown"} else "text/plain"
    if ext == ".png":
        if not head.startswith(b"\x89PNG\r\n\x1a\n"):
            raise FMError("PNG extension does not match file bytes")
        return "image/png"
    if ext in {".jpg", ".jpeg"}:
        if not head.startswith(b"\xff\xd8"):
            raise FMError("JPEG extension does not match file bytes")
        return "image/jpeg"
    if ext == ".gif":
        if not (head.startswith(b"GIF87a") or head.startswith(b"GIF89a")):
            raise FMError("GIF extension does not match file bytes")
        return "image/gif"
    if ext == ".webp":
        if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WEBP":
            raise FMError("WebP extension does not match file bytes")
        return "image/webp"
    if ext == ".pdf":
        if not head.startswith(b"%PDF-"):
            raise FMError("PDF extension does not match file bytes")
        return "application/pdf"
    guessed, _ = mimetypes.guess_type(str(path))
    raise FMError(f"unsupported artifact type: {guessed or ext or 'unknown'}")


def validate_artifact_file(env: Env, cfg: WorkspaceConfig, file_text: str, *, client_confidential: bool, approved_client_confidential: bool, require_direct: bool = False) -> Dict[str, Any]:
    path = Path(file_text).expanduser()
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    if path.is_symlink() or not path.is_file():
        raise FMError(f"refusing unsafe artifact path: {path}")
    resolved = path.resolve()
    if path_under(resolved, env.home / "projects"):
        raise FMError("artifact source under projects/ is blocked by default")
    name = resolved.name
    ext = resolved.suffix.lower()
    if SECRETISH_RE.search(name) or ext in BLOCKED_EXTENSIONS:
        raise FMError("artifact filename or extension is blocked by the default safety policy")
    roots = [root_for_name(env, item) for item in cfg.allowed_roots]
    if not any(path_under(resolved, root) for root in roots):
        raise FMError("artifact source is outside the configured allowed roots")
    if client_confidential and not (cfg.client_confidential_allowed and approved_client_confidential):
        raise FMError("client-confidential artifacts are blocked without explicit captain approval and config opt-in")
    size = resolved.stat().st_size
    mime = sniff_mime(resolved)
    if ext not in ALLOWED_DIRECT_EXTENSIONS:
        raise FMError("artifact extension is not allowed for phase-1 direct sharing")
    if require_direct and size > cfg.direct_attachment_max_bytes:
        raise FMError("artifact exceeds the direct attachment cap")
    digest = sha256_file(resolved)
    return {
        "path": str(resolved),
        "name": name,
        "extension": ext,
        "size": size,
        "mime": mime,
        "sha256": digest,
        "direct_attachment": size <= cfg.direct_attachment_max_bytes,
    }


def artifact_id_for(info: Dict[str, Any], profile: str, purpose: str) -> str:
    return sha256_text(f"artifact:{profile}:{purpose}:{info['sha256']}:{info['name']}")[:24]


def artifact_source_index_path(env: Env, source_sha256: str) -> Path:
    if not re.fullmatch(r"[0-9a-f]{64}", source_sha256):
        raise FMError("artifact source digest is invalid")
    return env.discord_state / "artifact-source-index" / f"{source_sha256}.json"


def write_artifact_source_index(env: Env, source_sha256: str, artifact_id: str, record: Dict[str, Any]) -> bool:
    path = artifact_source_index_path(env, source_sha256)
    existing = load_existing_json(path)
    if existing:
        existing_artifact = str(existing.get("artifact_id") or "")
        if existing_artifact == artifact_id:
            return False
        raise FMError(f"artifact source already has a canonical artifact record: {existing_artifact}")
    index = {
        "schema": ARTIFACT_INDEX_SCHEMA,
        "source_sha256": source_sha256,
        "artifact_id": artifact_id,
        "profile": record.get("profile"),
        "purpose": record.get("purpose"),
        "canonical_location": record.get("canonical_location"),
        "recorded_at": utc_now(),
    }
    atomic_json(path, index)
    return True


def write_artifact_record(env: Env, artifact_id: str, record: Dict[str, Any]) -> str:
    path = env.discord_state / "artifacts" / f"{artifact_id}.json"
    source = record.get("source") if isinstance(record.get("source"), dict) else {}
    source_sha256 = str(source.get("sha256") or "")
    existing = load_existing_json(path)
    if existing:
        comparable = dict(existing)
        comparable.pop("recorded_at", None)
        candidate = dict(record)
        if comparable == candidate:
            if source_sha256:
                write_artifact_source_index(env, source_sha256, artifact_id, record)
            return "artifact record exists"
        raise FMError("refusing to overwrite a different artifact record")
    created_index = False
    index_path = artifact_source_index_path(env, source_sha256) if source_sha256 else None
    if source_sha256:
        created_index = write_artifact_source_index(env, source_sha256, artifact_id, record)
    record = dict(record)
    record["recorded_at"] = utc_now()
    try:
        atomic_json(path, record)
    except Exception:
        if created_index and index_path is not None:
            try:
                index_path.unlink()
            except FileNotFoundError:
                pass
        raise
    return "artifact record written"


def cmd_artifact(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    if args.profile not in cfg.profiles:
        raise FMError("artifact profile must be one of the active configured profiles")
    if args.purpose not in cfg.artifact_tags:
        raise FMError("artifact purpose must be in the configured artifact tag vocabulary")
    info = validate_artifact_file(
        env,
        cfg,
        args.file,
        client_confidential=args.client_confidential,
        approved_client_confidential=args.captain_approved_client_confidential,
        require_direct=not bool(args.private_url),
    )
    profile = cfg.profiles[args.profile]
    if args.request_id:
        guild_id, channel_id, _message_id, profile_key, forum_kind = cfg.profile_for_request_id(args.request_id)
        if profile_key != args.profile or forum_kind != "exchange":
            raise FMError("artifact request link must name an exchange thread for the selected profile")
        exchange_channel_id = channel_id
    else:
        guild_id = cfg.guild_id
        exchange_channel_id = profile["exchange_forum_id"]
    artifact_id = artifact_id_for(info, args.profile, args.purpose)
    if args.private_url:
        args.private_url = validate_private_url(args.private_url)
    if not info["direct_attachment"] and not args.private_url:
        raise FMError("artifact exceeds the direct cap; use publish-artifact with a private expiring URL")
    target = {
        "guild_id": guild_id,
        "artifact_forum_id": profile["artifact_forum_id"],
        "exchange_channel_id": exchange_channel_id,
        "request_id": args.request_id,
    }
    nonce = args.nonce or f"artifact:{artifact_id}:{args.request_id or exchange_channel_id}"
    record = {
        "schema": ARTIFACT_SCHEMA,
        "artifact_id": artifact_id,
        "profile": args.profile,
        "purpose": args.purpose,
        "source": info,
        "target": target,
        "private_url": args.private_url,
        "canonical_location": "artifacts-forum-post",
        "exchange_behavior": "summary-card-and-link-only",
        "duplicate_binary_in_exchange": False,
    }
    print("Discord artifact publication plan (no network).")
    print(f"artifact id: {artifact_id}")
    print(f"canonical post forum: {profile['artifact_forum_id']}")
    print(f"canonical post tag: {args.purpose}")
    print(f"source file: {info['name']} {info['mime']} {info['size']} bytes sha256:{info['sha256']}")
    if info["direct_attachment"]:
        print("artifact transfer: direct attachment in the artifacts forum only")
    else:
        print("artifact transfer: private expiring link in the artifacts forum only")
    print(f"exchange summary destination: {exchange_channel_id}")
    print("exchange summary includes a card and link only; it will not duplicate the binary.")
    print(f"allowed_mentions: {json.dumps({'parse': []}, sort_keys=True)}")
    print(f"nonce: {nonce}")
    if args.record_discord_message_id:
        msg_id = validate_snowflake(args.record_discord_message_id, "--record-discord-message-id") or ""
        print(write_artifact_record(env, artifact_id, record))
        receipt = base_receipt("artifact", args.profile, target, info["sha256"])
        receipt["artifact_id"] = artifact_id
        print(record_receipt(env, nonce, receipt, msg_id))
    else:
        print("dry-run only; no artifact record or Discord receipt was written.")
    return 0


def validate_private_url(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise FMError("private artifact URL must be an https URL")
    if len(url) < 40:
        raise FMError("private artifact URL is too short to be a safe capability-style URL")
    return url


def cmd_publish_artifact(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    if args.profile not in cfg.profiles:
        raise FMError("publish-artifact profile must be active")
    if args.purpose not in cfg.artifact_tags:
        raise FMError("publish-artifact purpose must be in the configured artifact tag vocabulary")
    if args.access not in ("tailnet", "cloudflare-access", "local"):
        raise FMError("publish-artifact access must be tailnet, cloudflare-access, or local")
    if not re.fullmatch(r"[1-9][0-9]*[dh]", args.expires):
        raise FMError("publish-artifact --expires must be a duration like 7d or 24h")
    url = validate_private_url(args.url)
    info = validate_artifact_file(
        env,
        cfg,
        args.file,
        client_confidential=args.client_confidential,
        approved_client_confidential=args.captain_approved_client_confidential,
        require_direct=False,
    )
    artifact_id = artifact_id_for(info, args.profile, args.purpose)
    record = {
        "schema": ARTIFACT_SCHEMA,
        "artifact_id": artifact_id,
        "profile": args.profile,
        "purpose": args.purpose,
        "source": info,
        "publication": {"url": url, "access": args.access, "expires": args.expires},
        "canonical_location": "private-expiring-link",
    }
    print("Private artifact link plan (no network).")
    print(f"artifact id: {artifact_id}")
    print(f"access: {args.access}")
    print(f"expires: {args.expires}")
    print(f"url: {url}")
    print("revocation must be handled by the selected private publication host.")
    if args.record:
        print(write_artifact_record(env, artifact_id, record))
    else:
        print("dry-run only; no artifact record was written.")
    return 0


def request_record_path(env: Env, request_id: str) -> Path:
    return safe_digest_path(env.discord_state / "requests", request_id)


def task_link_path(env: Env, task_id: str) -> Path:
    return env.discord_state / "task-links" / f"{task_id}.json"


def pending_followup_path(env: Env, task_id: str) -> Path:
    return env.discord_state / "pending-followups" / f"{task_id}.json"


def write_same_or_refuse(path: Path, data: Dict[str, Any], label: str) -> str:
    existing = load_existing_json(path)
    if existing:
        comparable = dict(existing)
        comparable.pop("recorded_at", None)
        candidate = dict(data)
        if comparable == candidate:
            return f"{label} exists"
        raise FMError(f"refusing to overwrite a different {label}")
    data = dict(data)
    data["recorded_at"] = utc_now()
    atomic_json(path, data)
    return f"{label} written"


def cmd_link_task(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    if not TASK_ID_RE.fullmatch(args.task_id):
        raise FMError("task id must be path-safe")
    guild_id, channel_id, message_id, profile_key, forum_kind = cfg.profile_for_request_id(args.request_id)
    if forum_kind != "exchange":
        raise FMError("task links must originate from an exchange thread")
    request = {
        "schema": REQUEST_SCHEMA,
        "request_id": args.request_id,
        "guild_id": guild_id,
        "channel_id": channel_id,
        "message_id": message_id,
        "profile": profile_key,
        "origin": "discord-workspace",
    }
    link = {
        "schema": TASK_LINK_SCHEMA,
        "task_id": args.task_id,
        "request_id": args.request_id,
        "profile": profile_key,
        "final_followup_required": cfg.final_replies_required,
    }
    print(write_same_or_refuse(request_record_path(env, args.request_id), request, "request record"))
    print(write_same_or_refuse(task_link_path(env, args.task_id), link, "task link"))
    if cfg.final_replies_required:
        pending = {
            "schema": PENDING_SCHEMA,
            "task_id": args.task_id,
            "request_id": args.request_id,
            "profile": profile_key,
            "status": "pending",
        }
        print(write_same_or_refuse(pending_followup_path(env, args.task_id), pending, "pending final follow-up"))
    else:
        print("final follow-up is not required by config")
    return 0


def cmd_followup(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    if not TASK_ID_RE.fullmatch(args.task_id):
        raise FMError("task id must be path-safe")
    text = read_text_file(args.text_file)
    link = load_existing_json(task_link_path(env, args.task_id))
    if not link:
        raise FMError("task has no Discord workspace request link")
    request_id = str(link["request_id"])
    guild_id, channel_id, message_id, profile_key, forum_kind = cfg.profile_for_request_id(request_id)
    if forum_kind != "exchange":
        raise FMError("follow-up request no longer resolves to an exchange thread")
    text_digest = sha256_text(text)
    kind = "final-followup" if args.final else "followup"
    nonce = args.nonce or f"{kind}:{args.task_id}:{request_id}:{text_digest}"
    target = {"guild_id": guild_id, "channel_id": channel_id, "message_id": message_id, "request_id": request_id}
    receipt = base_receipt(kind, profile_key, target, text_digest)
    receipt["task_id"] = args.task_id
    print("Discord follow-up plan (no network).")
    print(f"task: {args.task_id}")
    print(f"request: {request_id}")
    print(f"destination thread/channel: {channel_id}")
    print(f"allowed_mentions: {json.dumps({'parse': []}, sort_keys=True)}")
    print(f"nonce: {nonce}")
    if args.final:
        pending_path = pending_followup_path(env, args.task_id)
        pending = load_existing_json(pending_path)
        if not pending:
            pending = {
                "schema": PENDING_SCHEMA,
                "task_id": args.task_id,
                "request_id": request_id,
                "profile": profile_key,
                "status": "pending",
            }
            write_same_or_refuse(pending_path, pending, "pending final follow-up")
        print("pending final follow-up: present")
    if args.record_discord_message_id:
        msg_id = validate_snowflake(args.record_discord_message_id, "--record-discord-message-id") or ""
        print(record_receipt(env, nonce, receipt, msg_id))
        if args.final:
            delivered = {
                "schema": PENDING_SCHEMA,
                "task_id": args.task_id,
                "request_id": request_id,
                "profile": profile_key,
                "status": "delivered",
                "receipt_nonce": nonce,
                "discord_message_id": msg_id,
            }
            atomic_json(pending_followup_path(env, args.task_id), delivered)
            print("pending final follow-up delivered")
    else:
        print("dry-run only; pending final follow-up remains unresolved.")
    return 0


def iter_pending_followups(env: Env) -> Iterable[Tuple[Path, Dict[str, Any]]]:
    root = env.discord_state / "pending-followups"
    if not root.exists():
        return []
    out: List[Tuple[Path, Dict[str, Any]]] = []
    for path in sorted(root.glob("*.json")):
        data = load_existing_json(path)
        if data and data.get("status") == "pending":
            out.append((path, data))
    return out


def cmd_guard_work(args: argparse.Namespace, env: Env) -> int:
    if not TASK_ID_RE.fullmatch(args.task_id):
        raise FMError("task id must be path-safe")
    path = pending_followup_path(env, args.task_id)
    if not path.exists() and not path.is_symlink():
        return 0
    data = load_existing_json(path)
    if not data:
        return 0
    if data.get("status") == "pending":
        print(f"task {args.task_id} still owes a Discord workspace final reply for {data.get('request_id')}")
        print(f"Deliver it with bin/fm-discord-workspace.sh followup {args.task_id} --final --text-file <file> after live posting is approved, or explicitly abandon the pending record after discard approval.")
        return 1
    return 0


def cmd_retire(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    pending = list(iter_pending_followups(env))
    if pending:
        print("Discord workspace retirement refused; pending final replies remain:")
        for path, item in pending:
            print(f"- task {item.get('task_id')} request {item.get('request_id')} ({path})")
        raise FMError("deliver or explicitly abandon pending final replies before retirement")
    if args.apply:
        raise FMError("retire --apply is disabled in this offline phase; use the process-event owner after live activation")
    print("Discord workspace retirement dry-run (no network).")
    print("No pending final replies are open.")
    print(f"If a local process-event source is registered later, retire it with: bin/fm-procevent.sh retire {DISCORD_SOURCE_ID}")
    print("Local Discord workspace state is preserved for audit and retry safety.")
    return 0


# ------------------------ process-event adapter ----------------------------

def parse_message_author(message: Dict[str, Any]) -> Tuple[str, bool]:
    author = message.get("author") if isinstance(message.get("author"), dict) else {}
    author_id = str(author.get("id") or message.get("author_id") or "")
    bot = bool(author.get("bot") or message.get("author_is_bot") or False)
    return author_id, bot


def external_id(guild_id: str, channel_id: str, message_id: str) -> str:
    return f"discord:{guild_id}:{channel_id}:{message_id}"


def discord_jump_url(guild_id: str, channel_id: str, message_id: str) -> str:
    return f"https://discord.com/channels/{guild_id}/{channel_id}/{message_id}"


def validate_discord_cdn_url(url: str, cfg: WorkspaceConfig) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise FMError("attachment URL is not https")
    host = parsed.hostname.lower() if parsed.hostname else ""
    if host not in cfg.cdn_hosts:
        raise FMError("attachment URL host is not in the Discord CDN allowlist")
    return url


def attachment_id(attachment: Dict[str, Any]) -> str:
    aid = attachment.get("id")
    return str(aid) if aid is not None else ""


def attachment_content_type(attachment: Dict[str, Any]) -> str:
    return str(attachment.get("content_type") or attachment.get("contentType") or "").lower()


def attachment_size(attachment: Dict[str, Any]) -> int:
    try:
        return int(attachment.get("size"))
    except (TypeError, ValueError):
        raise FMError("attachment size is missing or invalid")


def attachment_duration(attachment: Dict[str, Any], message: Dict[str, Any]) -> float:
    value = attachment.get("duration_secs")
    if value is None:
        value = attachment.get("durationSecs")
    if value is None:
        value = message.get("duration_secs")
    try:
        duration = float(value)
    except (TypeError, ValueError):
        raise FMError("audio duration is missing or invalid")
    return duration


def validate_audio_attachment(cfg: WorkspaceConfig, message: Dict[str, Any]) -> Tuple[Dict[str, Any], str]:
    attachments = as_list(message.get("attachments"), "message.attachments")
    flags = int(message.get("flags") or 0)
    voice = bool(flags & VOICE_MESSAGE_FLAG)
    audio_candidates = []
    for attachment in attachments:
        if not isinstance(attachment, dict):
            raise FMError("attachment must be an object")
        ctype = attachment_content_type(attachment)
        filename = str(attachment.get("filename") or "")
        ext = Path(filename).suffix.lower()
        if ctype.startswith(ALLOWED_AUDIO_MIME_PREFIXES) or ext in ALLOWED_AUDIO_EXTENSIONS:
            audio_candidates.append(attachment)
    if voice and len(audio_candidates) != 1:
        raise FMError("Discord voice messages must carry exactly one audio attachment")
    if not voice and len(audio_candidates) != 1:
        raise FMError("uploaded audio messages must carry exactly one supported audio attachment")
    attachment = audio_candidates[0]
    ctype = attachment_content_type(attachment)
    filename = str(attachment.get("filename") or "")
    ext = Path(filename).suffix.lower()
    if not (ctype.startswith(ALLOWED_AUDIO_MIME_PREFIXES) or ext in ALLOWED_AUDIO_EXTENSIONS):
        raise FMError("attachment is not an allowed audio type")
    size = attachment_size(attachment)
    if size <= 0 or size > cfg.audio_max_bytes:
        raise FMError("audio attachment exceeds the configured size limit")
    duration = attachment_duration(attachment, message)
    if duration <= 0 or duration > cfg.audio_max_duration_secs:
        raise FMError("audio attachment exceeds the configured duration limit")
    url = validate_discord_cdn_url(str(attachment.get("url") or ""), cfg)
    host = urlparse(url).hostname or ""
    meta = {
        "id": attachment_id(attachment),
        "filename": filename,
        "content_type": ctype,
        "size": size,
        "duration_secs": duration,
        "cdn_host": host.lower(),
        "voice_message": voice,
    }
    return meta, "voice" if voice else "audio-upload"


def fake_transcript_for(cfg: WorkspaceConfig, message: Dict[str, Any], attachment: Dict[str, Any]) -> str:
    tx = cfg.transcription
    if cfg.transcription_provider != "fake":
        raise FMError("live transcription is disabled; configure transcription.provider=fake for offline fixtures")
    fake = tx.get("fake_transcripts")
    if not isinstance(fake, dict):
        raise FMError("fake transcription requires transcription.fake_transcripts")
    keys = [str(message.get("id") or ""), attachment.get("id") or "", attachment.get("filename") or ""]
    for key in keys:
        if key and key in fake and isinstance(fake[key], str) and fake[key].strip():
            return fake[key]
    raise FMError("fake transcript fixture is missing for audio message")


def message_to_event(cfg: WorkspaceConfig, message: Dict[str, Any]) -> Dict[str, Any]:
    guild_id = str(message.get("guild_id") or "")
    channel_id = str(message.get("channel_id") or "")
    parent_id = str(message.get("parent_id") or "") if message.get("parent_id") else None
    message_id = str(message.get("id") or "")
    if not guild_id:
        return ignored_event("dm", guild_id, channel_id, message_id)
    if not ID_RE.fullmatch(message_id):
        return ignored_event("invalid-message-id", guild_id, channel_id, message_id)
    if guild_id != cfg.guild_id:
        return ignored_event("unknown-guild", guild_id, channel_id, message_id)
    profile = cfg.profile_for_channel(channel_id, parent_id)
    if profile is None:
        return ignored_event("unknown-channel-or-thread", guild_id, channel_id, message_id)
    profile_key, forum_kind, forum_id = profile
    author_id, author_is_bot = parse_message_author(message)
    if author_is_bot or author_id == cfg.bot_user_id:
        return ignored_event("bot-author", guild_id, channel_id, message_id, profile_key, forum_kind)
    if author_id not in cfg.captain_user_ids:
        return ignored_event("unknown-author", guild_id, channel_id, message_id, profile_key, forum_kind)
    content = str(message.get("content") or "").strip()
    attachments = as_list(message.get("attachments"), "message.attachments")
    has_audio = False
    try:
        flags = int(message.get("flags") or 0)
    except (TypeError, ValueError):
        flags = 0
    if flags & VOICE_MESSAGE_FLAG:
        has_audio = True
    else:
        for attachment in attachments:
            if isinstance(attachment, dict):
                ctype = attachment_content_type(attachment)
                ext = Path(str(attachment.get("filename") or "")).suffix.lower()
                if ctype.startswith(ALLOWED_AUDIO_MIME_PREFIXES) or ext in ALLOWED_AUDIO_EXTENSIONS:
                    has_audio = True
                    break
    base = {
        "schema": EVENT_SCHEMA,
        "source": DISCORD_SOURCE_ID,
        "guild_id": guild_id,
        "channel_id": channel_id,
        "message_id": message_id,
        "profile": profile_key,
        "forum_kind": forum_kind,
        "forum_channel_id": forum_id,
        "author_id": author_id,
        "external_id": external_id(guild_id, channel_id, message_id),
        "jump_url": discord_jump_url(guild_id, channel_id, message_id),
        "timestamp": str(message.get("timestamp") or ""),
    }
    if forum_kind != "exchange":
        item = dict(base)
        item.update({"kind": "ignored", "reason": "artifact-thread-input-disabled"})
        return item
    if has_audio:
        try:
            audio, audio_kind = validate_audio_attachment(cfg, message)
            transcript = fake_transcript_for(cfg, message, audio)
        except FMError as exc:
            item = dict(base)
            item.update({"kind": "audio-rejected", "reason": str(exc), "attachments": safe_attachment_metadata(attachments)})
            return item
        item = dict(base)
        item.update({
            "kind": "voice-transcript" if audio_kind == "voice" else "audio-transcript",
            "content": content,
            "audio": audio,
            "transcript": transcript,
            "transcription": {"provider": "fake", "secret_printed": False},
            "conversion_plan": {
                "tool": "ffmpeg",
                "input": "validated-discord-cdn-url",
                "output": "provider-preferred-audio",
                "delete_temporary_raw": cfg.audio_delete_raw,
            },
        })
        return item
    if not content:
        item = dict(base)
        item.update({"kind": "ignored", "reason": "empty-message"})
        return item
    item = dict(base)
    item.update({"kind": "text", "content": content, "attachments": safe_attachment_metadata(attachments)})
    return item


def safe_attachment_metadata(attachments: List[Any]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for attachment in attachments:
        if not isinstance(attachment, dict):
            continue
        out.append({
            "id": str(attachment.get("id") or ""),
            "filename": str(attachment.get("filename") or ""),
            "content_type": str(attachment.get("content_type") or ""),
            "size": attachment.get("size"),
            "duration_secs": attachment.get("duration_secs"),
        })
    return out


def ignored_event(reason: str, guild_id: str, channel_id: str, message_id: str, profile: Optional[str] = None, forum_kind: Optional[str] = None) -> Dict[str, Any]:
    item = {
        "schema": EVENT_SCHEMA,
        "source": DISCORD_SOURCE_ID,
        "kind": "ignored",
        "reason": reason,
        "guild_id": guild_id,
        "channel_id": channel_id,
        "message_id": message_id,
    }
    if profile:
        item["profile"] = profile
    if forum_kind:
        item["forum_kind"] = forum_kind
    if guild_id and channel_id and message_id:
        item["external_id"] = external_id(guild_id, channel_id, message_id)
    return item


def cursor_path(env: Env, profile: str, channel_id: str) -> Path:
    return env.discord_state / "cursors" / profile / f"{channel_id}.cursor"


def read_cursor(env: Env, profile: str, channel_id: str) -> int:
    path = cursor_path(env, profile, channel_id)
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


def write_cursor(env: Env, profile: str, channel_id: str, message_id: str) -> None:
    if not message_id.isdigit():
        return
    path = cursor_path(env, profile, channel_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".cursor.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(message_id + "\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def fixture_messages(cfg: WorkspaceConfig) -> List[Dict[str, Any]]:
    poll = cfg.raw.get("poll") if isinstance(cfg.raw.get("poll"), dict) else {}
    path_text = os.environ.get("FM_DISCORD_WORKSPACE_FIXTURE") or poll.get("fixture_file")
    if not path_text:
        raise FMError("live Discord polling is disabled in this phase; no network call was made")
    path = Path(str(path_text)).expanduser()
    if not path.is_absolute():
        path = (cfg.path.parent / path).resolve()
    data = json_load_file(path)
    if isinstance(data, dict):
        data = data.get("messages")
    if not isinstance(data, list):
        raise FMError("Discord fixture must be a list or an object with messages[]")
    out = []
    for item in data:
        if not isinstance(item, dict):
            raise FMError("Discord fixture message must be an object")
        out.append(item)
    out.sort(key=lambda m: int(str(m.get("id") or "0")) if str(m.get("id") or "0").isdigit() else 0)
    return out


def procevent_cmd_arm(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    command = [str(env.script_dir / "fm-procevent-discord-workspace.sh"), "source", "--config", str(cfg.path)]
    if args.dry_run:
        print("Discord workspace process-event arm dry-run (no network).")
        print(f"source id: {DISCORD_SOURCE_ID}")
        print("register command:")
        print(" ".join([str(env.script_dir / "fm-procevent.sh"), "register", "discord-workspace", DISCORD_SOURCE_ID, "--"] + command))
        print("live polling remains disabled until an activation task approves it.")
        return 0
    raise FMError("process-event arm refused in this offline phase; no live source was registered")


def procevent_cmd_source(args: argparse.Namespace, env: Env) -> int:
    cfg = load_config(env, args.config)
    messages = fixture_messages(cfg)
    for message in messages:
        event = message_to_event(cfg, message)
        profile = event.get("profile")
        channel_id = str(event.get("channel_id") or "")
        message_id = str(event.get("message_id") or "")
        if profile and channel_id and message_id.isdigit():
            cursor = read_cursor(env, str(profile), channel_id)
            if int(message_id) <= cursor:
                continue
        if event_class(event) == "ignored":
            if profile and channel_id and message_id.isdigit():
                write_cursor(env, str(profile), channel_id, message_id)
            continue
        print(json.dumps(event, sort_keys=True))
        return 0
    return EXIT_NO_RESULT


def load_event_result(result_file: str) -> Dict[str, Any]:
    path = Path(result_file)
    if path.is_symlink() or not path.is_file():
        raise FMError("result file is unavailable or unsafe")
    text = path.read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise FMError(f"result is not valid JSON: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema") != EVENT_SCHEMA:
        raise FMError("result schema is not fm-discord-workspace-event.v1")
    return data


def event_class(event: Dict[str, Any]) -> str:
    kind = str(event.get("kind") or "")
    if kind in ("text", "voice-transcript", "audio-transcript"):
        return "message"
    if kind == "audio-rejected":
        return "audio-rejected"
    if kind == "ignored":
        return "ignored"
    return "malformed"


def procevent_cmd_classify(args: argparse.Namespace, env: Env) -> int:
    try:
        event = load_event_result(args.result_file)
        print(event_class(event))
    except FMError:
        print("malformed")
    return 0


def procevent_cmd_silent(args: argparse.Namespace, env: Env) -> int:
    try:
        event = load_event_result(args.result_file)
    except FMError:
        return 1
    return 0 if event_class(event) == "ignored" else 1


def procevent_cmd_terminal(args: argparse.Namespace, env: Env) -> int:
    return 1


def procevent_cmd_self_announcing(args: argparse.Namespace, env: Env) -> int:
    return 0


def event_metadata(event: Dict[str, Any]) -> Dict[str, Any]:
    allowed = [
        "source", "kind", "profile", "forum_kind", "guild_id", "channel_id", "forum_channel_id",
        "message_id", "author_id", "external_id", "jump_url", "timestamp", "audio", "attachments",
        "transcription", "conversion_plan", "reason",
    ]
    return {key: event[key] for key in allowed if key in event}


def note_body_for_event(event: Dict[str, Any]) -> str:
    kind = str(event.get("kind"))
    header = f"Discord workspace / {event.get('profile')} / "
    lines = []
    if kind == "text":
        lines.append(header + "text")
        lines.append(f"request: {event.get('external_id')}")
        lines.append(f"from: {event.get('author_id')}")
        if event.get("jump_url"):
            lines.append(f"link: {event.get('jump_url')}")
        lines.append("")
        lines.append(str(event.get("content") or ""))
    elif kind in ("voice-transcript", "audio-transcript"):
        audio = event.get("audio") if isinstance(event.get("audio"), dict) else {}
        lines.append(header + ("voice transcript" if kind == "voice-transcript" else "audio transcript"))
        lines.append(f"request: {event.get('external_id')}")
        lines.append(f"from: {event.get('author_id')}")
        lines.append(f"attachment: {audio.get('id')} {audio.get('filename')} {audio.get('content_type')} {audio.get('size')} {audio.get('duration_secs')}")
        lines.append("transcription: fake fixture, no secret")
        if event.get("jump_url"):
            lines.append(f"link: {event.get('jump_url')}")
        lines.append("")
        lines.append(str(event.get("transcript") or ""))
    elif kind == "audio-rejected":
        lines.append(header + "audio rejected")
        lines.append(f"request: {event.get('external_id')}")
        lines.append(f"from: {event.get('author_id')}")
        lines.append(f"reason: {event.get('reason')}")
    else:
        raise FMError("event is not inbox-addressable")
    return "\n".join(lines).rstrip() + "\n"


def request_record_from_event(event: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "schema": REQUEST_SCHEMA,
        "request_id": event.get("external_id"),
        "guild_id": event.get("guild_id"),
        "channel_id": event.get("channel_id"),
        "message_id": event.get("message_id"),
        "profile": event.get("profile"),
        "origin": "discord-workspace",
        "jump_url": event.get("jump_url"),
    }


def procevent_mark_handled(env: Env, source_id: str, sequence: str) -> None:
    subprocess.run([str(env.script_dir / "fm-procevent.sh"), "handled", source_id, sequence], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def procevent_cmd_autohandle(args: argparse.Namespace, env: Env) -> int:
    source_id = args.source_id
    sequence = args.sequence
    if source_id != DISCORD_SOURCE_ID:
        raise FMError(f"not a Discord workspace source: {source_id}")
    if not str(sequence).isdigit():
        raise FMError("sequence must be numeric")
    event = load_event_result(args.result_file)
    cls = event_class(event)
    if cls == "malformed":
        raise FMError("result is malformed")
    if cls == "ignored":
        if event.get("profile") and event.get("channel_id") and event.get("message_id"):
            write_cursor(env, str(event["profile"]), str(event["channel_id"]), str(event["message_id"]))
        procevent_mark_handled(env, source_id, sequence)
        print("handled ignored Discord workspace event")
        return 0
    body = note_body_for_event(event)
    metadata_dir = env.discord_state / "metadata-staging"
    metadata_dir.mkdir(parents=True, exist_ok=True)
    fd, meta_tmp = tempfile.mkstemp(prefix=".metadata.", suffix=".json", dir=str(metadata_dir))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(event_metadata(event), f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(meta_tmp, 0o600)
        inbox_cmd = [
            str(env.script_dir / "fm-inbox.sh"),
            "note",
            "--source",
            "discord-workspace",
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
            return proc.returncode
    finally:
        try:
            os.unlink(meta_tmp)
        except FileNotFoundError:
            pass
    if cls == "message":
        request = request_record_from_event(event)
        write_same_or_refuse(request_record_path(env, str(event.get("external_id"))), request, "request record")
    if event.get("profile") and event.get("channel_id") and event.get("message_id"):
        write_cursor(env, str(event["profile"]), str(event["channel_id"]), str(event["message_id"]))
    procevent_mark_handled(env, source_id, sequence)
    print("autohandled Discord workspace event through fm-inbox")
    return 0


def procevent_cmd_answers(args: argparse.Namespace, env: Env) -> int:
    return 0


def add_config_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", help="non-secret Discord workspace config JSON")


def build_tool_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-discord-workspace.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("sample-config")
    p.set_defaults(func=cmd_sample_config)
    p = sub.add_parser("config-check")
    add_config_argument(p)
    p.set_defaults(func=cmd_config_check)
    p = sub.add_parser("setup")
    add_config_argument(p)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--apply", action="store_true")
    p.set_defaults(func=cmd_setup)
    p = sub.add_parser("health")
    add_config_argument(p)
    p.add_argument("--local", action="store_true")
    p.add_argument("--secrets", action="store_true")
    p.add_argument("--discord", action="store_true")
    p.add_argument("--transcription", action="store_true")
    p.add_argument("--process-event", action="store_true")
    p.add_argument("--outbound-dry-run", action="store_true")
    p.set_defaults(func=cmd_health)
    p = sub.add_parser("reply")
    add_config_argument(p)
    p.add_argument("--request-id", required=True)
    p.add_argument("--text-file", required=True)
    p.add_argument("--nonce")
    p.add_argument("--record-discord-message-id")
    p.set_defaults(func=cmd_reply)
    p = sub.add_parser("status")
    add_config_argument(p)
    p.add_argument("--profile", required=True, choices=ACTIVE_PROFILE_KEYS)
    p.add_argument("--thread")
    p.add_argument("--text-file", required=True)
    p.add_argument("--nonce")
    p.add_argument("--record-discord-message-id")
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("artifact")
    add_config_argument(p)
    p.add_argument("--profile", required=True, choices=ACTIVE_PROFILE_KEYS)
    p.add_argument("--file", required=True)
    p.add_argument("--purpose", required=True)
    p.add_argument("--request-id")
    p.add_argument("--private-url")
    p.add_argument("--client-confidential", action="store_true")
    p.add_argument("--captain-approved-client-confidential", action="store_true")
    p.add_argument("--nonce")
    p.add_argument("--record-discord-message-id")
    p.set_defaults(func=cmd_artifact)
    p = sub.add_parser("publish-artifact")
    add_config_argument(p)
    p.add_argument("--profile", required=True, choices=ACTIVE_PROFILE_KEYS)
    p.add_argument("--file", required=True)
    p.add_argument("--purpose", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--access", required=True)
    p.add_argument("--expires", default="7d")
    p.add_argument("--client-confidential", action="store_true")
    p.add_argument("--captain-approved-client-confidential", action="store_true")
    p.add_argument("--record", action="store_true")
    p.set_defaults(func=cmd_publish_artifact)
    p = sub.add_parser("link-task")
    add_config_argument(p)
    p.add_argument("task_id")
    p.add_argument("--request-id", required=True)
    p.set_defaults(func=cmd_link_task)
    p = sub.add_parser("followup")
    add_config_argument(p)
    p.add_argument("task_id")
    p.add_argument("--final", action="store_true")
    p.add_argument("--text-file", required=True)
    p.add_argument("--nonce")
    p.add_argument("--record-discord-message-id")
    p.set_defaults(func=cmd_followup)
    p = sub.add_parser("guard-work")
    p.add_argument("task_id")
    p.set_defaults(func=cmd_guard_work)
    p = sub.add_parser("retire")
    add_config_argument(p)
    p.add_argument("--apply", action="store_true")
    p.set_defaults(func=cmd_retire)
    return parser


def build_procevent_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-procevent-discord-workspace.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("arm")
    add_config_argument(p)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=procevent_cmd_arm)
    p = sub.add_parser("source")
    add_config_argument(p)
    p.set_defaults(func=procevent_cmd_source)
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
        print("usage: fm_discord_workspace_lib.py <tool|procevent> <script-dir> ...", file=sys.stderr)
        return 2
    mode = argv[1]
    env = Env(argv[2])
    rest = argv[3:]
    parser = build_tool_parser() if mode == "tool" else build_procevent_parser() if mode == "procevent" else None
    if parser is None:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    args = parser.parse_args(rest)
    try:
        return int(args.func(args, env))
    except FMError as exc:
        die(str(exc))
    except BrokenPipeError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
