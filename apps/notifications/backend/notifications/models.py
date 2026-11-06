import re
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, ConfigDict, Field, model_validator


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


def https_url(value):
    url = urlsplit(value)
    if (
        url.scheme != "https"
        or not url.hostname
        or url.username
        or url.password
        or url.port not in (None, 443)
        or "\\" in value
        or any(ord(c) < 33 for c in value)
    ):
        raise ValueError("An HTTPS URL without credentials is required")
    return f"https://{url.hostname}"


class Action(Input):
    id: str = Field(pattern=r"^[a-zA-Z0-9_-]{1,40}$")
    title: str = Field(min_length=1, max_length=40)
    kind: Literal["open", "respond", "reply"] = "open"
    url: str | None = Field(default=None, max_length=2048)
    # All responses require unlock; services cannot weaken this requirement.


class Notification(Input):
    recipient: str = Field(pattern=r"^[a-zA-Z0-9_-]{1,64}$")
    key: str = Field(min_length=1, max_length=128)
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(default="", max_length=500)
    url: str = Field(max_length=2048)
    image: str | None = Field(default=None, max_length=2048)
    group: str = Field(default="default", max_length=64)
    ttl: int = Field(default=600, ge=30, le=86400)
    expires_at: float | None = Field(default=None, allow_inf_nan=False)
    actions: list[Action] = Field(default_factory=list, max_length=4)

    @model_validator(mode="after")
    def unique_actions(self):
        if len({a.id for a in self.actions}) != len(self.actions):
            raise ValueError("Action identifiers must be unique")
        for action in self.actions:
            if (action.kind == "open") != (action.url is not None):
                raise ValueError("Only open actions require a URL")
        return self


class Enroll(Input):
    code: str = Field(min_length=32, max_length=128)
    name: str = Field(min_length=1, max_length=80)
    apns_token: str = Field(pattern=r"^[a-fA-F0-9]{64,200}$")
    environment: Literal["sandbox", "production"]


class Registration(Input):
    apns_token: str = Field(pattern=r"^[a-fA-F0-9]{64,200}$")
    environment: Literal["sandbox", "production"]


class ResponseInput(Input):
    action: str = Field(max_length=40)
    text: str | None = Field(default=None, max_length=2000)


class Preference(Input):
    enabled: bool


class Ticket(Input):
    ticket: str = Field(max_length=128)


class Accepted(BaseModel):
    id: str
    expires: float


class DeviceCredential(BaseModel):
    id: str
    token: str


class Service(Input):
    token: str
    origins: list[str] = Field(min_length=1)
    recipients: list[str] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_config(self):
        if len(self.token) < 32:
            raise ValueError("Service credentials must have at least 32 characters")
        if any(https_url(o) != o for o in self.origins):
            raise ValueError("Service origins must be https://hostname")
        if any(not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", r) for r in self.recipients):
            raise ValueError("Invalid recipient")
        return self


class NotificationView(Notification):
    id: str
    service: str
    expires: float
    active: bool


class Status(BaseModel):
    status: str


class SettingsLink(BaseModel):
    url: str


class PreferencesView(BaseModel):
    name: str
    services: dict[str, bool]


class ServiceResponse(BaseModel):
    id: str
    key: str
    recipient: str
    action: str
    text: str | None
    created: float
    expires: float
