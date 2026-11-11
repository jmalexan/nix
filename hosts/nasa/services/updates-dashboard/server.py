import json
import os
import re
import secrets
import subprocess

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


class DashboardHandler:
    """Report and queue operations; HTTP authorization lives in updates_api."""

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
            "prConfigured": self.app_configured(),
            "jobs": jobs | {"pr": self.job_state("updates-dashboard-pr.service")},
            "pullRequests": results,
        }

    def app_configured(self):
        try:
            return (
                self.server.app_key_path.is_file()
                and self.server.app_key_path.stat().st_size > 0
            )
        except OSError:
            return False

    def queue_scan(self, target):
        if target not in self.server.scan_units:
            raise ValueError("Unknown scan target")
        trigger = self.server.trigger_root / target
        temporary = trigger.with_name(f".{target}.{os.getpid()}.tmp")
        temporary.write_text("queued\n")
        os.replace(temporary, trigger)

    def queue_pull_request(self, kind, target):
        if not self.app_configured():
            raise RuntimeError("PR creation is not configured on this host")
        if kind == "container":
            if target != "all" and target not in self.server.container_names:
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
        active_statuses = ("queued", "running", "complete", "open")
        if existing.get("status") in active_statuses:
            raise RuntimeError("A pull request already exists or is being created")
        if kind == "container":
            if target == "all":
                possible_conflicts = self.server.results_root.glob("container--*.json")
            else:
                possible_conflicts = [self.server.results_root / "container--all.json"]
            for path in possible_conflicts:
                if path == result_path:
                    continue
                result = self.load_path_json(path, {})
                if result.get("status") in active_statuses:
                    raise RuntimeError(
                        "Another pull request already covers this container update"
                    )
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
