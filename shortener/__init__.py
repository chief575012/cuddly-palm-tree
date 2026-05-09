"""Flask URL shortener application package."""
from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any

from flask import Flask

from .db import close_db, init_db
from .routes import bp as main_bp


def create_app(config: Mapping[str, Any] | None = None) -> Flask:
    """Application factory for the URL shortener."""
    app = Flask(__name__, instance_relative_config=False)

    default_db = os.environ.get("SHORTENER_DB", "shortener.db")
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("SHORTENER_SECRET_KEY", "dev-secret-change-me"),
        DATABASE=default_db,
        CODE_LENGTH=int(os.environ.get("SHORTENER_CODE_LENGTH", "6")),
        BASE_URL=os.environ.get("SHORTENER_BASE_URL", ""),
    )

    if config:
        app.config.update(config)

    app.teardown_appcontext(close_db)

    with app.app_context():
        init_db()

    app.register_blueprint(main_bp)

    return app
