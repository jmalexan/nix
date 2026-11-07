import concurrent.futures
import json
import time

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
)
from fastapi.testclient import TestClient
from notifications.api import Settings, create_app
from notifications.delivery import APNs, deliver
from notifications.models import Service


@pytest.fixture
def env(tmp_path):
    services = {
        "backup": Service(
            token="b" * 32, origins=["https://backup.example.com"], recipients=["owner"]
        ),
        "updates": Service(
            token="u" * 32,
            origins=["https://updates.example.com"],
            recipients=["owner"],
        ),
    }
    app = create_app(
        Settings(
            "https://notifications.example.com",
            str(tmp_path / "state.sqlite"),
            services,
        )
    )
    return app.state.store, TestClient(
        app, base_url="https://notifications.example.com"
    )


def auth(token):
    return {"Authorization": "Bearer " + token}


def enroll(env, recipient="owner", apns="a" * 64):
    store, client = env
    code = store.grant(recipient)
    response = client.post(
        "/v1/enroll",
        json={
            "code": code,
            "name": "iPhone",
            "apns_token": apns,
            "environment": "production",
        },
    )
    assert response.status_code == 201, response.text
    return response.json(), code


def publish(env, **changes):
    _, client = env
    body = {
        "recipient": "owner",
        "key": "backup-1",
        "title": "Backup failed",
        "url": "https://backup.example.com/jobs/1",
        "ttl": 600,
        "actions": [
            {"id": "retry", "title": "Retry", "kind": "respond"},
            {"id": "reply", "title": "Reply", "kind": "reply"},
        ],
        **changes,
    }
    return client.post("/v1/notifications", headers=auth("b" * 32), json=body)


def web_session(env, credential):
    _, client = env
    link = client.post(
        "/v1/device/settings", headers=auth(credential["token"]), json={}
    ).json()["url"]
    ticket = link.split("#")[1]
    result = client.post(
        "/v1/web/session",
        headers={"Origin": "https://notifications.example.com"},
        json={"ticket": ticket},
    )
    assert result.status_code == 200
    return ticket


def test_enrollment_is_one_time_and_credentials_are_hashed(env):
    store, client = env
    credential, code = enroll(env)
    assert (
        client.post(
            "/v1/enroll",
            json={
                "code": code,
                "name": "Other",
                "apns_token": "b" * 64,
                "environment": "production",
            },
        ).status_code
        == 403
    )
    assert client.get("/v1/web/settings", headers=auth("b" * 32)).status_code == 401
    with store.transaction() as db:
        assert (
            db.execute("SELECT token FROM devices").fetchone()[0] != credential["token"]
        )
        assert not db.execute("SELECT 1 FROM grants").fetchone()
    with store.transaction() as db:
        db.execute("UPDATE devices SET active=0")
    assert (
        client.post(
            "/v1/device/settings", headers=auth(credential["token"]), json={}
        ).status_code
        == 401
    )


def test_expired_enrollment_and_racing_claims(env):
    store, client = env
    expired = store.grant("owner")
    with store.transaction() as db:
        db.execute("UPDATE grants SET expires=0")
    body = {
        "code": expired,
        "name": "iPhone",
        "apns_token": "a" * 64,
        "environment": "production",
    }
    assert client.post("/v1/enroll", json=body).status_code == 403
    body["code"] = store.grant("owner")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        statuses = list(
            pool.map(
                lambda _: client.post("/v1/enroll", json=body).status_code, range(2)
            )
        )
    assert sorted(statuses) == [201, 403]


def test_service_scope_and_url_validation(env):
    _, client = env
    assert client.post("/v1/notifications", json={}).status_code == 401
    assert publish(env, recipient="stranger").status_code == 403
    for url in [
        "http://backup.example.com/",
        "https://backup.example.com.evil.com/",
        "https://x:secret@backup.example.com/",
        "https://backup.example.com:8443/",
        "https://backup.example.com/\\evil",
        "https://127.0.0.1/",
    ]:
        assert publish(env, url=url).status_code == 422
    assert publish(env, image="https://evil.com/photo.png").status_code == 422
    assert (
        publish(
            env,
            actions=[
                {
                    "id": "open",
                    "title": "Open",
                    "kind": "open",
                    "url": "https://evil.com",
                }
            ],
        ).status_code
        == 422
    )
    assert (
        publish(env, actions=[{"id": "x", "title": "X", "kind": "open"}]).status_code
        == 422
    )
    assert (
        publish(
            env, actions=[{"id": "x", "title": "X", "kind": "respond"}] * 2
        ).status_code
        == 422
    )
    assert (
        publish(
            env,
            url="https://backup.example.com/" + "a" * 1900,
            body="😀" * 500,
            title="😀" * 120,
        ).status_code
        == 422
    )


def test_dedupe_expiry_and_recipient_isolation(env):
    store, client = env
    credential, _ = enroll(env)
    other, _ = enroll(env, recipient="other", apns="b" * 64)
    first = publish(env)
    mid = first.json()["id"]
    assert first.status_code == 201
    assert publish(env).json()["id"] == mid
    assert publish(env, title="Changed").status_code == 409
    assert (
        client.get(
            f"/v1/device/notifications/{mid}", headers=auth(other["token"])
        ).status_code
        == 404
    )
    with store.transaction() as db:
        db.execute("UPDATE messages SET expires=0")
    assert (
        client.post(
            f"/v1/device/notifications/{mid}/response",
            headers=auth(credential["token"]),
            json={"action": "retry"},
        ).status_code
        == 409
    )
    sent = []
    deliver(store, lambda row, payload: sent.append(payload))
    assert not sent
    assert publish(env, key="expired", expires_at=time.time() - 1).status_code == 409


def test_responses_single_use_and_service_scoped(env):
    _, client = env
    credential, _ = enroll(env)
    second, _ = enroll(env, apns="b" * 64)
    mid = publish(env).json()["id"]
    path = f"/v1/device/notifications/{mid}/response"
    assert (
        client.post(path, headers=auth("b" * 32), json={"action": "retry"}).status_code
        == 401
    )
    assert (
        client.post(
            path, headers=auth(credential["token"]), json={"action": "reply"}
        ).status_code
        == 422
    )
    body = {"action": "reply", "text": "Please check the disk"}
    assert (
        client.post(path, headers=auth(credential["token"]), json=body).status_code
        == 200
    )
    assert (
        client.post(path, headers=auth(credential["token"]), json=body).status_code
        == 200
    )
    assert (
        client.post(
            path, headers=auth(second["token"]), json={"action": "retry"}
        ).status_code
        == 409
    )
    assert client.get("/v1/responses", headers=auth("u" * 32)).json() == []
    event = client.get("/v1/responses", headers=auth("b" * 32)).json()[0]
    assert event["text"] == body["text"] and event["key"] == "backup-1"
    assert (
        client.post(
            f"/v1/responses/{mid}/ack", headers=auth("u" * 32), json={}
        ).status_code
        == 404
    )
    assert (
        client.post(
            f"/v1/responses/{mid}/ack", headers=auth("b" * 32), json={}
        ).status_code
        == 200
    )
    assert client.get("/v1/responses", headers=auth("b" * 32)).json() == []


def test_racing_responses_choose_one(env):
    _, client = env
    first, _ = enroll(env)
    second, _ = enroll(env, apns="b" * 64)
    mid = publish(env).json()["id"]

    def answer(credential):
        return client.post(
            f"/v1/device/notifications/{mid}/response",
            headers=auth(credential["token"]),
            json={"action": "retry"},
        ).status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(answer, [first, second])) == [200, 409]


def test_settings_ticket_csrf_opt_out_and_revoke(env):
    store, client = env
    credential, _ = enroll(env)
    ticket = web_session(env, credential)
    assert (
        client.post(
            "/v1/web/session",
            headers={"Origin": "https://notifications.example.com"},
            json={"ticket": ticket},
        ).status_code
        == 403
    )
    assert client.get("/v1/web/settings").json()["services"] == {
        "backup": True,
        "updates": True,
    }
    assert (
        client.post("/v1/web/services/backup", json={"enabled": False}).status_code
        == 403
    )
    assert (
        client.post(
            "/v1/web/services/backup",
            headers={"Origin": "https://evil.com"},
            json={"enabled": False},
        ).status_code
        == 403
    )
    origin = {"Origin": "https://notifications.example.com"}
    assert (
        client.post(
            "/v1/web/services/backup", headers=origin, json={"enabled": False}
        ).status_code
        == 200
    )
    mid = publish(env).json()["id"]
    with store.transaction() as db:
        assert not db.execute(
            "SELECT 1 FROM deliveries WHERE message=?", (mid,)
        ).fetchone()
    assert client.post("/v1/web/revoke", headers=origin, json={}).status_code == 200
    assert client.get("/v1/web/settings").status_code == 401
    assert (
        client.post(
            "/v1/device/settings", headers=auth(credential["token"]), json={}
        ).status_code
        == 401
    )


def test_outbox_retry_lease_and_token_invalidation(env):
    store, _ = env
    enroll(env)
    publish(env)
    sent = []

    def send(row, body):
        sent.append(body)
        return (503, {}) if len(sent) == 1 else (200, {})

    now = time.time()
    deliver(store, send, now=lambda: now)
    deliver(store, send, now=lambda: now + 1)
    assert len(sent) == 1
    deliver(store, send, now=lambda: now + 10)
    assert len(sent) == 2
    assert sent[0]["bridge"]["url"] == "https://backup.example.com/jobs/1"
    assert "token" not in json.dumps(sent[0])
    publish(env, key="second")
    deliver(store, lambda *_: (410, {"reason": "Unregistered"}), now=lambda: now + 20)
    with store.transaction() as db:
        assert db.execute("SELECT active FROM devices").fetchone()[0] == 0


def test_apns_request_signing_and_environment():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    apns = APNs(pem, "KEY123", "TEAM123", "com.example.Bridge")
    seen = []

    def handler(request):
        seen.append(request)
        token = request.headers["authorization"].removeprefix("bearer ")
        assert (
            jwt.decode(token, key.public_key(), algorithms=["ES256"])["iss"]
            == "TEAM123"
        )
        return httpx.Response(200)

    apns.client.close()
    apns.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        for environment in ("sandbox", "production"):
            assert (
                apns(
                    {
                        "environment": environment,
                        "apns": "a" * 64,
                        "message": "id",
                        "expires": 2000000000,
                    },
                    {"aps": {"alert": "Test"}},
                )[0]
                == 200
            )
        assert seen[0].url.host == "api.sandbox.push.apple.com"
        assert seen[1].url.host == "api.push.apple.com"
        assert seen[1].headers["apns-topic"] == "com.example.Bridge"
        assert seen[1].headers["apns-expiration"] == "2000000000"
    finally:
        apns.client.close()


def test_boundaries_and_credential_rotation(env):
    _, client = env
    assert (
        client.get("/health", headers={"Host": "evil.example.com"}).status_code == 400
    )
    assert client.post("/v1/enroll", content="x" * 17000).status_code == 413
    credential, _ = enroll(env)
    new, _ = enroll(env)
    assert (
        client.post(
            "/v1/device/settings", headers=auth(credential["token"]), json={}
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/v1/device/settings", headers=auth(new["token"]), json={}
        ).status_code
        == 200
    )


def test_expired_responses_are_not_replayed_and_reset_revokes_devices(env, monkeypatch):
    from notifications.admin import main

    store, client = env
    credential, _ = enroll(env)
    mid = publish(env).json()["id"]
    result = client.post(
        f"/v1/device/notifications/{mid}/response",
        headers=auth(credential["token"]),
        json={"action": "retry"},
    )
    assert result.status_code == 200
    with store.transaction() as db:
        db.execute("UPDATE messages SET expires=?", (time.time() - 1,))
    assert client.get("/v1/responses", headers=auth("b" * 32)).json() == []
    monkeypatch.setattr(
        "sys.argv",
        ["admin", "--database", store.path, "reset-devices", "--confirm-reset"],
    )
    main()
    assert (
        client.post(
            "/v1/device/settings", headers=auth(credential["token"]), json={}
        ).status_code
        == 401
    )


def test_absolute_expiry_is_preserved_and_preferences_cancel_pending_delivery(env):
    store, client = env
    credential, _ = enroll(env)
    deadline = time.time() + 100
    result = publish(env, expires_at=deadline)
    assert result.json()["expires"] == deadline
    web_session(env, credential)
    assert (
        client.post(
            "/v1/web/services/backup",
            headers={"Origin": "https://notifications.example.com"},
            json={"enabled": False},
        ).status_code
        == 200
    )
    sent = []
    deliver(store, lambda *_: sent.append(True))
    assert sent == []


def test_preferred_short_settings_link_and_matching_host_origin(tmp_path):
    app = create_app(
        Settings(
            "https://notifications.example.com",
            str(tmp_path / "short.sqlite"),
            {},
            aliases=("https://notifications",),
            link_origin="https://notifications",
        )
    )
    full = TestClient(app, base_url="https://notifications.example.com")
    short = TestClient(app, base_url="https://notifications")
    device, _ = enroll((app.state.store, full))
    link = full.post(
        "/v1/device/settings", headers=auth(device["token"]), json={}
    ).json()["url"]
    assert link.startswith("https://notifications/#")
    ticket = link.split("#", 1)[1]
    assert (
        short.post(
            "/v1/web/session",
            json={"ticket": ticket},
            headers={"Origin": "https://notifications.example.com"},
        ).status_code
        == 403
    )
    assert (
        short.post(
            "/v1/web/session",
            json={"ticket": ticket},
            headers={"Origin": "https://notifications"},
        ).status_code
        == 200
    )
    assert short.get("/v1/web/settings").status_code == 200
    assert (
        short.get("/v1/web/settings", headers={"Host": "evil.test"}).status_code == 400
    )
