"""Typed reports shared by the collector and authenticated API."""

from typing import Literal

from pydantic import BaseModel, Field


class Disk(BaseModel):
    name: str
    state: str
    read: int
    write: int
    checksum: int


class Pool(BaseModel):
    name: str
    health: str
    size: int
    allocated: int
    free: int
    capacity: float
    scan: str
    scrub_at: float | None = None
    disks: list[Disk] = Field(default_factory=list)
    data_errors: str


class Dataset(BaseModel):
    name: str
    used: int
    available: int
    mountpoint: str
    snapshots_enabled: bool
    snapshot_count: int
    latest_snapshot: float | None = None
    latest_automatic: float | None = None
    offsite: str


class Snapshot(BaseModel):
    id: str
    time: float
    hostname: str
    paths: list[str]
    bytes_processed: int | None = None
    duration: float | None = None


class Run(BaseModel):
    started: float | None = None
    finished: float | None = None
    result: str = "unknown"
    exit_status: str | None = None
    last_success: float | None = None


class Report(BaseModel):
    collected_at: float
    pools: list[Pool] = Field(default_factory=list)
    datasets: list[Dataset] = Field(default_factory=list)
    snapshots: list[Snapshot] = Field(default_factory=list)
    retained_snapshots: int = 0
    backup: Run = Field(default_factory=Run)
    history: list[Run] = Field(default_factory=list)
    backup_state: str = "unknown"
    database_state: str = "unknown"
    next_backup: str = "Unknown"
    repository: str
    paths: list[str]
    exclusions: list[str]
    retention: list[str]
    errors: list[str] = Field(default_factory=list)


class Alert(BaseModel):
    id: str
    severity: Literal["warning", "error"]
    message: str


class Status(BaseModel):
    report: Report | None = None
    alerts: list[Alert]
    checked_at: float
    verification: str = "No repository verification recorded"
    restore_test: str = "No restore test recorded"
