"""Backups uses the real private account service and independent host sessions."""

import threading
import time

import pytest
import uvicorn
from api import Settings, create_app
from fastapi.testclient import TestClient
from microapps.accounts import Account
from microapps.accounts import create_app as account_app
from microapps.auth_store import AuthStore
from updates_api import Settings as UpdateSettings
from updates_api import create_app as updates_app

PASSWORD = "one shared password for NASA apps"


@pytest.fixture
def shared(tmp_path):
    account = Account(AuthStore(tmp_path / "accounts/db"), "e" * 32)
    socket = str(tmp_path / "a.sock")
    server = uvicorn.Server(
        uvicorn.Config(account_app(account), uds=socket, log_level="error")
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert thread.is_alive() and time.monotonic() < deadline
        time.sleep(0.01)
    app = create_app(
        Settings(
            "https://backups.example.test",
            str(tmp_path / "backups/db"),
            "",
            str(tmp_path / "report.json"),
            aliases=("https://backups",),
            account_socket=socket,
        )
    )
    updates = updates_app(
        UpdateSettings(
            "https://updates.example.test",
            str(tmp_path / "updates/db"),
            "",
            str(tmp_path / "reports"),
            aliases=("https://updates",),
            account_socket=socket,
        )
    )
    try:
        yield (
            account,
            app,
            TestClient(app, base_url="https://backups"),
            TestClient(updates, base_url="https://updates"),
            server,
        )
    finally:
        server.should_exit = True
        thread.join(10)
        assert not thread.is_alive()


def post(client, action, body):
    return client.post(
        "/api/auth/password/" + action,
        json=body,
        headers={"Origin": str(client.base_url).rstrip("/")},
    )


def test_shared_account(shared):
    account, app, short, updates, _ = shared
    assert short.get("/api/status").status_code == 401
    assert (
        post(updates, "enroll", {"token": "e" * 32, "password": PASSWORD}).status_code
        == 200
    )
    assert short.get("/api/auth/methods").json() == {
        "password": True,
        "passkey": False,
        "setup": False,
    }
    assert post(short, "login", {"password": PASSWORD}).status_code == 200
    assert short.get("/api/status").status_code == 200
    full = TestClient(app, base_url="https://backups.example.test")
    # Copying a valid short-host cookie to the full hostname must not grant a session.
    full.cookies.set("__Host-microapp", short.cookies.get("__Host-microapp"))
    assert full.get("/api/status").status_code == 401
    assert post(full, "login", {"password": PASSWORD}).status_code == 200
    assert full.get("/api/status").status_code == 200
    with app.state.store.transaction() as db:
        assert db.execute("SELECT count(*) FROM passwords").fetchone()[0] == 0
    assert short.post("/api/logout", json={}).status_code == 403
    csrf = short.get("/api/session").json()["csrf"]
    assert (
        short.post(
            "/api/logout",
            json={},
            headers={"Origin": "https://backups.example.test", "X-CSRF-Token": csrf},
        ).status_code
        == 403
    )
    assert (
        short.post(
            "/api/logout",
            json={},
            headers={"Origin": "https://backups", "X-CSRF-Token": csrf},
        ).status_code
        == 200
    )
    assert full.get("/api/status").status_code == 200
    assert updates.get("/api/session").status_code == 200
    assert short.get("/api/status").status_code == 401


def test_account_reset_and_outage(shared):
    account, app, client, updates, server = shared
    assert (
        post(updates, "enroll", {"token": "e" * 32, "password": PASSWORD}).status_code
        == 200
    )
    assert post(client, "login", {"password": PASSWORD}).status_code == 200
    account.reset()
    assert client.get("/api/status").status_code == 401
    account.enroll(PASSWORD, "e" * 32)
    assert client.get("/api/status").status_code == 401
    assert post(client, "login", {"password": PASSWORD}).status_code == 200
    server.should_exit = True
    deadline = time.monotonic() + 10
    while server.started and time.monotonic() < deadline:
        if not server.servers[0].is_serving():
            break
        time.sleep(0.01)
    assert client.get("/api/status").status_code == 503
    assert post(client, "login", {"password": PASSWORD}).status_code == 503
    assert (
        client.post(
            "/api/auth/enroll/options",
            json={"token": "b" * 32},
            headers={"Origin": "https://backups"},
        ).status_code
        == 403
    )


def test_production_requires_account_socket(monkeypatch):
    from api import from_environment

    monkeypatch.setenv("BACKUPS_ORIGIN", "https://backups.example.test")
    monkeypatch.setenv("BACKUPS_DATABASE", "/unused")
    monkeypatch.delenv("MICROAPP_ACCOUNT_SOCKET", raising=False)
    with pytest.raises(KeyError, match="MICROAPP_ACCOUNT_SOCKET"):
        from_environment()
