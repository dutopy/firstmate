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

A short question can mishear into a phonetically adjacent sentence with the
opposite meaning, and the caller cannot tell a garbled question from a garbled
instruction. ``transcribe_checked`` therefore reads the same audio twice - one
extra bounded call at a different decode temperature - and reports the two
readings' disagreement, or any failure of that second call, as uncertainty
instead of hiding it. The first reading is always returned.

Test seams: ``FM_GROQ_API_BASE`` overrides the API base URL so a suite can point
this module at a loopback fake. It never changes what is redacted.
"""

from __future__ import annotations

import difflib
import json
import mimetypes
import os
import re
import unicodedata
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

# The confidence check. One extra decode of the same audio at a different
# temperature is compared against the first reading: a genuine mishearing
# decodes into a different sentence, while a phrase that was really heard
# decodes the same way twice. Only audio at or under the duration bound is
# checked, so the extra cost stays on the short phrases that mishear.
DEFAULT_CONFIDENCE_TEMPERATURE = 0.6
DEFAULT_CONFIDENCE_MAX_SECONDS = 30.0
MAX_CONFIDENCE_MAX_SECONDS = 600.0
DEFAULT_CONFIDENCE_TIMEOUT_SECONDS = 20.0
CONFIDENCE_MIN_RATIO = 0.75
CONFIDENCE_ALTERNATE_MAX_CHARS = 300


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


def validate_confidence_max_seconds(value: Any) -> float:
    """The audio duration bound under which the second decoding pass is spent."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GroqError("confidence check duration bound must be a number")
    seconds = float(value)
    if not 0 < seconds <= MAX_CONFIDENCE_MAX_SECONDS:
        raise GroqError(
            f"confidence check duration bound must be between 0 and {MAX_CONFIDENCE_MAX_SECONDS:g} seconds"
        )
    return seconds


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


def _validated_settings(
    *,
    api_key: str,
    model: str,
    language: str,
    prompt: str,
    timeout: float,
) -> Tuple[str, str, str, str, float]:
    """Validate one request's fixed settings, returning them normalized."""
    if not api_key or not isinstance(api_key, str):
        raise GroqError("Groq transcription is enabled but no API key is configured")
    model = validate_model(model)
    language = validate_language(language)
    prompt = validate_prompt(prompt)
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
        raise GroqError("transcription timeout must be a number")
    seconds = float(timeout)
    if seconds <= 0 or seconds > MAX_TIMEOUT_SECONDS:
        raise GroqError(f"transcription timeout must be between 0 and {MAX_TIMEOUT_SECONDS:g} seconds")
    return api_key, model, language, prompt, seconds


def _read_audio(audio_path: Path, filename: str) -> Tuple[bytes, str]:
    path = Path(audio_path)
    try:
        audio = path.read_bytes()
    except OSError as exc:
        raise GroqError(f"could not read the downloaded audio: {exc}") from exc
    if not audio:
        raise GroqError("the downloaded audio was empty")
    return audio, _safe_filename(filename)


def _post_audio(
    audio: bytes,
    safe_name: str,
    *,
    api_key: str,
    model: str,
    language: str,
    prompt: str,
    base_url: str,
    timeout: float,
    temperature: float,
) -> str:
    """POST one already-read audio buffer and return its transcript text.

    Every failure is one bounded, redacted line, so no caller can leak the key.
    """
    boundary, body = encode_multipart(
        [
            ("model", model),
            ("language", language),
            ("prompt", prompt),
            ("response_format", "json"),
            ("temperature", f"{temperature:g}"),
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
    api_key, model, language, prompt, seconds = _validated_settings(
        api_key=api_key, model=model, language=language, prompt=prompt, timeout=timeout
    )
    audio, safe_name = _read_audio(audio_path, filename)
    return _post_audio(
        audio,
        safe_name,
        api_key=api_key,
        model=model,
        language=language,
        prompt=prompt,
        base_url=base_url,
        timeout=seconds,
        temperature=0.0,
    )


def normalize_transcript(text: str) -> str:
    """Case-, accent-, and punctuation-insensitive form, for comparing readings."""
    decomposed = unicodedata.normalize("NFKD", text or "")
    stripped = "".join(char for char in decomposed if not unicodedata.combining(char))
    return " ".join(re.sub(r"[^a-z0-9]+", " ", stripped.lower()).split())


def transcript_tokens(text: str) -> List[str]:
    """The words of one reading, accents and punctuation already removed."""
    return normalize_transcript(text).split()


def transcripts_agree(primary: str, alternate: str, min_ratio: float = CONFIDENCE_MIN_RATIO) -> Tuple[bool, float]:
    """True when two readings of one audio carry the same words.

    Intentional differences (case, accents, punctuation, spacing) never count,
    and a second reading that hears the same sentence with one word more or less
    still agrees, because the shared words are the sentence.
    The returned ratio is a word-level similarity, so dropping or adding a
    function word among many keeps two readings together while a reading that
    heard a different sentence - or far fewer words - falls well below the
    threshold and is reported as doubt rather than averaged away.
    """
    first = transcript_tokens(primary)
    second = transcript_tokens(alternate)
    if first == second:
        return True, 1.0
    if not first or not second:
        return False, 0.0
    ratio = difflib.SequenceMatcher(None, first, second).ratio()
    return ratio >= min_ratio, ratio


def transcribe_checked(
    audio_path: Path,
    filename: str,
    *,
    api_key: str,
    model: str = DEFAULT_MODEL,
    language: str = DEFAULT_LANGUAGE,
    prompt: str = DEFAULT_PROMPT,
    base_url: str = DEFAULT_BASE_URL,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    check: bool = True,
    check_max_seconds: float = DEFAULT_CONFIDENCE_MAX_SECONDS,
    check_timeout: Optional[float] = None,
    duration_secs: Optional[float] = None,
    temperature: float = DEFAULT_CONFIDENCE_TEMPERATURE,
) -> Tuple[str, Dict[str, Any]]:
    """Transcribe one audio file, then spend one extra bounded call testing it.

    Returns ``(text, confidence)``, where ``text`` is the first reading and is
    never withheld. ``confidence`` is a small JSON-safe record whose ``status``
    is one of ``agree``, ``disagree``, ``unavailable``, ``skipped``, or
    ``disabled``, and whose ``uncertain`` flag is True exactly when the reading
    must not be treated as settled: the two readings disagreed, or the check
    itself could not complete. Both cases return the text so the caller can
    deliver it carrying a visible marker rather than silently trusting it.

    The check is one extra call, never retried, and runs only for audio at or
    under ``check_max_seconds``. The same language and vocabulary prompt are
    used for both readings, so the only difference is the decoding temperature.
    """
    api_key, model, language, prompt, seconds = _validated_settings(
        api_key=api_key, model=model, language=language, prompt=prompt, timeout=timeout
    )
    audio, safe_name = _read_audio(audio_path, filename)
    text = _post_audio(
        audio,
        safe_name,
        api_key=api_key,
        model=model,
        language=language,
        prompt=prompt,
        base_url=base_url,
        timeout=seconds,
        temperature=0.0,
    )
    settings = {
        "api_key": api_key,
        "model": model,
        "language": language,
        "prompt": prompt,
        "base_url": base_url,
    }
    if not check:
        return text, {
            "status": "disabled",
            "uncertain": False,
            "checked": False,
            "reason": "the confidence check is off",
        }
    bound = validate_confidence_max_seconds(check_max_seconds)
    if duration_secs is not None:
        if isinstance(duration_secs, bool) or not isinstance(duration_secs, (int, float)):
            raise GroqError("audio duration must be a number of seconds")
        duration = float(duration_secs)
        if duration > bound:
            return text, {
                "status": "skipped",
                "uncertain": False,
                "checked": False,
                "reason": f"the audio is {duration:g}s, longer than the {bound:g}s confidence bound",
            }
    second_timeout = min(seconds, DEFAULT_CONFIDENCE_TIMEOUT_SECONDS) if check_timeout is None else check_timeout
    if isinstance(second_timeout, bool) or not isinstance(second_timeout, (int, float)):
        raise GroqError("transcription timeout must be a number")
    second_timeout = float(second_timeout)
    if second_timeout <= 0 or second_timeout > MAX_TIMEOUT_SECONDS:
        raise GroqError(f"transcription timeout must be between 0 and {MAX_TIMEOUT_SECONDS:g} seconds")
    try:
        alternate = _post_audio(audio, safe_name, timeout=second_timeout, temperature=temperature, **settings)
    except GroqError as exc:
        # The check itself failed, so the reading is unknown, not settled: keep
        # the transcript and mark it rather than delivering it as confident.
        return text, {
            "status": "unavailable",
            "uncertain": True,
            "checked": True,
            "reason": bounded(str(exc), 200),
        }
    agree, ratio = transcripts_agree(text, alternate)
    if agree:
        return text, {"status": "agree", "uncertain": False, "checked": True, "ratio": round(ratio, 3)}
    return text, {
        "status": "disagree",
        "uncertain": True,
        "checked": True,
        "ratio": round(ratio, 3),
        "alternate": bounded(alternate, CONFIDENCE_ALTERNATE_MAX_CHARS),
    }
