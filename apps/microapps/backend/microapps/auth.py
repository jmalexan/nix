"""Passkey enrollment and host-only sessions for independently hosted apps."""

import json
import secrets
import time
from urllib.parse import urlparse

from fastapi import Depends, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field
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

from .accounts import Account, AccountClient
from .auth_store import digest
from .passwords import install_passwords


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Ceremony(Input):
    challenge_id: str = Field(max_length=128)
    credential: dict


class Enrollment(Input):
    token: str = Field(max_length=256)


class SessionView(BaseModel):
    csrf: str


def install_auth(
    app, store, settings, title, session_model=SessionView, session_extra=None
):
    session_extra = session_extra or {}
    cookie = (
        "__Host-microapp" if settings.origin.startswith("https:") else "microapp-dev"
    )
    rp_id = urlparse(settings.origin).hostname
    account = (
        AccountClient(settings.account_socket)
        if settings.account_socket
        else Account(store, settings.enrollment_token)
    )

    def request_origin(request):
        return app.state.origins[request.headers["host"]]

    def origin(request: Request):
        if request.headers.get("origin") != request_origin(request):
            raise HTTPException(403, "Request must come from this app")

    def canonical(request: Request):
        origin(request)
        if settings.account_socket:
            raise HTTPException(403, "Use password sign-in")
        if request_origin(request) != settings.origin:
            raise HTTPException(403, "Use the full hostname for passkeys")

    def session_id(token, request, generation=None):
        host_origin = request_origin(request)
        if settings.account_socket:
            return digest(generation + "\0" + host_origin + "\0" + token)
        # Retain existing canonical sessions, but bind new alias sessions to
        # their own origin even if a cookie is manually copied between hosts.
        return digest(
            token if host_origin == settings.origin else host_origin + "\0" + token
        )

    def new_session(request, response, db=None, generation=None):
        if db is None:
            with store.transaction() as transaction:
                return new_session(request, response, transaction, generation)
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        db.execute("DELETE FROM sessions WHERE expires<?", (time.time(),))
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (session_id(token, request, generation), csrf, time.time() + 30 * 86400),
        )
        response.set_cookie(
            cookie,
            token,
            secure=settings.origin.startswith("https:"),
            httponly=True,
            samesite="strict",
            max_age=30 * 86400,
            path="/",
        )

    def human(request: Request):
        generation = None
        if settings.account_socket:
            state = account.status()
            if not state.password:
                raise HTTPException(401, "Sign in to continue")
            generation = state.generation
        with store.transaction() as db:
            row = db.execute(
                "SELECT * FROM sessions WHERE id=? AND expires>?",
                (
                    session_id(request.cookies.get(cookie, ""), request, generation),
                    time.time(),
                ),
            ).fetchone()
        if not row:
            raise HTTPException(401, "Sign in to continue")
        if request.method not in ("GET", "HEAD"):
            origin(request)
            if not secrets.compare_digest(
                request.headers.get("x-csrf-token", ""), row["csrf"]
            ):
                raise HTTPException(403, "Reload the app before trying again")
        return row

    @app.post("/api/auth/enroll/options", dependencies=[Depends(canonical)])
    def enroll_options(body: Enrollment):
        with store.transaction() as db:
            enrolled = (
                db.execute("SELECT 1 FROM credentials").fetchone()
                or db.execute("SELECT 1 FROM passwords").fetchone()
            )
        if enrolled or not secrets.compare_digest(
            body.token, settings.enrollment_token
        ):
            raise HTTPException(403, "Enrollment unavailable")
        options = generate_registration_options(
            rp_id=rp_id,
            rp_name=title,
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

    @app.post("/api/auth/enroll/verify", dependencies=[Depends(canonical)])
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
            if (
                db.execute("SELECT 1 FROM credentials").fetchone()
                or db.execute("SELECT 1 FROM passwords").fetchone()
            ):
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

    @app.post("/api/auth/login/options", dependencies=[Depends(canonical)])
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

    @app.post("/api/auth/login/verify", dependencies=[Depends(canonical)])
    def login_verify(body: Ceremony, request: Request, response: Response):
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
                new_session(request, response, db)
        except Exception:
            raise HTTPException(400, "Could not verify passkey") from None
        return {"status": "signed-in"}

    @app.get("/api/session", response_model=session_model)
    def session(row=Depends(human)):
        return {"csrf": row["csrf"], **session_extra}

    @app.post("/api/logout")
    def logout(response: Response, row=Depends(human)):
        with store.transaction() as db:
            db.execute("DELETE FROM sessions WHERE id=?", (row["id"],))
        response.delete_cookie(
            cookie,
            path="/",
            secure=settings.origin.startswith("https:"),
            httponly=True,
            samesite="strict",
        )
        return {"status": "signed-out"}

    install_passwords(app, account, settings, origin, new_session)
    return human, origin
