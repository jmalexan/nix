import argparse
import datetime as dt
import json
import mimetypes
import os
import re
import secrets
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ANSI_SEQUENCE = re.compile(
    r"\x1b(?:\][^\x07]*(?:\x07|\x1b\\)|\[[0-?]*[ -/]*[@-~]|[@-_])"
)
SIZE_SUFFIX = re.compile(r", [+-]?\d+(?:\.\d+)? (?:B|[KMGTPE]iB)$")


def clean_terminal_text(value):
    if isinstance(value, str):
        return ANSI_SEQUENCE.sub("", value).replace("\r", "")
    if isinstance(value, list):
        return [clean_terminal_text(item) for item in value]
    if isinstance(value, dict):
        return {key: clean_terminal_text(item) for key, item in value.items()}
    return value


def version_change_text(value):
    return "\n".join(
        SIZE_SUFFIX.sub("", line) for line in value.splitlines() if " → " in line
    )


def version_focused_nix_report(report):
    if not isinstance(report, dict) or not isinstance(report.get("hosts"), list):
        return report

    for host in report["hosts"]:
        host["changes"] = version_change_text(host.get("changes", ""))
        if host.get("status") != "error":
            host["status"] = "update" if host["changes"] else "current"

    report["counts"] = {
        status: sum(host.get("status") == status for host in report["hosts"])
        for status in ("update", "current", "error")
    }
    return report


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "UpdateDashboard/1"

    def send_bytes(self, body, content_type, status=200, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header(
            "Content-Security-Policy", "default-src 'self'; style-src 'self'"
        )
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
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
            value = clean_terminal_text(
                json.loads((self.server.data_root / name).read_text())
            )
            return version_focused_nix_report(value) if name == "nix.json" else value
        except (FileNotFoundError, json.JSONDecodeError):
            return fallback

    def job_state(self, unit):
        try:
            result = subprocess.run(
                [
                    self.server.systemctl,
                    "show",
                    "--property=ActiveState",
                    "--value",
                    unit,
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return result.stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return "unknown"

    def action_status(self):
        results = {}
        for path in self.server.results_root.glob("*.json"):
            try:
                results[path.stem] = clean_terminal_text(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                continue
        jobs = {}
        for name, unit in self.server.scan_units.items():
            state = self.job_state(unit)
            jobs[name] = (
                "queued" if (self.server.trigger_root / name).exists() else state
            )
        return {
            "csrfToken": self.server.csrf_token,
            "prConfigured": self.token_configured(),
            "jobs": jobs | {"pr": self.job_state("updates-dashboard-pr.service")},
            "pullRequests": results,
        }

    def token_configured(self):
        try:
            return (
                self.server.token_path.is_file()
                and self.server.token_path.stat().st_size > 0
            )
        except OSError:
            return False

    def same_origin(self):
        origin = self.headers.get("Origin")
        host = self.headers.get("Host")
        if not origin or not host:
            return False
        scheme = self.headers.get("X-Forwarded-Proto", "http").split(",", 1)[0]
        return origin == f"{scheme}://{host}"

    def read_action(self):
        if not self.same_origin():
            raise ValueError("Action requests must come from this dashboard")
        if self.headers.get("X-Update-CSRF") != self.server.csrf_token:
            raise ValueError("The action token is missing or expired; reload the page")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("Invalid request length") from error
        if length <= 0 or length > 4096:
            raise ValueError("Invalid action request")
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError as error:
            raise ValueError("Invalid JSON request") from error

    def queue_scan(self, target):
        if target not in self.server.scan_units:
            raise ValueError("Unknown scan target")
        trigger = self.server.trigger_root / target
        temporary = trigger.with_name(f".{target}.{os.getpid()}.tmp")
        temporary.write_text("queued\n")
        os.replace(temporary, trigger)

    def queue_pull_request(self, kind, target):
        if not self.token_configured():
            raise RuntimeError("PR creation is not configured on this host")
        if kind == "container":
            if target not in self.server.container_names:
                raise ValueError("Unknown container service")
        elif kind == "action":
            actions = self.load_json("actions.json", {}).get("items", [])
            if target not in {item.get("name") for item in actions}:
                raise ValueError("Unknown GitHub Action")
        elif kind == "nix":
            target = "nix"
        else:
            raise ValueError("Unknown pull request type")

        safe_target = re.sub(r"[^A-Za-z0-9_.-]+", "--", target)
        result_path = self.server.results_root / f"{kind}--{safe_target}.json"
        existing = self.load_path_json(result_path, {})
        if existing.get("status") in ("queued", "running"):
            raise RuntimeError("A pull request job is already in progress")
        job = {"kind": kind, "target": target, "queuedAt": self.server.now()}
        self.atomic_json(result_path, {**job, "status": "queued"})
        self.atomic_json(
            self.server.queue_root / f"{secrets.token_hex(12)}.json",
            job,
        )

    @staticmethod
    def load_path_json(path, fallback=None):
        try:
            return json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return fallback

    @staticmethod
    def atomic_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        temporary.write_text(json.dumps(value, indent=2) + "\n")
        os.replace(temporary, path)

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
                        "actions": self.load_json("actions.json"),
                        "nix": self.load_json("nix.json"),
                    },
                    "history": list(reversed(self.load_json("history.json", []))),
                    "actions": self.action_status(),
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

    def do_POST(self):
        if urlparse(self.path).path != "/api/actions":
            self.send_json({"error": "not found"}, status=404)
            return
        try:
            request = self.read_action()
            if not isinstance(request, dict):
                raise ValueError("Action request must be a JSON object")
            action = request.get("action")
            if action == "scan":
                self.queue_scan(request.get("target"))
            elif action == "create-pr":
                self.queue_pull_request(request.get("kind"), request.get("target"))
            else:
                raise ValueError("Unknown action")
            self.send_json({"status": "queued"}, status=202)
        except ValueError as error:
            self.send_json({"error": str(error)}, status=400)
        except RuntimeError as error:
            self.send_json({"error": str(error)}, status=409)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8091)
    parser.add_argument("--static", required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--inventory")
    parser.add_argument("--systemctl", default="systemctl")
    parser.add_argument("--token")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.listen, args.port), DashboardHandler)
    server.static_root = Path(args.static)
    server.data_root = Path(args.data)
    server.trigger_root = server.data_root / "triggers"
    server.queue_root = server.data_root / "pr-queue"
    server.results_root = server.data_root / "pr-results"
    for directory in (server.trigger_root, server.queue_root, server.results_root):
        directory.mkdir(parents=True, exist_ok=True)
    inventory = DashboardHandler.load_path_json(
        Path(args.inventory) if args.inventory else server.data_root / "inventory.json",
        {"services": []},
    )
    server.container_names = {item["name"] for item in inventory.get("services", [])}
    server.systemctl = args.systemctl
    server.token_path = (
        Path(args.token) if args.token else server.data_root / "github-token"
    )
    server.csrf_token = secrets.token_urlsafe(32)
    server.now = lambda: dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    server.scan_units = {
        "releases": "updates-dashboard-oci-releases-report.service",
        "digests": "updates-dashboard-oci-digests-report.service",
        "actions": "updates-dashboard-actions-report.service",
        "nix": "updates-dashboard-nix-report.service",
    }
    print(f"Update dashboard listening on {args.listen}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
