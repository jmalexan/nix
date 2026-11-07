import concurrent.futures
import json
import time

import pytest
from fastapi.testclient import TestClient
from microapps.api import Settings, create_app
from microapps.notify import deliver
from microapps.store import digest


@pytest.fixture
def env(tmp_path):
    settings = Settings(
        "https://approve.example.test",
        str(tmp_path / "data.sqlite"),
        "r" * 32,
        "w" * 32,
        "e" * 32,
    )
    app = create_app(settings)
    client = TestClient(app, base_url=settings.origin)
    return app, client


def human(app, client):
    with app.state.store.transaction() as db:
        db.execute(
            "INSERT OR REPLACE INTO sessions VALUES(?,?,?)",
            (digest("test-session"), "csrf", time.time() + 60),
        )
    client.cookies.set("__Host-microapp", "test-session")
    return {"Origin": "https://approve.example.test", "X-CSRF-Token": "csrf"}


def submit(client):
    response = client.post(
        "/api/requests",
        json={"operation": "demo.verify", "reason": "Verify approval flow"},
        headers={"Authorization": "Bearer " + "r" * 32},
    )
    assert response.status_code == 201, response.text
    return response.json()["id"]


def test_machine_cannot_decide_or_enroll(env):
    app, client = env
    rid = submit(client)
    assert (
        client.post(
            f"/api/requests/{rid}/decision",
            json={"decision": "approve"},
            headers={"Authorization": "Bearer " + "r" * 32},
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/api/auth/enroll/options",
            json={"token": "r" * 32},
            headers={"Origin": "https://approve.example.test"},
        ).status_code
        == 403
    )
    assert (
        client.post(
            f"/api/worker/{rid}/verify", headers={"Authorization": "Bearer " + "r" * 32}
        ).status_code
        == 401
    )


def test_csrf_and_origin(env):
    app, client = env
    rid = submit(client)
    headers = human(app, client)
    for h in (
        {},
        {"Origin": headers["Origin"]},
        {**headers, "Origin": "https://evil.test"},
    ):
        assert (
            client.post(
                f"/api/requests/{rid}/decision", json={"decision": "approve"}, headers=h
            ).status_code
            == 403
        )
    assert client.get("/api/requests", headers={"Host": "evil.test"}).status_code == 400


def test_claim_is_atomic_and_survives_restart(env):
    app, client = env
    rid = submit(client)
    assert (
        client.post(
            f"/api/worker/{rid}/verify", headers={"Authorization": "Bearer " + "w" * 32}
        ).status_code
        == 409
    )
    assert (
        client.post(
            f"/api/requests/{rid}/decision",
            json={"decision": "approve"},
            headers=human(app, client),
        ).status_code
        == 200
    )

    def claim(_):
        return client.post(
            f"/api/worker/{rid}/verify", headers={"Authorization": "Bearer " + "w" * 32}
        ).status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(claim, range(6)))
    assert results.count(200) == 1
    assert results.count(409) == 5
    from microapps.store import Store

    with Store(app.state.store.path).transaction() as db:
        assert (
            db.execute("SELECT state FROM requests WHERE id=?", (rid,)).fetchone()[0]
            == "completed"
        )
        assert (
            db.execute("SELECT count(*) FROM events WHERE event='claimed'").fetchone()[
                0
            ]
            == 1
        )


@pytest.mark.parametrize("state", ["pending", "approved", "denied"])
def test_expired_and_denied_cannot_execute(env, state):
    app, client = env
    rid = submit(client)
    with app.state.store.transaction() as db:
        db.execute(
            "UPDATE requests SET state=?,expires=? WHERE id=?",
            (state, time.time() - 1, rid),
        )
    assert (
        client.post(
            f"/api/worker/{rid}/verify", headers={"Authorization": "Bearer " + "w" * 32}
        ).status_code
        == 409
    )


def test_challenges_single_use_and_wrong_origin(env):
    app, client = env
    headers = {"Origin": "https://approve.example.test"}
    challenge = client.post(
        "/api/auth/enroll/options", json={"token": "e" * 32}, headers=headers
    ).json()
    assert challenge["options"]["rp"]["id"] == "approve.example.test"
    body = {"challenge_id": challenge["challenge_id"], "credential": {}}
    assert (
        client.post("/api/auth/enroll/verify", json=body, headers=headers).status_code
        == 400
    )
    with pytest.raises(ValueError):
        app.state.store.consume_challenge(challenge["challenge_id"], "enroll")
    assert (
        client.post(
            "/api/auth/login/options", headers={"Origin": "https://evil.test"}
        ).status_code
        == 403
    )


def test_logout_revokes_session(env):
    app, client = env
    headers = human(app, client)
    assert client.get("/api/session").status_code == 200
    assert client.post("/api/logout", headers=headers).status_code == 200
    client.cookies.set("__Host-microapp", "test-session")
    assert client.get("/api/session").status_code == 401


@pytest.mark.parametrize("link_origin", [None, "https://approve"])
def test_push_outbox_and_expiry(env, link_origin):
    app, client = env
    with app.state.store.transaction() as db:
        db.execute(
            "INSERT INTO subscriptions VALUES(?,?)",
            (
                "device",
                json.dumps({"endpoint": "https://web.push.apple.com/test", "keys": {}}),
            ),
        )
    rid = submit(client)
    sent = []
    deliver(
        app.state.store,
        "unused",
        "mailto:test@example.test",
        send=lambda **kw: sent.append(kw),
        app_origin=link_origin,
    )
    deliver(
        app.state.store,
        "unused",
        "mailto:test@example.test",
        send=lambda **kw: sent.append(kw),
    )
    expected = {"request_id": rid}
    if link_origin:
        expected["url"] = "https://approve/?request=" + rid
    assert len(sent) == 1 and json.loads(sent[0]["data"]) == expected
    rid = submit(client)
    with app.state.store.transaction() as db:
        db.execute("UPDATE requests SET expires=0 WHERE id=?", (rid,))
    deliver(
        app.state.store,
        "unused",
        "mailto:test@example.test",
        send=lambda **kw: sent.append(kw),
    )
    assert len(sent) == 1


def test_input_and_push_endpoint_validation(env):
    app, client = env
    assert (
        client.post(
            "/api/requests",
            json={"operation": "ssh", "reason": "test"},
            headers={"Authorization": "Bearer " + "r" * 32},
        ).status_code
        == 422
    )
    headers = human(app, client)
    for endpoint in [
        "https://127.0.0.1/private",
        "https://web.push.apple.com.evil.test/",
        "http://web.push.apple.com/",
    ]:
        assert (
            client.post(
                "/api/subscriptions",
                json={"endpoint": endpoint, "keys": {"auth": "x", "p256dh": "y"}},
                headers=headers,
            ).status_code
            == 422
        )
