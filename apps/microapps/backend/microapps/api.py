import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from fastapi import Depends, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, model_validator

from .auth import install_auth
from .auth_store import digest
from .connection import ConnectionScope, request_view
from .push import PushOutcome, PushScope
from .runtime import create_service
from .store import Store


@dataclass(frozen=True)
class Settings:
    origin: str
    database: str
    requester_token: str
    worker_token: str
    enrollment_token: str
    static: str | None = None
    vapid_public: str = ""
    gate_token: str = ""
    notification_bridge: bool = False
    git_broker_token: str = ""
    aliases: tuple[str, ...] = ()

    def __post_init__(self):
        url = urlparse(self.origin)
        if url.path or url.query or url.fragment or not url.hostname:
            raise ValueError("Origin must be scheme://host[:port]")
        if url.scheme != "https" and not (
            url.scheme == "http" and url.hostname == "localhost"
        ):
            raise ValueError("HTTPS required except localhost development")
        values = [self.requester_token, self.worker_token, self.enrollment_token]
        if self.gate_token:
            values.append(self.gate_token)
        if self.git_broker_token:
            values.append(self.git_broker_token)
        if any(len(value) < 32 for value in values) or len(set(values)) != len(values):
            raise ValueError("Distinct credentials of at least 32 characters required")


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NewRequest(Input):
    operation: Literal["demo.verify", "ssh.connect", "git.push"]
    reason: str = Field(min_length=1, max_length=1000)
    connection: ConnectionScope | None = None
    push: PushScope | None = None

    @model_validator(mode="after")
    def scope_matches_operation(self):
        if (self.operation == "ssh.connect") != (self.connection is not None):
            raise ValueError(
                "SSH requests require a connection scope; demos cannot have one"
            )
        if (self.operation == "git.push") != (self.push is not None):
            raise ValueError("Git pushes require an exact push scope")
        return self


class Decision(Input):
    decision: Literal["approve", "deny"]
    connection: ConnectionScope | None = None
    push: PushScope | None = None


class RequestView(BaseModel):
    id: str
    requester: str
    reason: str
    operation: str
    state: str
    created: float
    expires: float
    result: str | None
    connection: ConnectionScope | None = None
    connection_deadline: float | None = None
    push: PushScope | None = None
    push_deadline: float | None = None


class ConnectionResult(Input):
    outcome: Literal["closed", "failed", "expired"]


class SessionView(BaseModel):
    csrf: str
    vapid_public: str


class Subscription(Input):
    endpoint: str = Field(max_length=2048)
    keys: dict[str, str]
    expirationTime: float | None = None


def create_app(settings: Settings):
    store = Store(settings.database)
    app = create_service("Approvals", settings.origin, settings.aliases)
    app.state.store = store

    def machine(expected):
        def check(request: Request):
            if not secrets.compare_digest(
                request.headers.get("authorization", ""), "Bearer " + expected
            ):
                raise HTTPException(401, "Invalid service credential")

        return check

    requester = machine(settings.requester_token)
    worker = machine(settings.worker_token)

    def gate(request: Request):
        if not settings.gate_token:
            raise HTTPException(503, "Connection gate is disabled")
        machine(settings.gate_token)(request)

    def broker(request: Request):
        if not settings.git_broker_token:
            raise HTTPException(503, "Git broker approvals are disabled")
        machine(settings.git_broker_token)(request)

    @app.get("/health")
    def health():
        return {"status": "ok", "app": "approvals", "capability": "demo.verify"}

    human, _ = install_auth(
        app,
        store,
        settings,
        "Approvals",
        SessionView,
        {"vapid_public": settings.vapid_public},
    )

    @app.post(
        "/api/requests",
        response_model=RequestView,
        status_code=201,
        dependencies=[Depends(requester)],
    )
    def submit(body: NewRequest):
        if body.operation == "ssh.connect" and not settings.gate_token:
            raise HTTPException(503, "Connection gate is disabled")
        if body.operation == "git.push" and not settings.git_broker_token:
            raise HTTPException(503, "Git broker approvals are disabled")
        if not body.reason.strip():
            raise HTTPException(422, "A reason is required")
        with store.transaction() as db:
            Store.expire(db)
            if (
                db.execute(
                    "SELECT count(*) FROM requests WHERE state='pending'"
                ).fetchone()[0]
                >= 20
            ):
                raise HTTPException(429, "Too many pending requests")
            rid, now = secrets.token_urlsafe(18), time.time()
            db.execute(
                "INSERT INTO requests VALUES(?,?,?,?,?,?,?,?)",
                (
                    rid,
                    "automation",
                    body.reason,
                    body.operation,
                    "pending",
                    now,
                    now + 600,
                    None,
                ),
            )
            Store.event(db, rid, "automation", "requested")
            if body.connection:
                db.execute(
                    "INSERT INTO connections(request_id,scope) VALUES(?,?)",
                    (rid, body.connection.model_dump_json()),
                )
            if body.push:
                db.execute(
                    "INSERT INTO pushes(request_id,scope) VALUES(?,?)",
                    (rid, body.push.model_dump_json()),
                )
            db.execute(
                "INSERT INTO outbox(request_id,subscription_id) SELECT ?,id FROM subscriptions",
                (rid,),
            )
            if settings.notification_bridge:
                db.execute(
                    "INSERT INTO notification_bridge_outbox(request_id) VALUES(?)",
                    (rid,),
                )
            return request_view(
                db, db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            )

    @app.get(
        "/api/requester/requests/{rid}",
        response_model=RequestView,
        dependencies=[Depends(requester)],
    )
    def request_status(rid: str):
        with store.transaction() as db:
            Store.expire(db)
            row = db.execute(
                "SELECT * FROM requests WHERE id=? AND requester='automation'", (rid,)
            ).fetchone()
            if not row:
                raise HTTPException(404, "Request not found")
            return request_view(db, row)

    @app.get(
        "/api/requests", response_model=list[RequestView], dependencies=[Depends(human)]
    )
    def requests():
        with store.transaction() as db:
            Store.expire(db)
            return [
                request_view(db, row)
                for row in db.execute(
                    "SELECT * FROM requests ORDER BY created DESC LIMIT 100"
                )
            ]

    @app.post(
        "/api/requests/{rid}/decision",
        response_model=RequestView,
        dependencies=[Depends(human)],
    )
    def decide(rid: str, body: Decision):
        with store.transaction() as db:
            Store.expire(db)
            row = db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            if row and row["operation"] == "ssh.connect" and body.decision == "approve":
                expected = request_view(db, row)["connection"]
                if body.connection is None or body.connection.model_dump() != expected:
                    raise HTTPException(
                        409, "Reload this app and review the connection details"
                    )
            if row and row["operation"] == "git.push" and body.decision == "approve":
                expected = request_view(db, row)["push"]
                if body.push is None or body.push.model_dump() != expected:
                    raise HTTPException(
                        409, "Reload this app and review the push details"
                    )
            state = "approved" if body.decision == "approve" else "denied"
            changed = db.execute(
                "UPDATE requests SET state=?,expires=min(expires,?) WHERE id=? AND state='pending'",
                (state, time.time() + 120, rid),
            ).rowcount
            if not changed:
                raise HTTPException(409, "Request is no longer pending")
            Store.event(db, rid, "owner", state)
            return request_view(
                db, db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            )

    @app.post(
        "/api/worker/{rid}/verify",
        response_model=RequestView,
        dependencies=[Depends(worker)],
    )
    def verify_demo(rid: str):
        with store.transaction() as db:
            Store.expire(db)
            if not db.execute(
                "UPDATE requests SET state='claimed' WHERE id=? AND state='approved' AND operation='demo.verify'",
                (rid,),
            ).rowcount:
                raise HTTPException(409, "No unused approval available")
            Store.event(db, rid, "demo-worker", "claimed")
            db.execute(
                "UPDATE requests SET state='completed',result='Permission boundary verified' WHERE id=?",
                (rid,),
            )
            Store.event(db, rid, "demo-worker", "completed")
            return request_view(
                db, db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            )

    @app.post(
        "/api/git-broker/{rid}/claim",
        response_model=RequestView,
        dependencies=[Depends(broker)],
    )
    def claim_push(rid: str, scope: PushScope):
        with store.transaction() as db:
            Store.expire(db)
            row = db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            if (
                not row
                or row["operation"] != "git.push"
                or row["state"] != "approved"
                or request_view(db, row)["push"] != scope.model_dump()
            ):
                raise HTTPException(409, "No unused approval for this exact push")
            db.execute("UPDATE requests SET state='claimed' WHERE id=?", (rid,))
            db.execute(
                "UPDATE pushes SET deadline=? WHERE request_id=?",
                (time.time() + 180, rid),
            )
            Store.event(db, rid, "git-broker", "claimed")
            return request_view(
                db, db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            )

    @app.post(
        "/api/git-broker/{rid}/finish",
        response_model=RequestView,
        dependencies=[Depends(broker)],
    )
    def finish_push(rid: str, body: PushOutcome):
        with store.transaction() as db:
            Store.expire(db)
            result = (
                "Approved commit pushed"
                if body.outcome == "completed"
                else "Push failed; fetch before retrying"
            )
            if not db.execute(
                "UPDATE requests SET state=?,result=? WHERE id=? AND state='claimed' AND operation='git.push'",
                (body.outcome, result, rid),
            ).rowcount:
                raise HTTPException(409, "No active push approval")
            Store.event(db, rid, "git-broker", body.outcome)
            return request_view(
                db, db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            )

    @app.post(
        "/api/gate/{rid}/claim",
        response_model=RequestView,
        dependencies=[Depends(gate)],
    )
    def claim_connection(rid: str):
        with store.transaction() as db:
            Store.expire(db)
            if db.execute(
                "SELECT 1 FROM requests WHERE operation='ssh.connect' AND state='claimed'"
            ).fetchone():
                raise HTTPException(409, "Another connection is active")
            if not db.execute(
                "UPDATE requests SET state='claimed' WHERE id=? AND state='approved' AND operation='ssh.connect'",
                (rid,),
            ).rowcount:
                raise HTTPException(409, "No unused connection approval available")
            row = db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            scope = request_view(db, row)["connection"]
            if scope is None:
                raise HTTPException(409, "Connection scope missing")
            db.execute(
                "UPDATE connections SET deadline=? WHERE request_id=?",
                (time.time() + scope["max_seconds"], rid),
            )
            Store.event(db, rid, "ssh-gate", "claimed")
            return request_view(db, row)

    @app.post(
        "/api/gate/{rid}/finish",
        response_model=RequestView,
        dependencies=[Depends(gate)],
    )
    def finish_connection(rid: str, body: ConnectionResult):
        with store.transaction() as db:
            Store.expire(db)
            state, result = {
                "closed": ("completed", "Connection closed"),
                "failed": ("failed", "Connection failed"),
                "expired": ("expired", "Connection time limit reached"),
            }[body.outcome]
            if not db.execute(
                "UPDATE requests SET state=?,result=? WHERE id=? AND state='claimed' AND operation='ssh.connect'",
                (state, result, rid),
            ).rowcount:
                raise HTTPException(409, "No active connection")
            Store.event(db, rid, "ssh-gate", state)
            return request_view(
                db, db.execute("SELECT * FROM requests WHERE id=?", (rid,)).fetchone()
            )

    @app.post("/api/subscriptions", dependencies=[Depends(human)])
    def subscribe(body: Subscription):
        url = urlparse(body.endpoint)
        allowed = (
            "web.push.apple.com",
            "fcm.googleapis.com",
            "updates.push.services.mozilla.com",
        )
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username
            or url.password
            or url.port not in (None, 443)
            or not any(
                url.hostname == h or url.hostname.endswith("." + h) for h in allowed
            )
        ):
            raise HTTPException(422, "Unsupported push provider")
        if set(body.keys) != {"p256dh", "auth"} or any(
            len(v) > 256 for v in body.keys.values()
        ):
            raise HTTPException(422, "Invalid push keys")
        with store.transaction() as db:
            db.execute(
                "INSERT OR REPLACE INTO subscriptions VALUES(?,?)",
                (digest(body.endpoint), body.model_dump_json()),
            )
        return {"status": "subscribed"}

    if settings.static:
        app.mount(
            "/", StaticFiles(directory=settings.static, html=True), name="frontend"
        )
    return app


def from_environment():
    def secret(name):
        return Path(os.environ[name]).read_text().strip()

    return create_app(
        Settings(
            git_broker_token=Path(os.environ["MICROAPP_GIT_BROKER_FILE"])
            .read_text()
            .strip()
            if os.environ.get("MICROAPP_GIT_BROKER_FILE")
            else "",
            origin=os.environ["MICROAPP_ORIGIN"],
            aliases=tuple(os.environ.get("MICROAPP_ALIASES", "").split()),
            database=os.environ["MICROAPP_DATABASE"],
            requester_token=secret("MICROAPP_REQUESTER_FILE"),
            worker_token=secret("MICROAPP_WORKER_FILE"),
            enrollment_token=secret("MICROAPP_ENROLLMENT_FILE"),
            static=os.environ.get("MICROAPP_STATIC"),
            vapid_public=os.environ.get("MICROAPP_VAPID_PUBLIC", ""),
            gate_token=secret("MICROAPP_GATE_FILE")
            if os.environ.get("MICROAPP_GATE_FILE")
            else "",
            notification_bridge=os.environ.get("MICROAPP_NOTIFICATION_BRIDGE") == "1",
        )
    )
