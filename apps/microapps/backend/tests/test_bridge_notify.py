import time

from fastapi.testclient import TestClient
from microapps.api import Settings, create_app
from microapps.bridge_notify import deliver_bridge


def test_bridge_adapter_is_transactional_and_only_opens_web(tmp_path):
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
    assert sent[0]["actions"][0]["kind"] == "open"
    assert sent[0]["expires_at"] == result.json()["expires"]
    assert "secret" not in str(sent)
    with app.state.store.transaction() as db:
        assert db.execute("SELECT state FROM requests").fetchone()[0] == "pending"
        db.execute("UPDATE notification_bridge_outbox SET done=0")
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
