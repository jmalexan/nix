import concurrent.futures
import contextlib
import socket
import time

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi.testclient import TestClient
from microapps.access import ssh_command
from microapps.api import Settings, create_app
from microapps.connection import ConnectionScope
from microapps.gate import finish, selector, serve, validate_grant
from microapps.store import Store, digest

REQUESTER = {"Authorization": "Bearer " + "r" * 32}
GATE = {"Authorization": "Bearer " + "g" * 32}
WORKER = {"Authorization": "Bearer " + "w" * 32}
HUMAN = {"Origin": "https://approve.example.test", "X-CSRF-Token": "csrf"}


@contextlib.contextmanager
def pair():
    left, right = socket.socketpair()
    with left, right:
        yield left, right


@pytest.fixture
def key():
    return (
        Ed25519PrivateKey.generate()
        .public_key()
        .public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)
        .decode()
    )


@pytest.fixture
def env(tmp_path):
    settings = Settings(
        "https://approve.example.test",
        str(tmp_path / "state.sqlite"),
        "r" * 32,
        "w" * 32,
        "e" * 32,
        gate_token="g" * 32,
    )
    app = create_app(settings)
    client = TestClient(app, base_url=settings.origin)
    with app.state.store.transaction() as db:
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (digest("owner"), "csrf", time.time() + 600),
        )
    client.cookies.set("__Host-microapp", "owner")
    return app, client


def submit(client, key):
    response = client.post(
        "/api/requests",
        headers=REQUESTER,
        json={
            "operation": "ssh.connect",
            "reason": "Inspect host filesystem",
            "connection": {"public_key": key},
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def approve(client, request):
    response = client.post(
        f"/api/requests/{request['id']}/decision",
        headers=HUMAN,
        json={"decision": "approve", "connection": request["connection"]},
    )
    assert response.status_code == 200, response.text


def test_disabled_until_provisioned(tmp_path, key):
    app = create_app(
        Settings(
            "https://approve.example.test",
            str(tmp_path / "state"),
            "r" * 32,
            "w" * 32,
            "e" * 32,
        )
    )
    client = TestClient(app, base_url="https://approve.example.test")
    assert (
        client.post(
            "/api/requests",
            headers=REQUESTER,
            json={
                "operation": "ssh.connect",
                "reason": "test",
                "connection": {"public_key": key},
            },
        ).status_code
        == 503
    )
    assert client.post("/api/gate/example/claim", headers=GATE).status_code == 503


def test_old_client_cannot_approve_unseen_scope(env, key):
    _, client = env
    request = submit(client, key)
    for scope in (
        None,
        {**request["connection"], "public_key": key.replace("AAA", "BBB", 1)},
    ):
        assert client.post(
            f"/api/requests/{request['id']}/decision",
            headers=HUMAN,
            json={"decision": "approve", "connection": scope},
        ).status_code in (409, 422)
    approve(client, request)


def test_roles_and_concurrent_claim(env, key):
    app, client = env
    request = submit(client, key)
    path = f"/api/gate/{request['id']}/claim"
    assert client.post(path, headers=GATE).status_code == 409
    approve(client, request)
    for headers in (REQUESTER, WORKER, HUMAN):
        assert client.post(path, headers=headers).status_code == 401
    assert (
        client.post(f"/api/worker/{request['id']}/verify", headers=WORKER).status_code
        == 409
    )
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        responses = list(pool.map(lambda _: client.post(path, headers=GATE), range(6)))
    assert [r.status_code for r in responses].count(200) == 1
    assert [r.status_code for r in responses].count(409) == 5
    result = next(r.json() for r in responses if r.status_code == 200)
    assert result["connection"] == request["connection"]
    assert 898 < result["connection_deadline"] - time.time() <= 900
    with Store(app.state.store.path).transaction() as db:
        assert (
            db.execute(
                "SELECT state FROM requests WHERE id=?", (request["id"],)
            ).fetchone()[0]
            == "claimed"
        )
    assert (
        client.post(
            f"/api/gate/{request['id']}/finish",
            headers=REQUESTER,
            json={"outcome": "closed"},
        ).status_code
        == 401
    )
    assert (
        client.post(
            f"/api/gate/{request['id']}/finish",
            headers=GATE,
            json={"outcome": "closed"},
        ).json()["state"]
        == "completed"
    )
    assert client.post(path, headers=GATE).status_code == 409


@pytest.mark.parametrize(
    "state", ["pending", "approved", "denied", "expired", "failed"]
)
def test_unapproved_or_expired_cannot_claim(env, key, state):
    app, client = env
    request = submit(client, key)
    with app.state.store.transaction() as db:
        db.execute(
            "UPDATE requests SET state=?,expires=0 WHERE id=?", (state, request["id"])
        )
    assert (
        client.post(f"/api/gate/{request['id']}/claim", headers=GATE).status_code == 409
    )


def test_lost_finish_and_restore_do_not_reopen_grant(env, key):
    app, client = env
    request = submit(client, key)
    approve(client, request)
    assert (
        client.post(f"/api/gate/{request['id']}/claim", headers=GATE).status_code == 200
    )
    with Store(app.state.store.path).transaction() as db:
        db.execute(
            "UPDATE connections SET deadline=0 WHERE request_id=?", (request["id"],)
        )
    status = client.get(f"/api/requester/requests/{request['id']}", headers=REQUESTER)
    assert status.json()["state"] == "expired"
    assert (
        client.post(f"/api/gate/{request['id']}/claim", headers=GATE).status_code == 409
    )
    assert client.get(f"/api/requester/requests/{request['id']}").status_code == 401


def test_scope_validation_and_key_injection(key):
    for change in (
        {"account": "root"},
        {"target": "other"},
        {"max_seconds": 901},
        {"public_key": key + "\n"},
        {"public_key": key + " comment"},
        {"public_key": 'command="bash" ' + key},
        {"extra": "field"},
    ):
        with pytest.raises(ValueError):
            ConnectionScope.model_validate({"public_key": key, **change})


def test_selector_bounds_and_preserves_ssh_bytes():
    with pair() as (left, right):
        left.sendall(b"a" * 24 + b"\nSSH-2.0-test\r\n")
        assert selector(right) == "a" * 24
        assert right.recv(99) == b"SSH-2.0-test\r\n"
    for value in (b"../bad\n", b"a" * 25 + b"\n", b"\xff\n"):
        with pair() as (left, right):
            left.sendall(value)
            with pytest.raises(ValueError):
                selector(right)


def test_gate_fails_closed_before_sshd(tmp_path, key):
    grant = {
        "id": "a" * 24,
        "state": "claimed",
        "operation": "ssh.connect",
        "connection": ConnectionScope(public_key=key).model_dump(),
        "connection_deadline": time.time() + 60,
    }
    assert validate_grant(grant, grant["id"])[0].account == "nasa-automation"
    for change in (
        {"state": "pending"},
        {"id": "b" * 24},
        {"operation": "demo.verify"},
        {"connection_deadline": 0},
        {"connection_deadline": time.time() + 1000},
        {"connection": {**grant["connection"], "account": "root"}},
    ):
        calls = []

        def api(path, body):
            calls.append(path)
            return {**grant, **change}

        with pair() as (left, right):
            left.sendall((grant["id"] + "\n").encode())
            with pytest.raises(ValueError):
                serve(right, api, "/must-not-start", "unused", tmp_path)
        assert calls == [f"/api/gate/{grant['id']}/claim"]


def test_upgrade_preserves_existing_requests(tmp_path):
    import sqlite3

    path = tmp_path / "old.sqlite"
    with sqlite3.connect(path) as db:
        db.execute(
            "CREATE TABLE requests(id TEXT PRIMARY KEY,requester TEXT,reason TEXT,operation TEXT,state TEXT,created REAL,expires REAL,result TEXT)"
        )
        db.execute(
            "INSERT INTO requests VALUES('old','automation','demo','demo.verify','completed',0,1,NULL)"
        )
        db.execute("PRAGMA user_version=1")
    with Store(path).transaction() as db:
        assert (
            db.execute("SELECT state FROM requests WHERE id='old'").fetchone()[0]
            == "completed"
        )
        assert db.execute("PRAGMA user_version").fetchone()[0] == 4


def test_request_key_cannot_be_replaced_at_decision(env, key):
    _, client = env
    request = submit(client, key)
    other = (
        Ed25519PrivateKey.generate()
        .public_key()
        .public_bytes(Encoding.OpenSSH, PublicFormat.OpenSSH)
        .decode()
    )
    response = client.post(
        f"/api/requests/{request['id']}/decision",
        headers=HUMAN,
        json={
            "decision": "approve",
            "connection": {**request["connection"], "public_key": other},
        },
    )
    assert response.status_code == 409
    assert (
        client.get(
            f"/api/requester/requests/{request['id']}", headers=REQUESTER
        ).json()["state"]
        == "pending"
    )


def test_only_one_active_connection(env, key):
    _, client = env
    first, second = submit(client, key), submit(client, key)
    approve(client, first)
    approve(client, second)
    assert (
        client.post(f"/api/gate/{first['id']}/claim", headers=GATE).status_code == 200
    )
    assert (
        client.post(f"/api/gate/{second['id']}/claim", headers=GATE).status_code == 409
    )
    assert (
        client.post(
            f"/api/gate/{first['id']}/finish", headers=GATE, json={"outcome": "closed"}
        ).status_code
        == 200
    )
    assert (
        client.post(f"/api/gate/{second['id']}/claim", headers=GATE).status_code == 200
    )


def test_client_has_no_agent_multiplex_or_host_trust_fallback(tmp_path):
    import shlex

    arguments = ["stat", "a b", "$(touch /tmp/should-not-execute)"]
    command = ssh_command(tmp_path / "key", "a" * 24, arguments)
    for option in (
        "IdentityAgent=none",
        "IdentitiesOnly=yes",
        "ControlMaster=no",
        "ControlPath=none",
        "ControlPersist=no",
        "StrictHostKeyChecking=yes",
        "ForwardAgent=no",
        "ClearAllForwardings=yes",
    ):
        assert option in command
    assert command[1:3] == ["-F", "/dev/null"]
    assert shlex.split(command[-1]) == arguments


@pytest.mark.parametrize(
    "service_result,outcome",
    [("success", "closed"), ("timeout", "expired"), ("signal", "failed")],
)
def test_stop_post_reports_without_reclaiming(tmp_path, service_result, outcome):
    import json

    (tmp_path / "result.json").write_text(
        json.dumps({"id": "a" * 24, "outcome": "closed"})
    )
    calls = []
    finish(lambda path, body: calls.append((path, body)), tmp_path, service_result)
    assert calls == [("/api/gate/" + "a" * 24 + "/finish", {"outcome": outcome})]

    def unavailable(path, body):
        raise OSError("offline")

    finish(unavailable, tmp_path, service_result)
