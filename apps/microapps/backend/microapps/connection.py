"""Immutable connection scope shared by the API and independently checking gate."""

import base64
from typing import Literal

from cryptography.hazmat.primitives.serialization import load_ssh_public_key
from pydantic import BaseModel, ConfigDict, Field, field_validator


class ConnectionScope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target: Literal["nasa"] = "nasa"
    account: Literal["nasa-automation"] = "nasa-automation"
    max_seconds: Literal[900] = 900
    public_key: str = Field(max_length=128)

    @field_validator("public_key")
    @classmethod
    def valid_key(cls, value):
        parts = value.split(" ")
        if len(parts) != 2 or parts[0] != "ssh-ed25519":
            raise ValueError("An uncommented Ed25519 public key is required")
        blob = base64.b64decode(parts[1], validate=True)
        if base64.b64encode(blob).decode() != parts[1]:
            raise ValueError("Noncanonical public key")
        load_ssh_public_key(value.encode())
        return value


def request_view(db, row):
    result = dict(row)
    connection = db.execute(
        "SELECT scope,deadline FROM connections WHERE request_id=?", (row["id"],)
    ).fetchone()
    result["connection"] = (
        ConnectionScope.model_validate_json(connection["scope"]).model_dump()
        if connection
        else None
    )
    result["connection_deadline"] = connection["deadline"] if connection else None
    return result
