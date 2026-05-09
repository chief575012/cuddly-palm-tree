# cuddly-palm-tree

A tiny Flask URL shortener. Paste a long URL, get a short one back.

## Features

- `POST /api/shorten` — JSON API to create a short link (optionally with a custom code).
- `GET /<code>` — 302 redirect to the original URL (also bumps a visit counter).
- `GET /api/links/<code>` — JSON stats for a short link.
- `GET /` — minimal HTML form for creating links from the browser.
- `GET /health` — health check.

Storage is SQLite by default; codes are random base62 strings.

## Quick start

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt

# Run the dev server
python wsgi.py
# or
flask --app wsgi run --debug
```

Then open http://localhost:5000 in a browser.

### Shorten a URL via the API

```bash
curl -X POST http://localhost:5000/api/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://www.roblox.com/games/131042960152703/Roda"}'
```

Response:

```json
{
  "code": "Ab3xY9",
  "url": "https://www.roblox.com/games/131042960152703/Roda",
  "short_url": "http://localhost:5000/Ab3xY9"
}
```

You can also pass `"code": "my-alias"` to request a custom (unique, alphanumeric) code.

### Follow a short link

```bash
curl -i http://localhost:5000/Ab3xY9
# HTTP/1.1 302 FOUND
# Location: https://www.roblox.com/games/131042960152703/Roda
```

## Configuration

| Env var | Default | Description |
| --- | --- | --- |
| `SHORTENER_DB` | `shortener.db` | SQLite file path |
| `SHORTENER_CODE_LENGTH` | `6` | Length of generated codes |
| `SHORTENER_BASE_URL` | _(empty)_ | Base URL used to render `short_url` (e.g. `https://sho.rt`) |

## Development

```bash
ruff check .
pytest
```

CI runs lint + tests on Python 3.10 / 3.11 / 3.12 via GitHub Actions.
