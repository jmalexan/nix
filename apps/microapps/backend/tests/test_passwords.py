import concurrent.futures
import dataclasses
import time

import pytest
from fastapi.testclient import TestClient
from microapps.api import Settings, create_app
from updates_api import Settings as UpdateSettings
from updates_api import create_app as create_updates

PASSWORD = "a long owner password for Bitwarden"
NEW_PASSWORD = "a different long password for Bitwarden"


@pytest.fixture(params=["approve", "updates"])
def app_clients(tmp_path, request):
    name = request.param
    full, short = f"https://{name}.example.test", f"https://{name}"
    if name == "approve":
        settings = Settings(
            full,
            str(tmp_path / "auth.db"),
            "r" * 32,
            "w" * 32,
            "e" * 32,
            aliases=(short,),
        )
        factory = create_app
    else:
        settings = UpdateSettings(
            full,
            str(tmp_path / "auth.db"),
            "e" * 32,
            str(tmp_path / "reports"),
            aliases=(short,),
        )
        factory = create_updates
    app = factory(settings)
    return (
        app,
        TestClient(app, base_url=full),
        TestClient(app, base_url=short),
        settings,
        factory,
    )


def post(client, path, body, csrf=None):
    return client.post(
        "/api/auth/password" + path,
        json=body,
        headers={
            "Origin": str(client.base_url).rstrip("/"),
            **({"X-CSRF-Token": csrf} if csrf else {}),
        },
    )


def enroll(client):
    response = post(client, "/enroll", {"password": PASSWORD, "token": "e" * 32})
    assert response.status_code == 200, response.text
    return client.get("/api/session").json()["csrf"]


def test_password_setup_short_and_full_logins_and_origin_isolation(app_clients):
    app, full, short, settings, factory = app_clients
    assert short.get("/api/auth/methods").json()["setup"] is True
    assert (
        post(short, "/enroll", {"password": PASSWORD, "token": "r" * 32}).status_code
        == 403
    )
    assert (
        post(short, "/enroll", {"password": "too short", "token": "e" * 32}).status_code
        == 422
    )
    csrf = enroll(short)
    cookie = short.cookies.get("__Host-microapp")
    with app.state.store.transaction() as db:
        row = db.execute("SELECT * FROM passwords").fetchone()
        assert row["hash"] != PASSWORD.encode() and len(row["salt"]) == 32
    assert full.get("/api/session").status_code == 401
    # An allowed Origin is still rejected if it does not match this request's Host.
    assert (
        short.post(
            "/api/auth/password/login",
            json={"password": PASSWORD},
            headers={"Origin": settings.origin},
        ).status_code
        == 403
    )
    assert short.get("/api/session", headers={"Host": "evil.test"}).status_code == 400
    full.cookies.set("__Host-microapp", cookie)
    assert full.get("/api/session").status_code == 401
    full.cookies.clear()
    assert post(full, "/login", {"password": "incorrect"}).status_code == 401
    response = post(full, "/login", {"password": PASSWORD})
    assert response.status_code == 200
    assert all(
        value in response.headers["set-cookie"].lower()
        for value in ("httponly", "secure", "samesite=strict")
    )
    assert "domain=" not in response.headers["set-cookie"].lower()
    assert short.get("/api/session").json()["csrf"] == csrf
    assert (
        post(
            short, "/enroll", {"password": NEW_PASSWORD, "token": "e" * 32}
        ).status_code
        == 403
    )
    assert (
        short.post(
            "/api/auth/enroll/options",
            json={"token": "e" * 32},
            headers={"Origin": str(short.base_url).rstrip("/")},
        ).status_code
        == 403
    )
    # Persisted password and sessions survive a restart without an auth reset.
    restarted = TestClient(factory(settings), base_url=str(short.base_url))
    restarted.cookies.update(short.cookies)
    assert restarted.get("/api/session").status_code == 200
    assert post(restarted, "/login", {"password": PASSWORD}).status_code == 200


def test_password_management_is_not_exposed(app_clients):
    app, full, short, *_ = app_clients
    csrf = enroll(full)
    for client in (full, short):
        assert post(client, "", {"password": NEW_PASSWORD}, csrf).status_code == 404
    assert post(short, "/login", {"password": PASSWORD}).status_code == 200


def test_rate_limit_persists_and_cannot_be_bypassed_by_switching_host(
    app_clients, monkeypatch
):
    app, full, short, settings, factory = app_clients
    # Exercise persistent reservation, not expensive KDF timings in this test.
    monkeypatch.setattr("microapps.accounts.password_hash", lambda *_: b"dummy")
    for _ in range(10):
        assert post(short, "/login", {"password": "wrong"}).status_code == 401
    response = post(full, "/login", {"password": "wrong"})
    assert response.status_code == 429
    assert int(response.headers["Retry-After"]) > 0
    restarted = TestClient(factory(settings), base_url=settings.origin)
    assert post(restarted, "/login", {"password": "wrong"}).status_code == 429
    with app.state.store.transaction() as db:
        db.execute("UPDATE password_attempts SET created=?", (time.time() - 61,))
    assert post(full, "/login", {"password": "wrong"}).status_code == 401


def test_enrollment_is_atomic_and_aliases_cannot_add_arbitrary_origins(app_clients):
    app, full, short, settings, factory = app_clients

    def setup(client):
        return post(
            client, "/enroll", {"password": PASSWORD, "token": "e" * 32}
        ).status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(setup, (full, short))) == [200, 403]
    for alias in (
        "https://user:secret@evil.test",
        "http://evil.test",
        "https://evil.test/path",
        settings.origin,
    ):
        with pytest.raises(ValueError, match="Aliases"):
            factory(dataclasses.replace(settings, aliases=(alias,)))
