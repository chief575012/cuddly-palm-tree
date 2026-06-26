"""Flask upload server matching the Roblox DataTransfer Luau client.

Endpoints
---------
POST /
    Dispatches based on the ``action`` request header:
      - ``ping``: heartbeat used by ``DataTransfer.connect``. Returns 200.
      - ``get``:  fetch the most recent snapshot for the user encoded in the
                  ``container`` header. Returns
                  ``{"response": true, "data": "<base64>"}`` if a snapshot
                  exists, else ``{"response": false}``.
      - ``save``: store the snapshot from the request body for the user
                  encoded in the ``container`` header.

GET /healthz
    Simple liveness probe.

Wire format
-----------
The Luau client wraps payloads as ``base64(zlib_deflate(json(payload)))``.
- The ``container`` header is that wrapping of ``{"user": "<userId>"}``.
- For ``save``, the request body is the JSON-encoded base64 string of the
  save itself (i.e. ``"<base64>"`` with the surrounding quotes).

The server stores the snapshot as the raw base64 string and returns it
verbatim on ``get`` so the client can decode it with its own zlib/json
inflater without re-encoding round trips.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import threading
import zlib
from pathlib import Path
from typing import Any, Callable

from flask import Flask, Response, jsonify, request

SAVE_DIR = Path(os.environ.get("SAVE_DIR", "saves")).resolve()
SAVE_DIR.mkdir(parents=True, exist_ok=True)

logger = logging.getLogger("data_transfer")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

app = Flask(__name__)

# Per-user file locks to prevent torn writes when multiple requests race.
_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def _lock_for(user: str) -> threading.Lock:
    with _locks_guard:
        lock = _locks.get(user)
        if lock is None:
            lock = threading.Lock()
            _locks[user] = lock
        return lock


def _decode_container(container: str) -> dict[str, Any]:
    """Reverse the Luau ``encodeContainer`` wrapping."""
    raw = zlib.decompress(base64.b64decode(container))
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("container payload is not a JSON object")
    return payload


def _user_from_container() -> str:
    container = request.headers.get("container")
    if not container:
        raise ValueError("missing 'container' header")
    payload = _decode_container(container)
    user = payload.get("user")
    if user is None:
        raise ValueError("container missing 'user' field")
    return str(user)


def _save_path(user: str) -> Path:
    # Confine writes to SAVE_DIR even if the user id contains unusual chars.
    safe = "".join(ch for ch in str(user) if ch.isalnum() or ch in "_-")
    if not safe:
        raise ValueError("invalid user id")
    return SAVE_DIR / f"{safe}.b64"


def _handle_ping() -> tuple[Response, int]:
    return jsonify({"response": True, "pong": True}), 200


def _handle_get() -> tuple[Response, int]:
    user = _user_from_container()
    path = _save_path(user)
    if not path.exists():
        logger.info("get user=%s: no snapshot", user)
        return jsonify({"response": False}), 200
    with _lock_for(user):
        data = path.read_text(encoding="utf-8")
    logger.info("get user=%s: %d bytes", user, len(data))
    return jsonify({"response": True, "data": data}), 200


def _handle_save() -> tuple[Response, int]:
    user = _user_from_container()
    raw = request.get_data(cache=False, as_text=True) or ""
    # The Luau client sends ``JSONEncode(base64_string)`` -- i.e. the base64
    # snapshot wrapped in JSON quotes. Try JSON first; fall back to the raw
    # body so a client that posts the bare base64 still works.
    try:
        decoded = json.loads(raw)
        if not isinstance(decoded, str):
            raise ValueError("save body decoded to non-string")
        snapshot = decoded
    except (ValueError, json.JSONDecodeError):
        snapshot = raw.strip()

    if not snapshot:
        return jsonify({"response": False, "error": "empty snapshot"}), 400

    # Validate the snapshot really is base64+zlib so we surface broken uploads
    # instead of accepting garbage.
    try:
        zlib.decompress(base64.b64decode(snapshot))
    except Exception as exc:  # noqa: BLE001 - bubble any decode failure
        logger.warning("save user=%s: invalid snapshot (%s)", user, exc)
        return jsonify({"response": False, "error": "invalid snapshot encoding"}), 400

    path = _save_path(user)
    tmp = path.with_suffix(".b64.tmp")
    with _lock_for(user):
        tmp.write_text(snapshot, encoding="utf-8")
        os.replace(tmp, path)
    logger.info("save user=%s: %d bytes", user, len(snapshot))
    return jsonify({"response": True}), 200


_ACTIONS: dict[str, Callable[[], tuple[Response, int]]] = {
    "ping": _handle_ping,
    "get": _handle_get,
    "save": _handle_save,
}


@app.post("/")
def dispatch() -> tuple[Response, int]:
    action = request.headers.get("action", "").lower()
    handler = _ACTIONS.get(action)
    if handler is None:
        return jsonify({"response": False, "error": f"unknown action {action!r}"}), 400
    try:
        return handler()
    except ValueError as exc:
        logger.warning("%s: bad request: %s", action, exc)
        return jsonify({"response": False, "error": str(exc)}), 400
    except Exception:  # noqa: BLE001
        logger.exception("%s: unhandled error", action)
        return jsonify({"response": False, "error": "internal error"}), 500


@app.get("/healthz")
def healthz() -> tuple[Response, int]:
    return jsonify({"ok": True}), 200


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "5000"))
    app.run(host=host, port=port)
