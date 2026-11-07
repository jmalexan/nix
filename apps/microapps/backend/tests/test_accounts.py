import concurrent.futures
import sys
import threading
import time

import pytest
import uvicorn
from fastapi import HTTPException
from fastapi.testclient import TestClient
from microapps.accounts import Account, AccountClient
from microapps.accounts import create_app as account_app
from microapps.api import Settings, create_app
from microapps.auth_admin import main as auth_admin
from microapps.auth_store import AuthStore, digest
from updates_api import Settings as UpdateSettings
from updates_api import create_app as update_app

PASSWORD = "one long password for both tools"
NEW_PASSWORD = "a recreated owner account password"


@pytest.fixture
def shared(tmp_path):
    account = Account(AuthStore(tmp_path / "accounts/db"), "e" * 32)
    socket = str(tmp_path / "accounts.sock")
    server = uvicorn.Server(
        uvicorn.Config(account_app(account), uds=socket, log_level="error")
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert thread.is_alive() and time.monotonic() < deadline
        time.sleep(0.01)
    apps = {
        "approve": create_app(
            Settings(
                "https://approve.example.test",
                str(tmp_path / "approve/db"),
                "r" * 32,
                "w" * 32,
                "",
                aliases=("https://approve",),
                account_socket=socket,
            )
        ),
        "updates": update_app(
            UpdateSettings(
                "https://updates.example.test",
                str(tmp_path / "updates/db"),
                "",
                str(tmp_path / "reports"),
                aliases=("https://updates",),
                account_socket=socket,
            )
        ),
    }
    clients = {
        name: TestClient(app, base_url=f"https://{name}") for name, app in apps.items()
    }
    try:
        yield account, apps, clients, socket
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


def enroll(client, password=PASSWORD):
    result = post(client, "enroll", {"password": password, "token": "e" * 32})
    assert result.status_code == 200, result.text


def test_create_once_and_login_directly_to_both_apps_and_origins(shared):
    account, apps, clients, socket = shared
    approve, updates = clients.values()
    assert (
        post(updates, "enroll", {"password": PASSWORD, "token": "r" * 32}).status_code
        == 403
    )
    assert (
        post(updates, "enroll", {"password": PASSWORD, "token": "é" * 32}).status_code
        == 403
    )
    assert (
        post(updates, "enroll", {"password": "short", "token": "e" * 32}).status_code
        == 422
    )
    enroll(approve)
    assert updates.get("/api/auth/methods").json() == {
        "password": True,
        "passkey": False,
        "setup": False,
    }
    assert updates.get("/api/session").status_code == 401
    assert post(updates, "login", {"password": PASSWORD}).status_code == 200
    assert updates.get("/api/session").status_code == 200
    for name, app in apps.items():
        full = TestClient(app, base_url=f"https://{name}.example.test")
        assert full.get("/api/session").status_code == 401
        assert post(full, "login", {"password": PASSWORD}).status_code == 200
        assert full.get("/api/session").status_code == 200
        with app.state.store.transaction() as db:
            assert db.execute("SELECT count(*) FROM passwords").fetchone()[0] == 0
        assert (
            post(
                clients[name], "enroll", {"password": NEW_PASSWORD, "token": "e" * 32}
            ).status_code
            == 403
        )
    # Even copying a cookie to another app does not create a shared session.
    updates.cookies.clear()
    updates.cookies.set("__Host-microapp", approve.cookies.get("__Host-microapp"))
    assert updates.get("/api/session").status_code == 401
    assert (
        Account(AuthStore(account.store.path), "e" * 32).status().generation
        == account.status().generation
    )
    assert AccountClient(socket).status().password is True


def test_local_reset_recreates_account_and_revokes_sessions_everywhere(
    shared, monkeypatch
):
    account, apps, clients, _ = shared
    approve, updates = clients.values()
    enroll(approve)
    assert post(updates, "login", {"password": PASSWORD}).status_code == 200
    previous = account.status().generation
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "microapp-auth-admin",
            "reset",
            "--database",
            str(account.store.path),
            "--confirm-reset",
        ],
    )
    auth_admin()
    assert account.status().generation != previous
    for client in clients.values():
        assert client.get("/api/session").status_code == 401
        assert client.get("/api/auth/methods").json()["setup"] is True
    # Old per-app sessions remain in their own databases, but their account
    # generation is invalid even after the replacement account is enrolled.
    fresh = TestClient(apps["approve"], base_url="https://approve")
    enroll(fresh, NEW_PASSWORD)
    for client in clients.values():
        assert client.get("/api/session").status_code == 401
        assert post(client, "login", {"password": PASSWORD}).status_code == 401
        assert post(client, "login", {"password": NEW_PASSWORD}).status_code == 200


def test_old_local_credentials_and_passkeys_cannot_bypass_shared_account(shared):
    _, apps, clients, _ = shared
    for name, app in apps.items():
        with app.state.store.transaction() as db:
            db.execute(
                "INSERT INTO sessions VALUES(?,?,?)",
                (digest("old-session"), "csrf", time.time() + 60),
            )
            db.execute("INSERT INTO credentials VALUES('old', 'public-key', 0)")
        clients[name].cookies.set("__Host-microapp", "old-session")
        assert clients[name].get("/api/session").status_code == 401
        assert (
            clients[name]
            .post(
                "/api/auth/login/options",
                json={},
                headers={"Origin": f"https://{name}"},
            )
            .status_code
            == 403
        )
        assert clients[name].get("/api/auth/methods").json()["setup"] is True
    enroll(clients["updates"])
    assert post(clients["approve"], "login", {"password": PASSWORD}).status_code == 200


def test_shared_setup_is_atomic_and_has_no_management_endpoint(shared):
    account, apps, clients, _ = shared

    def setup(client):
        return post(
            client, "enroll", {"password": PASSWORD, "token": "e" * 32}
        ).status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(setup, clients.values())) == [200, 403]
    for name, client in clients.items():
        assert (
            client.post(
                "/api/auth/password",
                json={"password": NEW_PASSWORD},
                headers={"Origin": f"https://{name}"},
            ).status_code
            == 404
        )
    broker = TestClient(account_app(account))
    assert (
        broker.post("/account/password", json={"password": NEW_PASSWORD}).status_code
        == 404
    )
    assert broker.delete("/account").status_code == 405
    assert broker.post("/account/reset", json={}).status_code == 404


def test_login_limits_are_shared_between_apps_and_survive_service_restart(
    shared, monkeypatch
):
    account, _, clients, _ = shared
    monkeypatch.setattr("microapps.accounts.password_hash", lambda *_: b"dummy")
    for index in range(10):
        assert (
            post(
                list(clients.values())[index % 2], "login", {"password": "wrong"}
            ).status_code
            == 401
        )
    assert post(clients["updates"], "login", {"password": "wrong"}).status_code == 429
    assert Account(AuthStore(account.store.path), "e" * 32).status().password is False
    with pytest.raises(HTTPException) as error:
        Account(AuthStore(account.store.path), "e" * 32).login("wrong")
    assert error.value.status_code == 429


def test_account_service_failure_closes_sessions_and_never_falls_back(
    shared, monkeypatch
):
    account, _, clients, socket = shared
    enroll(clients["approve"])
    with pytest.raises(HTTPException) as error:
        AccountClient(socket + ".missing").status()
    assert error.value.status_code == 503

    def unavailable(*_):
        raise HTTPException(503, "Account service unavailable")

    monkeypatch.setattr(AccountClient, "request", unavailable)
    assert clients["approve"].get("/api/session").status_code == 503
    assert post(clients["updates"], "login", {"password": PASSWORD}).status_code == 503
    assert (
        clients["approve"]
        .post(
            "/api/auth/password/login",
            json={"password": PASSWORD},
            headers={"Origin": "https://evil.test"},
        )
        .status_code
        == 403
    )
