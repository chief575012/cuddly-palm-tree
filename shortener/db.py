"""SQLite helpers for the URL shortener."""
from __future__ import annotations

import sqlite3
from typing import Any

from flask import current_app, g

SCHEMA = """
CREATE TABLE IF NOT EXISTS links (
    code        TEXT PRIMARY KEY,
    url         TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    visits      INTEGER NOT NULL DEFAULT 0
);
"""


def get_db() -> sqlite3.Connection:
    """Return a per-request SQLite connection."""
    if "db" not in g:
        conn = sqlite3.connect(
            current_app.config["DATABASE"],
            detect_types=sqlite3.PARSE_DECLTYPES,
        )
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON;")
        g.db = conn
    return g.db


def close_db(_exc: BaseException | None = None) -> None:
    """Close the per-request connection if one was opened."""
    db: sqlite3.Connection | None = g.pop("db", None)
    if db is not None:
        db.close()


def init_db() -> None:
    """Create the schema if it does not already exist."""
    db = get_db()
    db.executescript(SCHEMA)
    db.commit()


def fetch_one(query: str, params: tuple[Any, ...] = ()) -> sqlite3.Row | None:
    return get_db().execute(query, params).fetchone()


def fetch_all(query: str, params: tuple[Any, ...] = ()) -> list[sqlite3.Row]:
    return list(get_db().execute(query, params).fetchall())


def execute(query: str, params: tuple[Any, ...] = ()) -> None:
    db = get_db()
    db.execute(query, params)
    db.commit()
