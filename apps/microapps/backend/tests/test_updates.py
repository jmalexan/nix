import time

import pytest
from fastapi.testclient import TestClient
from microapps.auth_admin import provision
from microapps.auth_store import digest
from updates_api import Settings, create_app


@pytest.fixture
def updates(tmp_path):
    static = tmp_path / "static"
    static.mkdir()
    (static / "index.html").write_text("Sign in shell")
    app = create_app(
        Settings(
            "https://updates.example.test",
            str(tmp_path / "auth/state.sqlite"),
            "u" * 32,
            str(tmp_path / "reports"),
            str(static),
            systemctl="/no-such-systemctl",
        )
    )
    return app, TestClient(app, base_url="https://updates.example.test")


def login(app, client):
    with app.state.store.transaction() as db:
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (digest("updates-session"), "updates-csrf", time.time() + 60),
        )
    client.cookies.set("__Host-microapp", "updates-session")
    return {"Origin": "https://updates.example.test", "X-CSRF-Token": "updates-csrf"}


def test_all_dashboard_and_legacy_routes_require_a_session(updates):
    app, client = updates
    assert client.get("/").status_code == 200
    assert client.get("/health").status_code == 200
    for path in (
        "/api/status",
        "/pipeline/reports",
        "/pipeline/reports/nix.json",
        "/pipeline/reports/",
        "/pipeline/reports/history.json",
    ):
        assert client.get(path, follow_redirects=False).status_code == 401
    assert client.head("/pipeline/reports/nix.json").status_code == 401
    assert (
        client.get(
            "/api/status", headers={"Authorization": "Bearer " + "r" * 32}
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/api/actions", json={"action": "scan", "target": "nix"}
        ).status_code
        == 401
    )
    assert not list(app.state.dashboard.server.trigger_root.iterdir())
    assert client.get("/nix.json").status_code == 404


def test_actions_require_origin_and_session_csrf(updates):
    app, client = updates
    headers = login(app, client)
    body = {"action": "scan", "target": "containers"}
    assert client.post("/api/actions", json=body).status_code == 403
    assert (
        client.post(
            "/api/actions",
            json=body,
            headers={"Origin": headers["Origin"], "X-Update-CSRF": "updates-csrf"},
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/actions",
            json=body,
            headers={**headers, "Origin": "https://approve.example.test"},
        ).status_code
        == 403
    )
    assert not list(app.state.dashboard.server.trigger_root.iterdir())
    assert (
        client.head("/pipeline/reports/nix.json", follow_redirects=False).status_code
        == 302
    )
    assert client.post("/api/actions", json=body, headers=headers).status_code == 202
    assert (
        app.state.dashboard.server.trigger_root / "containers"
    ).read_text() == "queued\n"
    assert (
        client.post(
            "/api/actions", json={**body, "extra": True}, headers=headers
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/actions",
            json={**body, "target": "arbitrary.service"},
            headers=headers,
        ).status_code
        == 422
    )
    status = client.get("/api/status")
    assert status.status_code == 200
    assert "csrfToken" not in status.json()["actions"]
    assert (
        client.get("/pipeline/reports/nix.json", follow_redirects=False).status_code
        == 302
    )


def test_logout_expiry_and_other_app_cookies_are_rejected(updates):
    app, client = updates
    client.cookies.set("__Host-microapp", "approval-app-session")
    assert client.get("/api/session").status_code == 401
    headers = login(app, client)
    assert client.get("/api/session").json() == {"csrf": "updates-csrf"}
    assert client.post("/api/logout", json={}, headers=headers).status_code == 200
    assert client.get("/api/status").status_code == 401
    headers = login(app, client)
    with app.state.store.transaction() as db:
        db.execute("UPDATE sessions SET expires=0")
    assert client.get("/api/status").status_code == 401
    assert (
        client.post(
            "/api/actions", json={"action": "scan", "target": "nix"}, headers=headers
        ).status_code
        == 401
    )


def test_enrollment_is_origin_bound_and_requires_private_setup_code(updates):
    app, client = updates
    assert (
        client.post("/api/auth/enroll/options", json={"token": "u" * 32}).status_code
        == 403
    )
    headers = {"Origin": "https://updates.example.test"}
    assert (
        client.post(
            "/api/auth/enroll/options", json={"token": "e" * 32}, headers=headers
        ).status_code
        == 403
    )
    options = client.post(
        "/api/auth/enroll/options", json={"token": "u" * 32}, headers=headers
    )
    assert options.status_code == 200
    assert options.json()["options"]["rp"] == {
        "id": "updates.example.test",
        "name": "System updates",
    }
    body = {"challenge_id": options.json()["challenge_id"], "credential": {}}
    assert (
        client.post("/api/auth/enroll/verify", json=body, headers=headers).status_code
        == 400
    )
    assert (
        client.post("/api/auth/enroll/verify", json=body, headers=headers).status_code
        == 400
    )
    with app.state.store.transaction() as db:
        assert db.execute("SELECT count(*) FROM credentials").fetchone()[0] == 0


def test_setup_credential_is_private_and_never_rotated_implicitly(tmp_path, capsys):
    path = tmp_path / "private/enrollment"
    provision(path)
    original = path.read_text()
    provision(path)
    assert path.read_text() == original
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700
    assert original.strip() not in capsys.readouterr().out
    path.chmod(0o644)
    with pytest.raises(ValueError):
        provision(path)
    path.unlink()
    path.symlink_to(tmp_path / "target")
    with pytest.raises(OSError):
        provision(path)


def test_pr_queue_requires_human_and_keeps_reporter_access(updates):
    import os

    app, client = updates
    dashboard = app.state.dashboard.server
    dashboard.token_path.write_text("test-only-github-credential")
    body = {"action": "create-pr", "kind": "container", "target": "all"}
    assert client.post("/api/actions", json=body).status_code == 401
    assert not list(dashboard.queue_root.iterdir())
    headers = login(app, client)
    previous = os.umask(0o027)
    try:
        assert (
            client.post("/api/actions", json=body, headers=headers).status_code == 202
        )
    finally:
        os.umask(previous)
    queued = list(dashboard.queue_root.glob("*.json"))
    assert len(queued) == 1
    assert queued[0].stat().st_mode & 0o777 == 0o640
    assert app.state.store.path.stat().st_mode & 0o777 == 0o600
    assert app.state.store.path.parent.stat().st_mode & 0o777 == 0o700
    assert client.post("/api/actions", json=body, headers=headers).status_code == 409
