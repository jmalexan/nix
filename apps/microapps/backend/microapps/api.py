import json
import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse

from fastapi import Depends, HTTPException, Request, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, model_validator
from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers import base64url_to_bytes, bytes_to_base64url
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from .connection import ConnectionScope, request_view
from .runtime import create_service
from .store import Store, digest


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
        if any(len(value) < 32 for value in values) or len(set(values)) != len(values):
            raise ValueError("Distinct credentials of at least 32 characters required")


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NewRequest(Input):
    operation: Literal["demo.verify", "ssh.connect"]
    reason: str = Field(min_length=1, max_length=1000)
    connection: ConnectionScope | None = None

    @model_validator(mode="after")
    def scope_matches_operation(self):
        if (self.operation == "ssh.connect") != (self.connection is not None):
            raise ValueError(
                "SSH requests require a connection scope; demos cannot have one"
            )
        return self


class Decision(Input):
    decision: Literal["approve", "deny"]
    connection: ConnectionScope | None = None


class Ceremony(Input):
    challenge_id: str = Field(max_length=128)
    credential: dict


class Enrollment(Input):
    token: str = Field(max_length=256)


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
    app = create_service("Approvals", settings.origin)
    app.state.store = store
    cookie = (
        "__Host-microapp" if settings.origin.startswith("https:") else "microapp-dev"
    )
    rp_id = urlparse(settings.origin).hostname

    def origin(request: Request):
        if request.headers.get("origin") != settings.origin:
            raise HTTPException(403, "Request must come from this app")

    def human(request: Request):
        with store.transaction() as db:
            row = db.execute(
                "SELECT * FROM sessions WHERE id=? AND expires>?",
                (digest(request.cookies.get(cookie, "")), time.time()),
            ).fetchone()
        if not row:
            raise HTTPException(401, "Sign in with your passkey")
        if request.method != "GET":
            origin(request)
            if not secrets.compare_digest(
                request.headers.get("x-csrf-token", ""), row["csrf"]
            ):
                raise HTTPException(403, "Reload the app before trying again")
        return row

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

    @app.get("/health")
    def health():
        return {"status": "ok", "app": "approvals", "capability": "demo.verify"}

    @app.post("/api/auth/enroll/options", dependencies=[Depends(origin)])
    def enroll_options(body: Enrollment):
        with store.transaction() as db:
            enrolled = db.execute("SELECT 1 FROM credentials").fetchone()
        if enrolled or not secrets.compare_digest(
            body.token, settings.enrollment_token
        ):
            raise HTTPException(403, "Enrollment unavailable")
        options = generate_registration_options(
            rp_id=rp_id,
            rp_name="Approvals",
            user_name="owner",
            user_id=b"owner",
            authenticator_selection=AuthenticatorSelectionCriteria(
                resident_key=ResidentKeyRequirement.REQUIRED,
                user_verification=UserVerificationRequirement.REQUIRED,
            ),
        )
        data = json.loads(options_to_json(options))
        return {
            "challenge_id": store.challenge("enroll", data["challenge"]),
            "options": data,
        }

    @app.post("/api/auth/enroll/verify", dependencies=[Depends(origin)])
    def enroll_verify(body: Ceremony):
        try:
            challenge = store.consume_challenge(body.challenge_id, "enroll")
            verified = verify_registration_response(
                credential=body.credential,
                expected_challenge=base64url_to_bytes(challenge),
                expected_rp_id=rp_id,
                expected_origin=settings.origin,
                require_user_verification=True,
            )
        except Exception:
            raise HTTPException(400, "Could not verify passkey") from None
        with store.transaction() as db:
            if db.execute("SELECT 1 FROM credentials").fetchone():
                raise HTTPException(409, "Already enrolled")
            db.execute(
                "INSERT INTO credentials VALUES(?,?,?)",
                (
                    bytes_to_base64url(verified.credential_id),
                    bytes_to_base64url(verified.credential_public_key),
                    verified.sign_count,
                ),
            )
        return {"status": "enrolled"}

    @app.post("/api/auth/login/options", dependencies=[Depends(origin)])
    def login_options():
        data = json.loads(
            options_to_json(
                generate_authentication_options(
                    rp_id=rp_id, user_verification=UserVerificationRequirement.REQUIRED
                )
            )
        )
        return {
            "challenge_id": store.challenge("login", data["challenge"]),
            "options": data,
        }

    @app.post("/api/auth/login/verify", dependencies=[Depends(origin)])
    def login_verify(body: Ceremony, response: Response):
        try:
            challenge = store.consume_challenge(body.challenge_id, "login")
            with store.transaction() as db:
                row = db.execute(
                    "SELECT * FROM credentials WHERE id=?", (body.credential.get("id"),)
                ).fetchone()
                if not row:
                    raise ValueError("Unknown credential")
                verified = verify_authentication_response(
                    credential=body.credential,
                    expected_challenge=base64url_to_bytes(challenge),
                    expected_rp_id=rp_id,
                    expected_origin=settings.origin,
                    credential_public_key=base64url_to_bytes(row["public_key"]),
                    credential_current_sign_count=row["counter"],
                    require_user_verification=True,
                )
                db.execute(
                    "UPDATE credentials SET counter=? WHERE id=?",
                    (verified.new_sign_count, row["id"]),
                )
                token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
                db.execute("DELETE FROM sessions WHERE expires<?", (time.time(),))
                db.execute(
                    "INSERT INTO sessions VALUES(?,?,?)",
                    (digest(token), csrf, time.time() + 30 * 86400),
                )
        except Exception:
            raise HTTPException(400, "Could not verify passkey") from None
        response.set_cookie(
            cookie,
            token,
            secure=settings.origin.startswith("https:"),
            httponly=True,
            samesite="strict",
            max_age=30 * 86400,
            path="/",
        )
        return {"status": "signed-in"}

    @app.get("/api/session", response_model=SessionView)
    def session(row=Depends(human)):
        return {"csrf": row["csrf"], "vapid_public": settings.vapid_public}

    @app.post("/api/logout")
    def logout(response: Response, row=Depends(human)):
        with store.transaction() as db:
            db.execute("DELETE FROM sessions WHERE id=?", (row["id"],))
        response.delete_cookie(cookie, path="/")
        return {"status": "signed-out"}

    @app.post(
        "/api/requests",
        response_model=RequestView,
        status_code=201,
        dependencies=[Depends(requester)],
    )
    def submit(body: NewRequest):
        if body.operation == "ssh.connect" and not settings.gate_token:
            raise HTTPException(503, "Connection gate is disabled")
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
            origin=os.environ["MICROAPP_ORIGIN"],
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
