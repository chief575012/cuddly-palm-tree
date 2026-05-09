"""WSGI entry point used by ``flask run`` and production servers."""
from shortener import create_app

app = create_app()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
