"""Password authentication for the single owner, shared by both app hostnames."""

import hashlib
import secrets
import time

from fastapi import Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PasswordLogin(Input):
    password: str = Field(min_length=1, max_length=1024, repr=False)


class PasswordSet(Input):
    password: str = Field(min_length=15, max_length=1024, repr=False)


class PasswordEnrollment(PasswordSet):
    token: str = Field(max_length=256, repr=False)


class AuthMethods(BaseModel):
    password: bool
    passkey: bool
    setup: bool


class PasswordStatus(BaseModel):
    status: str


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


def install_passwords(app, store, settings, human, origin, new_session):
    @app.get("/api/auth/methods", response_model=AuthMethods)
    def methods(request: Request):
        with store.transaction() as db:
            password = bool(db.execute("SELECT 1 FROM passwords").fetchone())
            passkey = bool(db.execute("SELECT 1 FROM credentials").fetchone())
        return AuthMethods(
            password=password,
            passkey=passkey
            and app.state.origins[request.headers["host"]] == settings.origin,
            setup=not password and not passkey,
        )

    @app.post(
        "/api/auth/password/enroll",
        response_model=PasswordStatus,
        dependencies=[Depends(origin)],
    )
    def enroll(body: PasswordEnrollment, request: Request, response: Response):
        if not secrets.compare_digest(body.token, settings.enrollment_token):
            raise HTTPException(403, "Enrollment unavailable")
        salt = secrets.token_bytes(32)
        hashed = password_hash(body.password, salt)
        with store.transaction() as db:
            if (
                db.execute("SELECT 1 FROM credentials").fetchone()
                or db.execute("SELECT 1 FROM passwords").fetchone()
            ):
                raise HTTPException(403, "Enrollment unavailable")
            db.execute("INSERT INTO passwords VALUES(1,?,?)", (salt, hashed))
            db.execute("DELETE FROM challenges")
            new_session(request, response, db)
        return PasswordStatus(status="signed-in")

    @app.post(
        "/api/auth/password/login",
        response_model=PasswordStatus,
        dependencies=[Depends(origin)],
    )
    def login(body: PasswordLogin, request: Request, response: Response):
        now = time.time()
        # Reserve attempts in SQLite before hashing, including concurrent
        # requests. Persist limits across restarts and proxy address changes.
        with store.transaction() as db:
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
        # Do the same expensive work even before the password is configured.
        hashed = password_hash(body.password, row["salt"] if row else b"\0" * 32)
        if row is None or not secrets.compare_digest(hashed, row["hash"]):
            raise HTTPException(401, "Incorrect password")
        # A password change racing this verification must not mint a session
        # from the old hash. Hold the transaction through session creation.
        with store.transaction() as db:
            current = db.execute("SELECT hash FROM passwords WHERE owner=1").fetchone()
            if current is None or not secrets.compare_digest(current["hash"], hashed):
                raise HTTPException(401, "Incorrect password")
            new_session(request, response, db)
        return PasswordStatus(status="signed-in")

    @app.post("/api/auth/password", response_model=PasswordStatus)
    def change(
        body: PasswordSet, request: Request, response: Response, session=Depends(human)
    ):
        salt = secrets.token_bytes(32)
        hashed = password_hash(body.password, salt)
        with store.transaction() as db:
            # Recheck after hashing so a revoked session cannot change it.
            if not db.execute(
                "SELECT 1 FROM sessions WHERE id=? AND expires>?",
                (session["id"], time.time()),
            ).fetchone():
                raise HTTPException(401, "Sign in to continue")
            db.execute("INSERT OR REPLACE INTO passwords VALUES(1,?,?)", (salt, hashed))
            db.execute("DELETE FROM sessions")
            db.execute("DELETE FROM challenges")
            db.execute("DELETE FROM password_attempts")
            new_session(request, response, db)
        return PasswordStatus(status="password-set")
