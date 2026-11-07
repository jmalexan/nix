import json
import os
import re
import secrets
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.staticfiles import StaticFiles

from .delivery import payload
from .models import (
    Accepted,
    DeviceCredential,
    Enroll,
    Notification,
    NotificationView,
    Preference,
    PreferencesView,
    Registration,
    ResponseInput,
    Service,
    ServiceResponse,
    SettingsLink,
    Status,
    Ticket,
    https_url,
)
from .store import Store, digest


@dataclass
class Settings:
    origin: str
    database: str
    services: dict[str, Service]
    static: str | None = None
    aliases: tuple[str, ...] = ()
    link_origin: str | None = None

    def __post_init__(self):
        if https_url(self.origin) != self.origin:
            raise ValueError("An HTTPS origin is required")
        if any(https_url(alias) != alias for alias in self.aliases):
            raise ValueError("Aliases must be HTTPS origins")
        if self.link_origin is not None and self.link_origin not in (
            self.origin,
            *self.aliases,
        ):
            raise ValueError("Link origin must be an allowed origin")
        tokens = [s.token for s in self.services.values()]
        if len(set(tokens)) != len(tokens):
            raise ValueError("Service credentials must be distinct")
        if any(
            not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", name) for name in self.services
        ):
            raise ValueError("Invalid service name")


def create_app(settings):
    store = Store(settings.database)
    app = FastAPI(title="Notifications", version="1.0.0")
    app.state.store = store
    cookie = "__Host-notifications"
    origins = {
        urlsplit(value).netloc: value for value in (settings.origin, *settings.aliases)
    }

    @app.middleware("http")
    async def boundary(request, call_next):
        if request.headers.get("host") not in origins:
            return Response("Unexpected host", status_code=400)
        length = request.headers.get("content-length", "0")
        if not length.isdigit() or int(length) > 16384:
            return Response("Request too large", status_code=413)
        if request.method in ("POST", "PUT", "DELETE") and (
            "content-length" not in request.headers
            or request.headers.get("transfer-encoding")
        ):
            return Response("Content-Length required", status_code=411)
        response = await call_next(request)
        response.headers.update(
            {
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "Referrer-Policy": "no-referrer",
                "Content-Security-Policy": "default-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
            }
        )
        return response

    def service(request: Request):
        supplied = request.headers.get("authorization", "")
        for name, config in settings.services.items():
            if secrets.compare_digest(supplied, "Bearer " + config.token):
                return name
        raise HTTPException(401, "Invalid service credential")

    def device(request: Request):
        authorization = request.headers.get("authorization", "")
        with store.transaction() as db:
            row = db.execute(
                "SELECT * FROM devices WHERE token=? AND active=1",
                (digest(authorization.removeprefix("Bearer ")),),
            ).fetchone()
        if not authorization.startswith("Bearer ") or row is None:
            raise HTTPException(401, "Enroll this device again")
        return row

    def origin(request: Request):
        if request.headers.get("origin") != origins[request.headers["host"]]:
            raise HTTPException(403, "Open settings from the companion")

    def web_device(request: Request):
        with store.transaction() as db:
            row = db.execute(
                """SELECT d.* FROM devices d JOIN sessions s ON s.device=d.id
                   WHERE s.token=? AND s.expires>? AND d.active=1""",
                (digest(request.cookies.get(cookie, "")), time.time()),
            ).fetchone()
        if row is None:
            raise HTTPException(401, "Open settings from the companion")
        if request.method != "GET":
            origin(request)
        return row

    def message(db, mid, owner):
        row = db.execute(
            """SELECT m.* FROM messages m JOIN deliveries d ON d.message=m.id
               JOIN devices v ON v.id=d.device
               WHERE m.id=? AND d.device=? AND m.recipient=? AND v.active=1""",
            (mid, owner["id"], owner["recipient"]),
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Notification unavailable")
        return row

    @app.get("/health", response_model=Status)
    def health():
        return {"status": "ok"}

    @app.post("/v1/enroll", response_model=DeviceCredential, status_code=201)
    def enroll(body: Enroll):
        with store.transaction() as db:
            grant = db.execute(
                "DELETE FROM grants WHERE code=? AND expires>? RETURNING recipient",
                (digest(body.code), time.time()),
            ).fetchone()
            if grant is None:
                raise HTTPException(403, "Enrollment code expired or already used")
            identifier, token = secrets.token_urlsafe(18), secrets.token_urlsafe(32)
            # An APNs token cannot be enrolled as two recipients or two active devices.
            db.execute(
                "UPDATE devices SET active=0 WHERE apns=? AND environment=?",
                (body.apns_token.lower(), body.environment),
            )
            db.execute(
                "INSERT INTO devices VALUES(?,?,?,?,?,?,1)",
                (
                    identifier,
                    grant["recipient"],
                    body.name,
                    digest(token),
                    body.apns_token.lower(),
                    body.environment,
                ),
            )
        return {"id": identifier, "token": token}

    @app.post("/v1/device/registration", response_model=Status)
    def registration(body: Registration, owner=Depends(device)):
        try:
            with store.transaction() as db:
                db.execute(
                    "UPDATE devices SET apns=?,environment=? WHERE id=?",
                    (body.apns_token.lower(), body.environment, owner["id"]),
                )
        except sqlite3.IntegrityError:
            raise HTTPException(
                409, "Token belongs to another enrolled device"
            ) from None
        return {"status": "registered"}

    @app.post("/v1/notifications", response_model=Accepted, status_code=201)
    def publish(body: Notification, name=Depends(service)):
        config = settings.services[name]
        if body.recipient not in config.recipients:
            raise HTTPException(403, "Recipient not permitted")
        urls = [body.url] + [a.url for a in body.actions if a.url]
        if body.image:
            urls.append(body.image)
        try:
            if any(https_url(url) not in config.origins for url in urls):
                raise ValueError()
        except ValueError:
            raise HTTPException(
                422, "URL origin not permitted for this service"
            ) from None
        with store.transaction() as db:
            Store.prune(db)
            existing = db.execute(
                "SELECT * FROM messages WHERE service=? AND recipient=? AND dedupe=?",
                (name, body.recipient, body.key),
            ).fetchone()
            if existing:
                if existing["content"] != body.model_dump_json():
                    raise HTTPException(409, "Notification key already used")
                return dict(existing)
            if (
                db.execute(
                    "SELECT count(*) FROM messages WHERE service=? AND created>?",
                    (name, time.time() - 86400),
                ).fetchone()[0]
                >= 1000
            ):
                raise HTTPException(429, "Daily notification limit reached")
            mid, now = secrets.token_urlsafe(18), time.time()
            expires = min(
                now + body.ttl,
                body.expires_at if body.expires_at is not None else now + body.ttl,
            )
            if expires <= now:
                raise HTTPException(409, "Notification already expired")
            serialized = payload(
                {"content": body.model_dump_json(), "message": mid, "service": name}
            )
            if len(json.dumps(serialized, ensure_ascii=False).encode()) > 4096:
                raise HTTPException(
                    422, "Notification exceeds Apple's push payload limit"
                )
            db.execute(
                "INSERT INTO messages VALUES(?,?,?,?,?,?,?)",
                (
                    mid,
                    name,
                    body.recipient,
                    body.key,
                    body.model_dump_json(),
                    now,
                    expires,
                ),
            )
            db.execute(
                """INSERT INTO deliveries(message,device)
                   SELECT ?,d.id FROM devices d LEFT JOIN preferences p
                   ON p.device=d.id AND p.service=?
                   WHERE d.active=1 AND d.recipient=? AND COALESCE(p.enabled,1)=1""",
                (mid, name, body.recipient),
            )
        return {"id": mid, "expires": expires}

    @app.get("/v1/device/notifications/{mid}", response_model=NotificationView)
    def get_message(mid: str, owner=Depends(device)):
        with store.transaction() as db:
            row = message(db, mid, owner)
            answered = db.execute(
                "SELECT 1 FROM responses WHERE message=?", (mid,)
            ).fetchone()
        return {
            "id": mid,
            "service": row["service"],
            "expires": row["expires"],
            "active": row["expires"] > time.time() and not answered,
            **json.loads(row["content"]),
        }

    @app.post("/v1/device/notifications/{mid}/response", response_model=Status)
    def respond(mid: str, body: ResponseInput, owner=Depends(device)):
        with store.transaction() as db:
            row = message(db, mid, owner)
            if row["expires"] <= time.time():
                raise HTTPException(409, "Notification expired; open the service")
            action = next(
                (
                    a
                    for a in json.loads(row["content"])["actions"]
                    if a["id"] == body.action
                ),
                None,
            )
            if not action or action["kind"] == "open":
                raise HTTPException(422, "Unsupported response")
            if (action["kind"] == "reply") != (body.text is not None):
                raise HTTPException(422, "Only replies require text")
            existing = db.execute(
                "SELECT * FROM responses WHERE message=?", (mid,)
            ).fetchone()
            if existing:
                if (
                    existing["device"] == owner["id"]
                    and existing["action"] == body.action
                    and existing["text"] == body.text
                ):
                    return {"status": "recorded"}
                raise HTTPException(409, "Notification already answered")
            db.execute(
                "INSERT INTO responses VALUES(?,?,?,?,?,0)",
                (mid, owner["id"], body.action, body.text, time.time()),
            )
        return {"status": "recorded"}

    @app.get("/v1/responses", response_model=list[ServiceResponse])
    def responses(name=Depends(service)):
        with store.transaction() as db:
            return [
                dict(row)
                for row in db.execute(
                    """SELECT r.message AS id,m.dedupe AS key,m.recipient,r.action,r.text,
                       r.created,m.expires FROM responses r JOIN messages m ON m.id=r.message
                       WHERE m.service=? AND r.acknowledged=0 AND m.expires>?
                       ORDER BY r.created LIMIT 100""",
                    (name, time.time()),
                )
            ]

    @app.post("/v1/responses/{mid}/ack", response_model=Status)
    def acknowledge(mid: str, name=Depends(service)):
        with store.transaction() as db:
            if not db.execute(
                """UPDATE responses SET acknowledged=1 WHERE message=? AND message IN
                   (SELECT id FROM messages WHERE service=?)""",
                (mid, name),
            ).rowcount:
                raise HTTPException(404, "Response unavailable")
        return {"status": "acknowledged"}

    @app.post("/v1/device/settings", response_model=SettingsLink)
    def settings_link(owner=Depends(device)):
        ticket = secrets.token_urlsafe(32)
        with store.transaction() as db:
            Store.prune(db)
            db.execute("DELETE FROM tickets WHERE device=?", (owner["id"],))
            db.execute(
                "INSERT INTO tickets VALUES(?,?,?)",
                (digest(ticket), owner["id"], time.time() + 60),
            )
        return {"url": (settings.link_origin or settings.origin) + "/#" + ticket}

    @app.post("/v1/device/revoke", response_model=Status)
    def revoke_native(owner=Depends(device)):
        with store.transaction() as db:
            db.execute("UPDATE devices SET active=0 WHERE id=?", (owner["id"],))
            db.execute("DELETE FROM sessions WHERE device=?", (owner["id"],))
        return {"status": "revoked"}

    @app.post("/v1/web/session", dependencies=[Depends(origin)], response_model=Status)
    def exchange(body: Ticket, response: Response):
        token = secrets.token_urlsafe(32)
        with store.transaction() as db:
            ticket = db.execute(
                """DELETE FROM tickets WHERE token=? AND expires>? AND device IN
                   (SELECT id FROM devices WHERE active=1) RETURNING device""",
                (digest(body.ticket), time.time()),
            ).fetchone()
            if ticket is None:
                raise HTTPException(403, "Open settings from the companion")
            db.execute(
                "INSERT INTO sessions VALUES(?,?,?)",
                (digest(token), ticket["device"], time.time() + 900),
            )
        response.set_cookie(
            cookie,
            token,
            secure=True,
            httponly=True,
            samesite="strict",
            max_age=900,
            path="/",
        )
        return {"status": "connected"}

    @app.get("/v1/web/settings", response_model=PreferencesView)
    def preferences(owner=Depends(web_device)):
        with store.transaction() as db:
            values = {
                r["service"]: bool(r["enabled"])
                for r in db.execute(
                    "SELECT * FROM preferences WHERE device=?", (owner["id"],)
                )
            }
        return {
            "name": owner["name"],
            "services": {
                name: values.get(name, True)
                for name, s in settings.services.items()
                if owner["recipient"] in s.recipients
            },
        }

    @app.post("/v1/web/services/{name}", response_model=Status)
    def preference(name: str, body: Preference, owner=Depends(web_device)):
        if (
            name not in settings.services
            or owner["recipient"] not in settings.services[name].recipients
        ):
            raise HTTPException(404, "Service unavailable")
        with store.transaction() as db:
            db.execute(
                "INSERT OR REPLACE INTO preferences VALUES(?,?,?)",
                (owner["id"], name, body.enabled),
            )
            if not body.enabled:
                db.execute(
                    "UPDATE deliveries SET state='disabled' WHERE device=? AND state='pending' AND message IN (SELECT id FROM messages WHERE service=?)",
                    (owner["id"], name),
                )
        return {"status": "saved"}

    @app.post("/v1/web/revoke", response_model=Status)
    def revoke(owner=Depends(web_device)):
        with store.transaction() as db:
            db.execute("UPDATE devices SET active=0 WHERE id=?", (owner["id"],))
            db.execute("DELETE FROM sessions WHERE device=?", (owner["id"],))
        return {"status": "revoked"}

    if settings.static:
        app.mount("/", StaticFiles(directory=settings.static, html=True))
    return app


def from_environment():
    services = json.loads(Path(os.environ["NOTIFICATIONS_SERVICES_FILE"]).read_text())
    return create_app(
        Settings(
            origin=os.environ["NOTIFICATIONS_ORIGIN"],
            aliases=tuple(os.environ.get("NOTIFICATIONS_ALIASES", "").split()),
            link_origin=os.environ.get("NOTIFICATIONS_LINK_ORIGIN"),
            database=os.environ["NOTIFICATIONS_DATABASE"],
            services={
                name: Service.model_validate(value) for name, value in services.items()
            },
            static=os.environ.get("NOTIFICATIONS_STATIC"),
        )
    )
