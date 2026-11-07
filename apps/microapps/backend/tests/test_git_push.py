import time

import pytest
from fastapi.testclient import TestClient
from git_broker.api import create_app as broker_app
from git_broker.approval import Gate
from git_broker.backend import Repo
from microapps.api import Settings, create_app
from microapps.bridge_notify import deliver_bridge, receive_bridge
from microapps.store import digest

SCOPE = {
    "repository": "owner/project",
    "branch": "robot/work",
    "commit": "a" * 40,
    "expected": "0" * 40,
}
REQUESTER = {"Authorization": "Bearer " + "r" * 32}
BROKER = {"Authorization": "Bearer " + "b" * 32}


@pytest.fixture
def setup(tmp_path):
    app = create_app(
        Settings(
            "https://approve.test",
            str(tmp_path / "approve.db"),
            "r" * 32,
            "w" * 32,
            "e" * 32,
            gate_token="g" * 32,
            git_broker_token="b" * 32,
            notification_bridge=True,
        )
    )
    client = TestClient(app, base_url="https://approve.test")
    with app.state.store.transaction() as db:
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (digest("owner"), "csrf", time.time() + 600),
        )
    client.cookies.set("__Host-microapp", "owner")
    return app, client


def submit(client):
    response = client.post(
        "/api/requests",
        headers=REQUESTER,
        json={
            "operation": "git.push",
            "reason": "Publish reviewed change",
            "push": SCOPE,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["id"]


def decide(client, rid, decision="approve", scope=SCOPE):
    return client.post(
        f"/api/requests/{rid}/decision",
        headers={"Origin": "https://approve.test", "X-CSRF-Token": "csrf"},
        json={"decision": decision, "push": scope},
    )


def test_git_push_scope_and_claim_are_one_use_and_role_separated(setup):
    app, client = setup
    rid = submit(client)
    path = f"/api/git-broker/{rid}/claim"
    assert client.post(path, json=SCOPE, headers=BROKER).status_code == 409
    assert decide(client, rid, scope={**SCOPE, "commit": "c" * 40}).status_code == 409
    assert decide(client, rid).status_code == 200
    for token in ("r", "w", "g", "e"):
        assert (
            client.post(
                path, json=SCOPE, headers={"Authorization": "Bearer " + token * 32}
            ).status_code
            == 401
        )
    for field, value in (
        ("repository", "other/repo"),
        ("branch", "robot/other"),
        ("commit", "d" * 40),
        ("expected", "e" * 40),
    ):
        assert (
            client.post(path, json={**SCOPE, field: value}, headers=BROKER).status_code
            == 409
        )
    claimed = client.post(path, json=SCOPE, headers=BROKER)
    assert claimed.status_code == 200
    assert claimed.json()["push_deadline"] > time.time()
    assert client.post(path, json=SCOPE, headers=BROKER).status_code == 409
    assert client.post(f"/api/gate/{rid}/claim", headers=BROKER).status_code == 401
    assert (
        client.post(
            f"/api/gate/{rid}/claim", headers={"Authorization": "Bearer " + "g" * 32}
        ).status_code
        == 409
    )
    assert (
        client.post(
            f"/api/git-broker/{rid}/finish",
            headers=BROKER,
            json={"outcome": "completed"},
        ).json()["state"]
        == "completed"
    )


@pytest.mark.parametrize("state", ["denied", "expired"])
def test_denied_or_expired_approval_cannot_be_claimed(setup, state):
    app, client = setup
    rid = submit(client)
    if state == "denied":
        assert decide(client, rid, decision="deny").status_code == 200
    else:
        with app.state.store.transaction() as db:
            db.execute("UPDATE requests SET expires=0 WHERE id=?", (rid,))
    assert (
        client.post(
            f"/api/git-broker/{rid}/claim", headers=BROKER, json=SCOPE
        ).status_code
        == 409
    )


def test_native_git_choice_is_bound_to_complete_scope(setup):
    app, client = setup
    rid = submit(client)
    sent = []
    deliver_bridge(
        app.state.store,
        "https://notifications.test",
        "token",
        "owner",
        "https://approve.test",
        send=lambda *args: sent.append(args[-1]),
    )
    assert sent[0]["actions"] == [
        {"id": "approve", "title": "Approve", "kind": "respond"},
        {"id": "reject", "title": "Reject", "kind": "respond"},
    ]
    assert SCOPE["commit"] in sent[0]["body"] and SCOPE["repository"] in sent[0]["body"]
    event = {
        "id": "native-response",
        "key": rid,
        "recipient": "owner",
        "action": "approve",
        "text": None,
        "created": time.time(),
        "expires": time.time() + 60,
    }
    receive_bridge(
        app.state.store,
        "https://notifications.test",
        "token",
        "owner",
        send=lambda origin, token, path, body=None: [event] if body is None else {},
    )
    assert (
        client.post(
            f"/api/git-broker/{rid}/claim", headers=BROKER, json=SCOPE
        ).status_code
        == 200
    )


def test_broker_cannot_write_without_exact_approval_and_never_replays(setup, tmp_path):
    app, client = setup

    class FakeBackend:
        state = tmp_path
        repositories = {
            "project": Repo(github="owner/project", write_prefixes=["robot/"])
        }
        effects = 0

        def repo(self, alias):
            return self.repositories[alias]

        def push(self, alias, branch, commit, expected, bundle, authorize):
            authorize()
            self.effects += 1
            return {"branch": branch, "commit": commit}

    backend = FakeBackend()

    def send(origin, token, path, body=None):
        response = client.post(
            path, headers={"Authorization": "Bearer " + token}, json=body
        )
        if not response.is_success:
            raise OSError("Approval unavailable")
        return response.json()

    api = TestClient(
        broker_app(
            backend,
            "c" * 32,
            approval_gate=Gate("https://approve.test", "b" * 32, send),
        )
    )
    rid = submit(client)
    params = {
        "branch": SCOPE["branch"],
        "commit": SCOPE["commit"],
        "expected": SCOPE["expected"],
        "approval": rid,
    }
    headers = {"Authorization": "Bearer " + "c" * 32}
    assert (
        api.post(
            "/v1/repositories/project/push",
            params=params,
            headers=headers,
            content=b"bundle",
        ).status_code
        == 403
    )
    assert backend.effects == 0
    assert decide(client, rid).status_code == 200
    assert (
        api.post(
            "/v1/repositories/project/push",
            params=params,
            headers=headers,
            content=b"bundle",
        ).status_code
        == 200
    )
    assert backend.effects == 1
    assert (
        api.post(
            "/v1/repositories/project/push",
            params=params,
            headers=headers,
            content=b"bundle",
        ).status_code
        == 403
    )
    assert backend.effects == 1
    assert (
        client.get(f"/api/requester/requests/{rid}", headers=REQUESTER).json()["state"]
        == "completed"
    )


def test_claimed_push_expires_and_cannot_be_finished_as_success(setup):
    app, client = setup
    rid = submit(client)
    assert decide(client, rid).status_code == 200
    assert (
        client.post(
            f"/api/git-broker/{rid}/claim", headers=BROKER, json=SCOPE
        ).status_code
        == 200
    )
    with app.state.store.transaction() as db:
        db.execute("UPDATE pushes SET deadline=0 WHERE request_id=?", (rid,))
    assert (
        client.post(
            f"/api/git-broker/{rid}/finish",
            headers=BROKER,
            json={"outcome": "completed"},
        ).status_code
        == 409
    )
    assert (
        client.get(f"/api/requester/requests/{rid}", headers=REQUESTER).json()["state"]
        == "expired"
    )


def test_changed_push_scope_invalidates_native_choice(setup):
    import json

    app, client = setup
    rid = submit(client)
    deliver_bridge(
        app.state.store,
        "https://notifications.test",
        "token",
        "owner",
        "https://approve.test",
        send=lambda *args: {},
    )
    with app.state.store.transaction() as db:
        db.execute(
            "UPDATE pushes SET scope=? WHERE request_id=?",
            (json.dumps({**SCOPE, "commit": "c" * 40}), rid),
        )
    event = {
        "id": "native-old",
        "key": rid,
        "recipient": "owner",
        "action": "approve",
        "text": None,
        "created": time.time(),
        "expires": time.time() + 60,
    }
    receive_bridge(
        app.state.store,
        "https://notifications.test",
        "token",
        "owner",
        send=lambda origin, token, path, body=None: [event] if body is None else {},
    )
    assert (
        client.get(f"/api/requester/requests/{rid}", headers=REQUESTER).json()["state"]
        == "pending"
    )
