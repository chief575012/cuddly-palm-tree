from __future__ import annotations

import pytest

from shortener.shortener import InvalidURLError, normalize_url


def test_index_renders(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert b"URL Shortener" in resp.data


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_api_shorten_creates_link(client):
    resp = client.post("/api/shorten", json={"url": "https://example.com/foo"})
    assert resp.status_code == 201
    body = resp.get_json()
    assert body["url"] == "https://example.com/foo"
    assert body["code"]
    assert body["short_url"].endswith(body["code"])


def test_api_shorten_rejects_invalid_url(client):
    resp = client.post("/api/shorten", json={"url": "not a url"})
    assert resp.status_code == 400
    assert "error" in resp.get_json()


def test_api_shorten_requires_url_field(client):
    resp = client.post("/api/shorten", json={})
    assert resp.status_code == 400


def test_api_shorten_custom_code_must_be_unique(client):
    first = client.post(
        "/api/shorten",
        json={"url": "https://example.com/a", "code": "abc123"},
    )
    assert first.status_code == 201

    second = client.post(
        "/api/shorten",
        json={"url": "https://example.com/b", "code": "abc123"},
    )
    assert second.status_code == 400


def test_redirect_follows_link(client):
    resp = client.post("/api/shorten", json={"url": "https://example.com/dest"})
    code = resp.get_json()["code"]

    follow = client.get(f"/{code}")
    assert follow.status_code == 302
    assert follow.headers["Location"] == "https://example.com/dest"


def test_redirect_404_for_unknown_code(client):
    assert client.get("/missing").status_code == 404


def test_stats_endpoint_tracks_visits(client):
    resp = client.post("/api/shorten", json={"url": "https://example.com/x"})
    code = resp.get_json()["code"]

    client.get(f"/{code}")
    client.get(f"/{code}")

    stats = client.get(f"/api/links/{code}").get_json()
    assert stats["visits"] == 2
    assert stats["url"] == "https://example.com/x"


def test_stats_404_for_unknown_code(client):
    assert client.get("/api/links/nope").status_code == 404


def test_form_submission_creates_link(client):
    resp = client.post(
        "/",
        data={"url": "https://example.com/form"},
        follow_redirects=False,
    )
    assert resp.status_code == 200
    assert b"Your short link" in resp.data


@pytest.mark.parametrize(
    "bad",
    ["", "   ", "ftp://example.com", "javascript:alert(1)", "example.com"],
)
def test_normalize_url_rejects_bad_urls(bad):
    with pytest.raises(InvalidURLError):
        normalize_url(bad)


def test_normalize_url_strips_whitespace():
    assert normalize_url("  https://example.com/  ") == "https://example.com/"
