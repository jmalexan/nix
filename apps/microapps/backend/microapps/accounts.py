"""One owner account, usable directly from independent app origins."""

import contextlib
import hashlib
import os
import secrets
import socket
import ssl
import time
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, ConfigDict, Field

from .auth_store import AuthStore


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PasswordLogin(Input):
    password: str = Field(min_length=1, max_length=1024, repr=False)


class PasswordEnrollment(Input):
    password: str = Field(min_length=15, max_length=1024, repr=False)
    token: str = Field(max_length=256, repr=False)


class AccountState(BaseModel):
    password: bool
    passkey: bool
    generation: str


class AccountLogin(BaseModel):
    generation: str


def password_hash(password, salt):
    return hashlib.scrypt(
        password.encode(),
        salt=salt,
        n=2**17,
        r=8,
        p=1,
        maxmem=256 * 1024 * 1024,
        dklen=32,
    )


class Account:
    def __init__(self, store, enrollment_token):
        self.store, self.enrollment_token = store, enrollment_token
        with store.transaction() as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS account_generation (owner INTEGER PRIMARY KEY CHECK(owner=1), value TEXT NOT NULL)"
            )
            db.execute(
                "INSERT OR IGNORE INTO account_generation VALUES(1,?)",
                (secrets.token_urlsafe(32),),
            )

    @staticmethod
    def generation(db):
        return db.execute(
            "SELECT value FROM account_generation WHERE owner=1"
        ).fetchone()["value"]

    def status(self):
        with self.store.transaction() as db:
            return AccountState(
                password=bool(db.execute("SELECT 1 FROM passwords").fetchone()),
                passkey=bool(db.execute("SELECT 1 FROM credentials").fetchone()),
                generation=self.generation(db),
            )

    def enroll(self, password, token):
        if not secrets.compare_digest(token.encode(), self.enrollment_token.encode()):
            raise HTTPException(403, "Enrollment unavailable")
        salt = secrets.token_bytes(32)
        hashed = password_hash(password, salt)
        with self.store.transaction() as db:
            if (
                db.execute("SELECT 1 FROM passwords").fetchone()
                or db.execute("SELECT 1 FROM credentials").fetchone()
            ):
                raise HTTPException(403, "Enrollment unavailable")
            db.execute("INSERT INTO passwords VALUES(1,?,?)", (salt, hashed))
            db.execute("DELETE FROM challenges")
            return AccountLogin(generation=self.generation(db))

    def login(self, password):
        now = time.time()
        with self.store.transaction() as db:
            db.execute("DELETE FROM password_attempts WHERE created<?", (now - 3600,))
            recent = db.execute(
                "SELECT created FROM password_attempts ORDER BY created"
            ).fetchall()
            minute = [row["created"] for row in recent if row["created"] > now - 60]
            if len(minute) >= 10 or len(recent) >= 100:
                wait = max(
                    1,
                    int(
                        (
                            minute[0] + 60
                            if len(minute) >= 10
                            else recent[0]["created"] + 3600
                        )
                        - now
                    )
                    + 1,
                )
                raise HTTPException(
                    429,
                    "Too many sign-in attempts; try again later",
                    headers={"Retry-After": str(wait)},
                )
            db.execute("INSERT INTO password_attempts VALUES(?)", (now,))
            row = db.execute(
                "SELECT salt, hash FROM passwords WHERE owner=1"
            ).fetchone()
            generation = self.generation(db)
        hashed = password_hash(password, row["salt"] if row else b"\0" * 32)
        if row is None or not secrets.compare_digest(hashed, row["hash"]):
            raise HTTPException(401, "Incorrect password")
        with self.store.transaction() as db:
            current = db.execute("SELECT hash FROM passwords WHERE owner=1").fetchone()
            if (
                current is None
                or self.generation(db) != generation
                or not secrets.compare_digest(current["hash"], hashed)
            ):
                raise HTTPException(401, "Incorrect password")
        return AccountLogin(generation=generation)

    def reset(self):
        with self.store.transaction() as db:
            for table in (
                "credentials",
                "sessions",
                "challenges",
                "passwords",
                "password_attempts",
            ):
                db.execute(f"DELETE FROM {table}")
            db.execute(
                "UPDATE account_generation SET value=? WHERE owner=1",
                (secrets.token_urlsafe(32),),
            )


class AccountClient:
    def __init__(self, socket):
        self.socket = socket

    def request(self, method, path, body=None):
        try:
            with httpx.Client(
                # This transport uses plain HTTP on a private Unix socket.
                # An empty verifying context avoids host CA-file dependencies
                # and still fails closed if TLS is ever requested accidentally.
                transport=httpx.HTTPTransport(
                    uds=self.socket,
                    verify=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT),
                    trust_env=False,
                ),
                base_url="http://accounts",
                timeout=10,
                trust_env=False,
            ) as client:
                response = client.request(method, path, json=body)
            if response.status_code in (401, 403, 409, 422, 429):
                detail = (
                    "Too many sign-in attempts; try again later"
                    if response.status_code == 429
                    else "Incorrect password"
                    if response.status_code == 401
                    else "Enrollment unavailable"
                )
                headers = {}
                retry = response.headers.get("retry-after", "")
                if retry.isdigit():
                    headers["Retry-After"] = retry
                raise HTTPException(response.status_code, detail, headers=headers)
            response.raise_for_status()
            return response.json()
        except (httpx.HTTPError, ValueError):
            raise HTTPException(503, "Account service unavailable") from None

    def status(self):
        try:
            return AccountState.model_validate(self.request("GET", "/account"))
        except ValueError:
            raise HTTPException(503, "Account service unavailable") from None

    def enroll(self, password, token):
        try:
            return AccountLogin.model_validate(
                self.request(
                    "POST", "/account/enroll", {"password": password, "token": token}
                )
            )
        except ValueError:
            raise HTTPException(503, "Account service unavailable") from None

    def login(self, password):
        try:
            return AccountLogin.model_validate(
                self.request("POST", "/account/login", {"password": password})
            )
        except ValueError:
            raise HTTPException(503, "Account service unavailable") from None


def create_app(account):
    @contextlib.asynccontextmanager
    async def lifespan(app):
        # Account construction has initialized the database before readiness.
        notify = os.environ.get("NOTIFY_SOCKET")
        if notify:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as channel:
                channel.connect("\0" + notify[1:] if notify.startswith("@") else notify)
                channel.sendall(b"READY=1")
        yield

    app = FastAPI(
        title="Owner account",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @app.middleware("http")
    async def boundary(request, call_next):
        if request.method == "POST":
            length = request.headers.get("content-length", "")
            if not length.isdigit() or request.headers.get("transfer-encoding"):
                return Response("Content-Length required", status_code=411)
            if int(length) > 8192:
                return Response("Request too large", status_code=413)
        return await call_next(request)

    @app.get("/account", response_model=AccountState)
    def status():
        return account.status()

    @app.post("/account/enroll", response_model=AccountLogin)
    def enroll(body: PasswordEnrollment):
        return account.enroll(body.password, body.token)

    @app.post("/account/login", response_model=AccountLogin)
    def login(body: PasswordLogin):
        return account.login(body.password)

    return app


def from_environment():
    token = Path(os.environ["MICROAPP_ACCOUNT_ENROLLMENT_FILE"]).read_text().strip()
    if len(token) < 32:
        raise ValueError("A private enrollment credential is required")
    return create_app(
        Account(AuthStore(os.environ["MICROAPP_ACCOUNT_DATABASE"]), token)
    )
