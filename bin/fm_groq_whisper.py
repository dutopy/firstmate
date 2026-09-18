#!/usr/bin/env python3
"""Bounded Groq Whisper transcription for the Discord conversation console.

This module owns exactly one thing: turning one already-downloaded audio file
into text through Groq's OpenAI-compatible ``/audio/transcriptions`` endpoint.

The API key and the audio bytes never leave the caller's process except in the
one request to Groq: the key is read from the environment (falling back to the
home's gitignored ``.env``) into memory only, the audio is read once, and no
caller-visible error ever contains the key or the audio bytes.

Out of scope by contract: downloading from Discord (the conversation console
owns that), any provider other than Groq, any model other than the
captain-authorized French ``whisper-large-v3``, and persisting audio anywhere.

Test seams: ``FM_GROQ_API_BASE`` overrides the API base URL so a suite can point
this module at a loopback fake. It never changes what is redacted.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple

DEFAULT_MODEL = "whisper-large-v3"
DEFAULT_LANGUAGE = "fr"
DEFAULT_BASE_URL = "https://api.groq.com/openai/v1"
DEFAULT_TIMEOUT_SECONDS = 60.0
MAX_TIMEOUT_SECONDS = 300.0
DEFAULT_KEY_ENV = "GROQ_API_KEY"

# The captain-authorized vocabulary prompt, passed verbatim to Whisper so the
# proper nouns survive transcription.
DEFAULT_PROMPT = (
    "Hermes, Firstmate, ProApplis, Folium, ARFAL, herdr, Mnemosyne, dutopy, "
    "Astra, Luna, Jeff, kanban, worktree"
)

MAX_RESPONSE_BYTES = 64 * 1024
MAX_ERROR_BYTES = 4 * 1024
_KEY_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


class GroqError(Exception):
    """A bounded, redacted transcription refusal that should not show a traceback."""


def redact(text: str, api_key: str) -> str:
    if not api_key:
        return text
    return text.replace(api_key, "[REDACTED]")


def bounded(text: str, limit: int = 300) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "\u2026"


def dotenv_get(path: Path, key: str) -> str:
    """Read one KEY= value from a .env-style file, matching bin/fm-env-lib.sh.

    The last assignment wins; a leading ``export `` and one layer of matching
    single or double quotes are tolerated. An absent file or key yields "".
    """
    if not path.is_file() or path.is_symlink():
        return ""
    pattern = re.compile(rf"^[ \t]*(?:export[ \t]+)?{re.escape(key)}[ \t]*=(.*)$")
    found = ""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    for line in text.splitlines():
        match = pattern.match(line)
        if not match:
            continue
        value = match.group(1).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        found = value
    return found


def resolve_api_key(home: Path, key_env: str = DEFAULT_KEY_ENV, environ: Optional[Mapping[str, str]] = None) -> str:
    """Resolve the Groq key: the process environment wins, then the home's .env."""
    if not isinstance(key_env, str) or not _KEY_NAME_RE.fullmatch(key_env):
        raise GroqError("Groq API key reference must be an uppercase secret name")
    env = os.environ if environ is None else environ
    value = str(env.get(key_env) or "").strip()
    if value:
        return value
    return dotenv_get(Path(home) / ".env", key_env).strip()


def validate_model(model: str) -> str:
    """Only the captain-authorized Whisper large-v3 is accepted, never turbo."""
    if model != DEFAULT_MODEL:
        raise GroqError(f"Groq transcription model must be {DEFAULT_MODEL}")
    return model


def validate_language(language: str) -> str:
    if not isinstance(language, str) or not re.fullmatch(r"[a-z]{2,3}", language):
        raise GroqError("transcription language must be a short lowercase code such as fr")
    return language


def validate_prompt(prompt: str) -> str:
    if not isinstance(prompt, str) or not prompt.strip():
        raise GroqError("transcription prompt must be a non-empty string")
    if len(prompt) > 1000 or "\n" in prompt or "\r" in prompt:
        raise GroqError("transcription prompt must be one line of at most 1000 characters")
    return prompt


def api_base_url(configured: str = "") -> str:
    override = os.environ.get("FM_GROQ_API_BASE")
    base = (override or configured or DEFAULT_BASE_URL).strip().rstrip("/")
    if not base.startswith(("https://", "http://")):
        raise GroqError("Groq API base URL must be http(s)")
    return base


def _safe_filename(name: str) -> str:
    base = Path(str(name) or "audio").name
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", base)[:120]
    if cleaned in ("", ".", "..") or cleaned.startswith("."):
        cleaned = "audio" + Path(base).suffix
    return cleaned


def _content_type_for(filename: str) -> str:
    guessed, _ = mimetypes.guess_type(filename)
    return guessed or "application/octet-stream"


def encode_multipart(
    fields: Iterable[Tuple[str, str]],
    file_field: str,
    filename: str,
    data: bytes,
    content_type: str,
) -> Tuple[str, bytes]:
    boundary = "----firstmate-" + os.urandom(16).hex()
    body = bytearray()
    for name, value in fields:
        body += f"--{boundary}\r\n".encode("ascii")
        body += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("ascii")
        body += str(value).encode("utf-8") + b"\r\n"
    body += f"--{boundary}\r\n".encode("ascii")
    body += (
        f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
    ).encode("utf-8")
    body += f"Content-Type: {content_type}\r\n\r\n".encode("ascii")
    body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode("ascii")
    return boundary, bytes(body)


def transcribe(
    audio_path: Path,
    filename: str,
    *,
    api_key: str,
    model: str = DEFAULT_MODEL,
    language: str = DEFAULT_LANGUAGE,
    prompt: str = DEFAULT_PROMPT,
    base_url: str = DEFAULT_BASE_URL,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> str:
    """Return the transcript text for one audio file, or raise GroqError.

    Every failure is one bounded, redacted line. The caller owns the audio file's
    lifetime and deletes it; this function never writes the audio anywhere.
    """
    if not api_key or not isinstance(api_key, str):
        raise GroqError("Groq transcription is enabled but no API key is configured")
    model = validate_model(model)
    language = validate_language(language)
    prompt = validate_prompt(prompt)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        raise GroqError("transcription timeout must be a number")
    timeout = float(timeout)
    if timeout <= 0 or timeout > MAX_TIMEOUT_SECONDS:
        raise GroqError(f"transcription timeout must be between 0 and {MAX_TIMEOUT_SECONDS:g} seconds")
    path = Path(audio_path)
    try:
        audio = path.read_bytes()
    except OSError as exc:
        raise GroqError(f"could not read the downloaded audio: {exc}") from exc
    if not audio:
        raise GroqError("the downloaded audio was empty")
    safe_name = _safe_filename(filename)
    boundary, body = encode_multipart(
        [
            ("model", model),
            ("language", language),
            ("prompt", prompt),
            ("response_format", "json"),
            ("temperature", "0"),
        ],
        "file",
        safe_name,
        audio,
        _content_type_for(safe_name),
    )
    url = f"{api_base_url(base_url)}/audio/transcriptions"
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": "application/json",
            "User-Agent": "firstmate-discord-console-audio (+https://localhost)",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read(MAX_ERROR_BYTES).decode("utf-8", "replace")
        except OSError:
            detail = ""
        raise GroqError(
            redact(f"Groq transcription failed with HTTP {exc.code}: {bounded(detail)}", api_key)
        ) from exc
    except urllib.error.URLError as exc:
        raise GroqError(redact(f"Groq transcription could not be reached: {exc.reason}", api_key)) from exc
    except OSError as exc:
        raise GroqError(redact(f"Groq transcription failed: {exc}", api_key)) from exc
    if len(payload) > MAX_RESPONSE_BYTES:
        raise GroqError("Groq transcription response exceeded the size bound")
    try:
        parsed: Any = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GroqError("Groq transcription returned a malformed response") from exc
    if not isinstance(parsed, dict):
        raise GroqError("Groq transcription returned a malformed response")
    text = parsed.get("text")
    if not isinstance(text, str):
        raise GroqError("Groq transcription response did not contain text")
    return text
