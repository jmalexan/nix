"""Initial password setup and login; recovery is local account recreation."""

from fastapi import Depends, Request, Response
from pydantic import BaseModel

from .accounts import PasswordEnrollment, PasswordLogin


class AuthMethods(BaseModel):
    password: bool
    passkey: bool
    setup: bool


class PasswordStatus(BaseModel):
    status: str


def install_passwords(app, account, settings, origin, new_session):
    @app.get("/api/auth/methods", response_model=AuthMethods)
    def methods(request: Request):
        state = account.status()
        return AuthMethods(
            password=state.password,
            passkey=state.passkey
            and not settings.account_socket
            and app.state.origins[request.headers["host"]] == settings.origin,
            setup=not state.password and not state.passkey,
        )

    @app.post(
        "/api/auth/password/enroll",
        response_model=PasswordStatus,
        dependencies=[Depends(origin)],
    )
    def enroll(body: PasswordEnrollment, request: Request, response: Response):
        result = account.enroll(body.password, body.token)
        new_session(request, response, generation=result.generation)
        return PasswordStatus(status="signed-in")

    @app.post(
        "/api/auth/password/login",
        response_model=PasswordStatus,
        dependencies=[Depends(origin)],
    )
    def login(body: PasswordLogin, request: Request, response: Response):
        result = account.login(body.password)
        new_session(request, response, generation=result.generation)
        return PasswordStatus(status="signed-in")
