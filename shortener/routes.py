"""HTTP routes for the URL shortener."""
from __future__ import annotations

from flask import (
    Blueprint,
    abort,
    current_app,
    flash,
    redirect,
    render_template,
    request,
    url_for,
)

from .shortener import InvalidURLError, create_link, lookup, record_visit, stats

bp = Blueprint("main", __name__)


def _build_short_url(code: str) -> str:
    base = current_app.config.get("BASE_URL", "").rstrip("/")
    if base:
        return f"{base}/{code}"
    return url_for("main.follow", code=code, _external=True)


@bp.route("/", methods=["GET", "POST"])
def index():
    short_url: str | None = None
    if request.method == "POST":
        url = request.form.get("url", "")
        custom_code = request.form.get("code") or None
        try:
            code, _ = create_link(url, custom_code)
        except InvalidURLError as exc:
            flash(str(exc), "error")
        else:
            short_url = _build_short_url(code)
            flash("Short link created.", "success")
    return render_template("index.html", short_url=short_url)


@bp.route("/api/shorten", methods=["POST"])
def api_shorten():
    payload = request.get_json(silent=True) or {}
    url = payload.get("url")
    custom_code = payload.get("code")

    if not isinstance(url, str):
        return {"error": "Field 'url' is required"}, 400

    try:
        code, normalized = create_link(url, custom_code if isinstance(custom_code, str) else None)
    except InvalidURLError as exc:
        return {"error": str(exc)}, 400

    return {
        "code": code,
        "url": normalized,
        "short_url": _build_short_url(code),
    }, 201


@bp.route("/api/links/<code>")
def api_stats(code: str):
    info = stats(code)
    if info is None:
        return {"error": "Not found"}, 404
    info["short_url"] = _build_short_url(code)
    return info


@bp.route("/<code>")
def follow(code: str):
    if code in {"favicon.ico", "robots.txt"}:
        abort(404)
    target = lookup(code)
    if target is None:
        abort(404)
    record_visit(code)
    return redirect(target, code=302)


@bp.route("/health")
def health():
    return {"status": "ok"}
