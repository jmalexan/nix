import argparse
import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "UpdateDashboard/1"

    def send_bytes(self, body, content_type, status=200, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, value, status=200):
        self.send_bytes(
            json.dumps(value).encode(),
            "application/json; charset=utf-8",
            status=status,
        )

    def load_json(self, name, fallback=None):
        try:
            return json.loads((self.server.data_root / name).read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return fallback

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self.send_json({"status": "ok"})
            return
        if path == "/api/status":
            self.send_json(
                {
                    "reports": {
                        "releases": self.load_json("releases.json"),
                        "digests": self.load_json("digests.json"),
                        "nix": self.load_json("nix.json"),
                    },
                    "history": list(reversed(self.load_json("history.json", []))),
                }
            )
            return

        assets = {
            "/": "index.html",
            "/index.html": "index.html",
            "/app.js": "app.js",
            "/styles.css": "styles.css",
        }
        if path.startswith("/pipeline/reports/"):
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return
        if path not in assets:
            self.send_json({"error": "not found"}, status=404)
            return

        asset = self.server.static_root / assets[path]
        content_type = mimetypes.guess_type(asset.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type in (
            "application/javascript",
            "application/json",
        ):
            content_type += "; charset=utf-8"
        self.send_bytes(asset.read_bytes(), content_type, cache="public, max-age=300")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--static", required=True)
    parser.add_argument("--data", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.listen, args.port), DashboardHandler)
    server.static_root = Path(args.static)
    server.data_root = Path(args.data)
    print(f"Update dashboard listening on {args.listen}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
