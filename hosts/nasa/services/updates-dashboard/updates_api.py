"""Authenticated Updates API; collectors and PR workers remain independent."""

import datetime as dt
import os
import threading
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import Annotated, Literal
from urllib.parse import urlparse

from fastapi import Depends, HTTPException
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from microapps.auth import install_auth
from microapps.auth_store import AuthStore
from microapps.runtime import create_service
from pydantic import BaseModel, ConfigDict, Field
from server import DashboardHandler


@dataclass
class Settings:
    origin: str
    database: str
    enrollment_token: str
    data: str
    static: str | None = None
    inventory: str | None = None
    systemctl: str = "systemctl"
    token: str | None = None
    aliases: tuple[str, ...] = ()

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


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Scan(Input):
    action: Literal["scan"]
    target: Literal["containers", "actions", "nix"]


class CreatePR(Input):
    action: Literal["create-pr"]
    kind: Literal["container", "action", "nix"]
    target: str = Field(min_length=1, max_length=256)


class ActionStatus(BaseModel):
    prConfigured: bool
    jobs: dict[str, str]
    pullRequests: dict[str, dict]


class DashboardStatus(BaseModel):
    reports: dict[str, dict | None]
    history: list[dict]
    actions: ActionStatus


class Queued(BaseModel):
    status: Literal["queued"] = "queued"


class Healthy(BaseModel):
    status: Literal["ok"] = "ok"


def create_app(settings):
    store = AuthStore(settings.database)
    app = create_service("System updates", settings.origin, settings.aliases)
    app.state.store = store
    human, _ = install_auth(app, store, settings, "System updates")
    dashboard = DashboardHandler()
    root = Path(settings.data)
    dashboard.server = SimpleNamespace(
        data_root=root,
        trigger_root=root / "triggers",
        queue_root=root / "pr-queue",
        results_root=root / "pr-results",
        systemctl=settings.systemctl,
        token_path=Path(settings.token) if settings.token else root / "github-token",
        scan_units={
            "containers": "updates-dashboard-containers-report.service",
            "actions": "updates-dashboard-actions-report.service",
            "nix": "updates-dashboard-nix-report.service",
        },
        now=lambda: dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    )
    for directory in (
        dashboard.server.trigger_root,
        dashboard.server.queue_root,
        dashboard.server.results_root,
    ):
        directory.mkdir(parents=True, exist_ok=True)
    inventory = dashboard.load_path_json(
        Path(settings.inventory) if settings.inventory else root / "inventory.json",
        {"services": []},
    )
    dashboard.server.container_names = {
        item["name"] for item in inventory.get("services", [])
    }
    app.state.dashboard = dashboard
    action_lock = threading.Lock()

    @app.get("/health", response_model=Healthy)
    def health():
        return Healthy()

    @app.get(
        "/api/status", response_model=DashboardStatus, dependencies=[Depends(human)]
    )
    def status():
        return dict(
            reports={
                name: dashboard.load_json(name + ".json")
                for name in ("releases", "digests", "actions", "nix")
            },
            history=list(reversed(dashboard.load_json("history.json", []))),
            actions=dashboard.action_status(),
        )

    @app.post(
        "/api/actions",
        response_model=Queued,
        status_code=202,
        dependencies=[Depends(human)],
    )
    def action(body: Annotated[Scan | CreatePR, Field(discriminator="action")]):
        try:
            with action_lock:
                if isinstance(body, Scan):
                    dashboard.queue_scan(body.target)
                else:
                    dashboard.queue_pull_request(body.kind, body.target)
        except ValueError as error:
            raise HTTPException(400, str(error)) from None
        except RuntimeError as error:
            raise HTTPException(409, str(error)) from None
        return Queued()

    @app.api_route(
        "/pipeline/reports",
        methods=["GET", "HEAD"],
        dependencies=[Depends(human)],
        include_in_schema=False,
    )
    @app.api_route(
        "/pipeline/reports/{path:path}",
        methods=["GET", "HEAD"],
        dependencies=[Depends(human)],
        include_in_schema=False,
    )
    def legacy(path: str = ""):
        return RedirectResponse("/", status_code=302)

    if settings.static:
        app.mount("/", StaticFiles(directory=settings.static, html=True))
    return app


def from_environment():
    return create_app(
        Settings(
            origin=os.environ["UPDATES_ORIGIN"],
            aliases=tuple(os.environ.get("UPDATES_ALIASES", "").split()),
            database=os.environ["UPDATES_DATABASE"],
            enrollment_token=Path(os.environ["UPDATES_ENROLLMENT_FILE"])
            .read_text()
            .strip(),
            data=os.environ["UPDATES_DATA"],
            static=os.environ["UPDATES_STATIC"],
            inventory=os.environ["UPDATES_INVENTORY"],
            systemctl=os.environ["UPDATES_SYSTEMCTL"],
            token=os.environ["UPDATES_GITHUB_TOKEN_FILE"],
        )
    )
