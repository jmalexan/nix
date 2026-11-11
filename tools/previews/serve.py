"""Preview-only factories with disposable accounts/data and no production workers."""

import json
import secrets
import shutil
import sys
import threading
import time
from pathlib import Path

import uvicorn

PASSWORD = "preview"


def static_files(repo, directory, app):
    output = directory / "static"
    shutil.rmtree(output, ignore_errors=True)
    if app == "approve":
        shutil.copytree(repo / "apps/microapps/web/dist", output)
        return output
    source = repo / (
        "apps/backups/web"
        if app == "backups"
        else "hosts/nasa/services/updates-dashboard"
    )
    shutil.copytree(
        source, output, ignore=shutil.ignore_patterns("*.py", "__pycache__", "*.nix")
    )
    shared = repo / "apps/microapps/web/src/shared"
    for name in ("components.js", "component-shadow.css"):
        shutil.copy(shared / name, output / name)
    shutil.copy(repo / "apps/microapps/web/dist-auth/auth.js", output / "auth.js")
    (output / "styles.css").write_text(
        "\n".join((shared / n).read_text() for n in ("tokens.css", "components.css"))
        + (source / "styles.css").read_text()
    )
    return output


def make_app(metadata, directory, socket):
    repo = Path(metadata["repo"])
    sys.path.insert(0, str(repo / "apps/microapps/backend"))
    static = str(static_files(repo, directory, metadata["app"]))
    common = dict(
        origin=metadata["origin"],
        database=str(directory / "app.sqlite"),
        enrollment_token="",
        static=static,
        account_socket=socket,
    )
    if metadata["app"] == "approve":
        from microapps.api import Settings, create_app

        app = create_app(
            Settings(
                **common,
                requester_token=secrets.token_urlsafe(32),
                worker_token=secrets.token_urlsafe(32),
            )
        )
        now = time.time()
        with app.state.store.transaction() as db:
            for key, state, reason in (
                ("sample-pending", "pending", "Preview: verify a harmless request"),
                ("sample-completed", "completed", "Preview: completed verification"),
                ("sample-denied", "denied", "Preview: denied request"),
            ):
                db.execute(
                    "INSERT OR IGNORE INTO requests VALUES(?,?,?,?,?,?,?,?)",
                    (
                        key,
                        "Preview",
                        reason,
                        "demo.verify",
                        state,
                        now,
                        now + 86400,
                        "Sample result" if state == "completed" else None,
                    ),
                )
        return app
    if metadata["app"] == "updates":
        sys.path.insert(0, str(repo / "hosts/nasa/services/updates-dashboard"))
        from updates_api import Settings, create_app

        reports = directory / "reports"
        reports.mkdir(exist_ok=True)
        sample = {
            "checkedAt": "2026-11-11T12:00:00Z",
            "items": [
                {
                    "name": "home-assistant",
                    "repository": "ghcr.io/home-assistant/home-assistant",
                    "currentTag": "2026.10.4",
                    "availableTag": "2026.11.0",
                    "status": "update",
                },
                {
                    "name": "frigate",
                    "repository": "ghcr.io/blakeblackshear/frigate",
                    "currentTag": "0.17.2",
                    "availableTag": "0.17.2",
                    "status": "current",
                },
            ],
        }
        if not (reports / "releases.json").exists():
            (reports / "releases.json").write_text(json.dumps(sample))
        return create_app(
            Settings(**common, data=str(reports), systemctl="/no-preview-systemctl")
        )
    sys.path.insert(0, str(repo / "apps/backups"))
    from api import Settings, create_app
    from models import Report, Run

    report = directory / "report.json"
    if not report.exists():
        report.write_text(
            Report(
                collected_at=time.time(),
                repository="Preview backup repository",
                paths=["/sample/data"],
                exclusions=[],
                retention=["--keep-daily 14"],
                retained_snapshots=34,
                backup=Run(last_success=time.time() - 1800, result="success"),
                backup_state="inactive",
                database_state="inactive",
                next_backup="Tomorrow at midnight",
            ).model_dump_json()
        )
    return create_app(Settings(**common, report=str(report)))


def main():
    directory = Path(sys.argv[1]).resolve()
    metadata = json.loads((directory / "instance.json").read_text())
    sys.path.insert(0, str(Path(metadata["repo"]) / "apps/microapps/backend"))
    from microapps.accounts import Account, create_app
    from microapps.auth_store import AuthStore

    account = Account(
        AuthStore(directory / "accounts.sqlite"), secrets.token_urlsafe(32)
    )
    if not account.status().password:
        account.enroll(PASSWORD, account.enrollment_token)
    # Short socket path stays below Linux's 108-byte limit even with long names.
    socket = str(directory / "account.sock")
    Path(socket).unlink(missing_ok=True)
    server = uvicorn.Server(
        uvicorn.Config(create_app(account), uds=socket, log_level="warning")
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 15
        while not server.started:
            if not thread.is_alive() or time.monotonic() > deadline:
                raise RuntimeError("Preview account service failed to start")
            time.sleep(0.01)
        uvicorn.run(
            make_app(metadata, directory, socket),
            host="127.0.0.1",
            port=metadata["port"],
            proxy_headers=False,
        )
    finally:
        server.should_exit = True
        thread.join(5)


if __name__ == "__main__":
    main()
