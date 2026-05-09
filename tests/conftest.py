from __future__ import annotations

import os
import tempfile

import pytest

from shortener import create_app


@pytest.fixture()
def app():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    application = create_app(
        {
            "TESTING": True,
            "DATABASE": path,
            "BASE_URL": "http://localhost",
        }
    )
    yield application
    os.unlink(path)


@pytest.fixture()
def client(app):
    return app.test_client()
