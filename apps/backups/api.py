"""Passkey-protected storage reports; no host-command or backup-control API."""

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from fastapi import Depends
from fastapi.staticfiles import StaticFiles
from microapps.auth import install_auth
from microapps.auth_store import AuthStore
from microapps.runtime import create_service
from models import Status
from pydantic import BaseModel
from status import load_status


@dataclass
class Settings:
    origin: str
    database: str
    enrollment_token: str
    report: str
    static: str | None = None

    def __post_init__(self):
        url = urlparse(self.origin)
        if (
            not url.hostname
            or url.path
            or url.query
            or url.fragment
            or url.username
            or url.password
            or (
                url.scheme != "https"
                and not (url.scheme == "http" and url.hostname == "localhost")
            )
        ):
            raise ValueError("An HTTPS origin is required")
        if len(self.enrollment_token) < 32:
            raise ValueError("Enrollment credential must have at least 32 characters")


class Healthy(BaseModel):
    status: str = "ok"


def create_app(settings):
    app = create_service("Backups", settings.origin)
    store = AuthStore(settings.database)
    app.state.store = store
    human, _ = install_auth(app, store, settings, "Backups")

    @app.get("/health", response_model=Healthy)
    def health():
        return Healthy()

    @app.get("/api/status", response_model=Status, dependencies=[Depends(human)])
    def status():
        return load_status(settings.report)

    if settings.static:
        app.mount("/", StaticFiles(directory=settings.static, html=True))
    return app


def from_environment():
    return create_app(
        Settings(
            origin=os.environ["BACKUPS_ORIGIN"],
            database=os.environ["BACKUPS_DATABASE"],
            enrollment_token=Path(os.environ["BACKUPS_ENROLLMENT_FILE"])
            .read_text()
            .strip(),
            report=os.environ["BACKUPS_REPORT"],
            static=os.environ["BACKUPS_STATIC"],
        )
    )
