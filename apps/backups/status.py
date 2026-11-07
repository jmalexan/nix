"""Fail visibly for missing, stale, or unhealthy protection evidence."""

import time
from pathlib import Path

from models import Alert, Report, Status
from pydantic import ValidationError


def evaluate(report, now=None):
    now = time.time() if now is None else now
    alerts = []

    def add(key, message, severity="warning"):
        alerts.append(Alert(id=key, severity=severity, message=message))

    if report is None:
        add("report-missing", "Waiting for the first storage report")
        return Status(alerts=alerts, checked_at=now)
    if now - report.collected_at > 1800 or report.collected_at > now + 60:
        add("report-stale", "Storage report is out of date", "error")
    for index, error in enumerate(report.errors):
        add(f"collector-{index}", error, "error")
    if not report.pools:
        add("pools-missing", "No ZFS pools reported", "error")
    if not report.datasets:
        add("datasets-missing", "No ZFS datasets reported", "error")
    for pool in report.pools:
        if not pool.disks:
            add(
                f"devices-missing-{pool.name}",
                f"{pool.name}: device status unavailable",
                "error",
            )
        if pool.health != "ONLINE":
            add(f"pool-{pool.name}", f"{pool.name}: {pool.health}", "error")
        if pool.capacity >= 80:
            add(
                f"capacity-{pool.name}",
                f"{pool.name} is {pool.capacity:g}% full",
                "error" if pool.capacity >= 90 else "warning",
            )
        if any(
            d.read or d.write or d.checksum or d.state != "ONLINE" for d in pool.disks
        ):
            add(
                f"disks-{pool.name}",
                f"{pool.name}: disk errors or unavailable devices",
                "error",
            )
        if pool.data_errors != "No known data errors":
            add(f"data-{pool.name}", f"{pool.name}: {pool.data_errors}", "error")
        if "with 0 errors" not in pool.scan and "scrub repaired" in pool.scan:
            add(
                f"scrub-errors-{pool.name}",
                f"{pool.name}: scrub reported errors",
                "error",
            )
        if pool.scrub_at is None or now - pool.scrub_at > 40 * 86400:
            add(
                f"scrub-{pool.name}",
                f"{pool.name}: no completed scrub in the last 40 days",
            )
    for dataset in report.datasets:
        if dataset.snapshots_enabled and (
            dataset.latest_automatic is None or now - dataset.latest_automatic > 3600
        ):
            add(
                f"snapshots-{dataset.name}",
                f"{dataset.name}: automatic snapshots overdue",
            )
    if report.backup.result not in ("success", "running", "unknown"):
        add("backup-failed", "The last offsite backup attempt failed", "error")
    if report.database_state == "failed":
        add("database-failed", "Database export failed before offsite backup", "error")
    if report.backup_state == "failed":
        add("backup-service", "The offsite backup service is failed", "error")
    if (
        report.backup.last_success is None
        or now - report.backup.last_success > 36 * 3600
    ):
        add(
            "backup-overdue",
            "No successful offsite backup recorded in the last 36 hours",
            "error",
        )
    if not report.snapshots or now - report.snapshots[0].time > 36 * 3600:
        add("offsite-overdue", "No offsite snapshot from the last 36 hours", "error")
    return Status(report=report, alerts=alerts, checked_at=now)


def load_status(path, now=None):
    try:
        report = Report.model_validate_json(Path(path).read_text())
    except (OSError, ValueError, ValidationError):
        report = None
    return evaluate(report, now)
