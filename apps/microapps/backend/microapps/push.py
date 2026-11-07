"""Exact Git update authorized by a human and consumed by the trusted broker."""

from pydantic import BaseModel, ConfigDict, Field, model_validator


class PushScope(BaseModel):
    model_config = ConfigDict(extra="forbid")
    repository: str = Field(
        pattern=r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"
    )
    branch: str = Field(pattern=r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")
    commit: str = Field(pattern=r"^[0-9a-f]{40}$")
    expected: str = Field(pattern=r"^[0-9a-f]{40}$")

    @model_validator(mode="after")
    def valid(self):
        if self.repository.split("/")[1] in (".", "..") or self.commit == "0" * 40:
            raise ValueError("A repository and nonzero commit are required")
        if (
            ".." in self.branch
            or "//" in self.branch
            or self.branch.endswith(("/", "."))
            or any(
                part.startswith(".") or part.endswith(".lock")
                for part in self.branch.split("/")
            )
        ):
            raise ValueError("Invalid branch")
        return self


class PushOutcome(BaseModel):
    model_config = ConfigDict(extra="forbid")
    outcome: str = Field(pattern=r"^(completed|failed)$")
