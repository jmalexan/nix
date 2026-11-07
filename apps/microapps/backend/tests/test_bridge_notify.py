import time

import pytest
from fastapi.testclient import TestClient
from microapps.api import Settings, create_app
from microapps.bridge_notify import deliver_bridge


def test_bridge_adapter_is_transactional_and_publishes_choices(tmp_path):
    settings = Settings(
        "https://approve.example.com",
        str(tmp_path / "state.sqlite"),
        "r" * 32,
        "w" * 32,
        "e" * 32,
        notification_bridge=True,
    )
    app = create_app(settings)
    client = TestClient(app, base_url=settings.origin)
    result = client.post(
        "/api/requests",
        headers={"Authorization": "Bearer " + "r" * 32},
        json={"operation": "demo.verify", "reason": "Test"},
    )
    rid = result.json()["id"]
    sent = []

    def send(origin, token, path, body):
        sent.append(body)
        assert (
            origin == "https://notifications.example.com"
            and path == "/v1/notifications"
        )

    def run():
        deliver_bridge(
            app.state.store,
            "https://notifications.example.com",
            "secret",
            "owner",
            settings.origin,
            send=send,
        )

    run()
    run()
    assert len(sent) == 1
    assert sent[0]["key"] == rid
    assert sent[0]["actions"][-1]["kind"] == "open"
    assert sent[0]["expires_at"] == result.json()["expires"]
    assert "secret" not in str(sent)
    with app.state.store.transaction() as db:
        assert db.execute("SELECT state FROM requests").fetchone()[0] == "pending"
        db.execute("UPDATE notification_bridge_outbox SET done=0,next_attempt=0")
        db.execute("UPDATE requests SET expires=?", (time.time() - 1,))
    run()
    assert len(sent) == 1


def test_bridge_failure_keeps_durable_outbox(tmp_path):
    app = create_app(
        Settings(
            "https://approve.example.com",
            str(tmp_path / "state.sqlite"),
            "r" * 32,
            "w" * 32,
            "e" * 32,
            notification_bridge=True,
        )
    )
    client = TestClient(app, base_url="https://approve.example.com")
    client.post(
        "/api/requests",
        headers={"Authorization": "Bearer " + "r" * 32},
        json={"operation": "demo.verify", "reason": "Test"},
    )

    def failed(*args):
        raise OSError("Offline")

    deliver_bridge(
        app.state.store,
        "https://notifications.example.com",
        "secret",
        "owner",
        "https://approve.example.com",
        send=failed,
    )
    with app.state.store.transaction() as db:
        row = db.execute("SELECT * FROM notification_bridge_outbox").fetchone()
        assert row["done"] == 0 and row["attempts"] == 1


def fixture_request(tmp_path, reason="Test"):
    app = create_app(
        Settings(
            "https://approve.example.com",
            str(tmp_path / "state.sqlite"),
            "r" * 32,
            "w" * 32,
            "e" * 32,
            notification_bridge=True,
        )
    )
    client = TestClient(app, base_url="https://approve.example.com")
    request = client.post(
        "/api/requests",
        headers={"Authorization": "Bearer " + "r" * 32},
        json={"operation": "demo.verify", "reason": reason},
    ).json()
    sent = []
    deliver_bridge(
        app.state.store,
        "https://notifications.example.com",
        "secret",
        "owner",
        "https://approve.example.com",
        send=lambda *args: sent.append(args[-1]),
    )
    return app.state.store, request, sent


def test_native_decision_and_ack_retry_are_single_use(tmp_path):
    from microapps.bridge_notify import receive_bridge

    store, request, sent = fixture_request(tmp_path)
    assert [a["id"] for a in sent[0]["actions"]] == ["approve", "reject", "review"]
    assert sent[0]["body"] == "Test\nOperation: demo.verify"
    event = dict(
        id="response1",
        key=request["id"],
        recipient="owner",
        action="approve",
        text=None,
        created=time.time(),
        expires=request["expires"],
    )
    fail_ack = True

    def send(origin, token, path, body=None):
        if path == "/v1/responses":
            return [event]
        if fail_ack:
            raise OSError("ack offline")

    import pytest

    with pytest.raises(OSError):
        receive_bridge(
            store, "https://notifications.example.com", "secret", "owner", send
        )
    with store.transaction() as db:
        row = db.execute("SELECT * FROM requests").fetchone()
        assert row["state"] == "approved"
        deadline = row["expires"]
    fail_ack = False
    receive_bridge(store, "https://notifications.example.com", "secret", "owner", send)
    with store.transaction() as db:
        assert db.execute("SELECT expires FROM requests").fetchone()[0] == deadline
        assert (
            db.execute(
                "SELECT count(*) FROM events WHERE actor='owner-native'"
            ).fetchone()[0]
            == 1
        )


def test_native_reject(tmp_path):
    from microapps.bridge_notify import receive_bridge

    store, request, _ = fixture_request(tmp_path)
    event = dict(
        id="reject1",
        key=request["id"],
        recipient="owner",
        action="reject",
        text=None,
        created=time.time(),
        expires=request["expires"],
    )
    receive_bridge(
        store,
        "https://notifications.example.com",
        "secret",
        "owner",
        lambda origin, token, path, body=None: [event] if body is None else {},
    )
    with store.transaction() as db:
        assert db.execute("SELECT state FROM requests").fetchone()[0] == "denied"


@pytest.mark.parametrize(
    "invalid",
    ["recipient", "action", "text", "expired", "scope", "decided", "unpublished"],
)
def test_native_response_rejects_invalid_or_stale_authority(tmp_path, invalid):
    from microapps.bridge_notify import receive_bridge

    store, request, _ = fixture_request(tmp_path)
    event = dict(
        id="response1",
        key=request["id"],
        recipient="owner",
        action="approve",
        text=None,
        created=time.time(),
        expires=request["expires"],
    )
    if invalid in ("recipient", "action", "text"):
        event[invalid] = "wrong"
    with store.transaction() as db:
        if invalid == "expired":
            db.execute("UPDATE requests SET expires=0")
        if invalid == "scope":
            db.execute("UPDATE requests SET reason='Changed request'")
        if invalid == "decided":
            db.execute("UPDATE requests SET state='denied'")
        if invalid == "unpublished":
            db.execute("DELETE FROM notification_bridge_messages")
    receive_bridge(
        store,
        "https://notifications.example.com",
        "secret",
        "owner",
        lambda origin, token, path, body=None: [event] if body is None else {},
    )
    with store.transaction() as db:
        assert db.execute("SELECT state FROM requests").fetchone()[0] != "approved"
        assert (
            db.execute(
                "SELECT count(*) FROM events WHERE actor='owner-native'"
            ).fetchone()[0]
            == 0
        )


def test_long_reason_falls_back_to_review_without_authority(tmp_path):
    store, _, sent = fixture_request(tmp_path, "x" * 1000)
    assert [a["id"] for a in sent[0]["actions"]] == ["review"]
    with store.transaction() as db:
        assert (
            db.execute("SELECT count(*) FROM notification_bridge_messages").fetchone()[
                0
            ]
            == 0
        )


@pytest.mark.parametrize("changed_scope", [False, True])
def test_ssh_choices_show_and_bind_complete_scope(tmp_path, changed_scope):
    import json

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    from microapps.bridge_notify import native_body, receive_bridge
    from microapps.connection import request_view

    store, request, _ = fixture_request(tmp_path)
    public_key = (
        Ed25519PrivateKey.generate()
        .public_key()
        .public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)
        .decode()
    )
    scope = dict(
        target="nasa", account="nasa-automation", max_seconds=900, public_key=public_key
    )
    with store.transaction() as db:
        db.execute("UPDATE requests SET operation='ssh.connect'")
        db.execute(
            "INSERT INTO connections(request_id,scope) VALUES(?,?)",
            (request["id"], json.dumps(scope)),
        )
        db.execute("DELETE FROM notification_bridge_messages")
        db.execute("UPDATE notification_bridge_outbox SET done=0,next_attempt=0")
    sent = []
    deliver_bridge(
        store,
        "https://notifications.example.com",
        "secret",
        "owner",
        "https://approve.example.com",
        send=lambda *args: sent.append(args[-1]),
    )
    assert public_key in sent[0]["body"]
    assert "nasa-automation@nasa" in sent[0]["body"]
    assert "900 seconds; no sudo" in sent[0]["body"]
    event = dict(
        id="ssh-response",
        key=request["id"],
        recipient="owner",
        action="approve",
        text=None,
        created=time.time(),
        expires=request["expires"],
    )
    if changed_scope:
        replacement = (
            Ed25519PrivateKey.generate()
            .public_key()
            .public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)
            .decode()
        )
        with store.transaction() as db:
            db.execute(
                "UPDATE connections SET scope=?",
                (json.dumps({**scope, "public_key": replacement}),),
            )
    receive_bridge(
        store,
        "https://notifications.example.com",
        "secret",
        "owner",
        lambda origin, token, path, body=None: [event] if body is None else {},
    )
    with store.transaction() as db:
        row = db.execute("SELECT * FROM requests").fetchone()
        assert row["state"] == ("pending" if changed_scope else "approved")
        if not changed_scope:
            assert native_body(request_view(db, row)) == sent[0]["body"]
