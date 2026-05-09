"""Core helpers for generating short codes and validating URLs."""
from __future__ import annotations

import secrets
import string
from urllib.parse import urlparse

from flask import current_app

from .db import execute, fetch_one

ALPHABET = string.ascii_letters + string.digits
ALLOWED_SCHEMES = {"http", "https"}
MAX_URL_LENGTH = 2048


class InvalidURLError(ValueError):
    """Raised when the supplied URL is not a valid http(s) URL."""


def normalize_url(raw: str) -> str:
    """Strip whitespace and validate that ``raw`` is an http(s) URL."""
    if not isinstance(raw, str):
        raise InvalidURLError("URL must be a string")

    url = raw.strip()
    if not url:
        raise InvalidURLError("URL must not be empty")
    if len(url) > MAX_URL_LENGTH:
        raise InvalidURLError(f"URL exceeds {MAX_URL_LENGTH} characters")

    parsed = urlparse(url)
    if parsed.scheme.lower() not in ALLOWED_SCHEMES:
        raise InvalidURLError("Only http and https URLs are supported")
    if not parsed.netloc:
        raise InvalidURLError("URL must include a host")

    return url


def generate_code(length: int | None = None) -> str:
    """Generate a random short code that does not collide with an existing one."""
    target_length = length or current_app.config.get("CODE_LENGTH", 6)
    for _ in range(10):
        candidate = "".join(secrets.choice(ALPHABET) for _ in range(target_length))
        if fetch_one("SELECT 1 FROM links WHERE code = ?", (candidate,)) is None:
            return candidate
    # Extremely unlikely; fall back to a longer code to guarantee uniqueness.
    return generate_code(target_length + 1)


def create_link(raw_url: str, code: str | None = None) -> tuple[str, str]:
    """Persist a new short link and return ``(code, url)``."""
    url = normalize_url(raw_url)

    if code is not None:
        if not code or not all(c in ALPHABET for c in code):
            raise InvalidURLError(
                "Custom codes must be alphanumeric and non-empty",
            )
        if fetch_one("SELECT 1 FROM links WHERE code = ?", (code,)) is not None:
            raise InvalidURLError("That code is already taken")
    else:
        code = generate_code()

    execute(
        "INSERT INTO links (code, url) VALUES (?, ?)",
        (code, url),
    )
    return code, url


def lookup(code: str) -> str | None:
    """Return the original URL for ``code`` or ``None`` if it does not exist."""
    row = fetch_one("SELECT url FROM links WHERE code = ?", (code,))
    return row["url"] if row else None


def record_visit(code: str) -> None:
    execute("UPDATE links SET visits = visits + 1 WHERE code = ?", (code,))


def stats(code: str) -> dict[str, object] | None:
    row = fetch_one(
        "SELECT code, url, created_at, visits FROM links WHERE code = ?",
        (code,),
    )
    if row is None:
        return None
    return {
        "code": row["code"],
        "url": row["url"],
        "created_at": row["created_at"],
        "visits": row["visits"],
    }
