"""Fixed read-only probes; credentials and host access stay outside the web app."""

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

from models import Dataset, Disk, Pool, Report, Run, Snapshot


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".report-")
    try:
        with os.fdopen(fd, "w") as target:
            json.dump(value, target)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
            os.fchmod(target.fileno(), 0o640)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def read_json(path, fallback):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return fallback


def record_run(root, phase, now=None, environ=None):
    """A failed/partial run cannot replace the last successful completion."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    now = time.time() if now is None else now
    environ = os.environ if environ is None else environ
    with (root / "run.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        run = Run.model_validate(read_json(root / "run.json", {}))
        if phase == "start":
            run = Run(started=now, result="running", last_success=run.last_success)
        else:
            run.finished = now
            run.result = environ.get("SERVICE_RESULT", "unknown")
            run.exit_status = environ.get("EXIT_STATUS")
            if run.result == "success":
                run.last_success = now
            history = read_json(root / "history.json", [])
            atomic_json(root / "history.json", [run.model_dump(), *history][:30])
        atomic_json(root / "run.json", run.model_dump())


def command(args, timeout=30):
    # Deliberately do not expose stderr: tools can include credential-bearing URLs.
    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        env={**os.environ, "LC_ALL": "C", "TZ": "UTC"},
    )
    if result.returncode:
        raise ValueError("Probe failed")
    return result.stdout


def parse_pool(line, status):
    name, size, allocated, free, capacity, health = line.split("\t")
    scan = re.search(
        r"^\s*scan:\s*(.*?)(?=\n\S|\n\s*(?:config|remove|errors):|\Z)",
        status,
        re.M | re.S,
    )
    scan = " ".join(scan.group(1).split()) if scan else "Unknown"
    scrub_at = None
    match = re.search(
        r"scrub repaired .*? on (\w{3} \w{3}\s+\d+ \d\d:\d\d:\d\d \d{4})", scan
    )
    if match:
        scrub_at = (
            dt.datetime.strptime(match.group(1), "%a %b %d %H:%M:%S %Y")
            .replace(tzinfo=dt.timezone.utc)
            .timestamp()
        )
    disks = []
    for match in re.finditer(
        r"^\s+(\S+)\s+(ONLINE|DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|AVAIL)\s+(\d+)\s+(\d+)\s+(\d+)\s*$",
        status,
        re.M,
    ):
        disk, state, read, write, checksum = match.groups()
        disks.append(
            Disk(
                name=disk,
                state=state,
                read=int(read),
                write=int(write),
                checksum=int(checksum),
            )
        )
    errors = re.search(r"^errors:\s*(.*)", status, re.M)
    return Pool(
        name=name,
        size=int(size),
        allocated=int(allocated),
        free=int(free),
        capacity=float(capacity),
        health=health,
        scan=scan,
        scrub_at=scrub_at,
        disks=disks,
        data_errors=errors.group(1) if errors else "Data error status unavailable",
    )


def parse_datasets(datasets, snapshots, paths, exclusions=()):
    by_dataset = {}
    for line in snapshots.splitlines():
        name, created = line.split("\t")
        dataset, suffix = name.split("@", 1)
        by_dataset.setdefault(dataset, []).append((suffix, float(created)))
    result = []
    for line in datasets.splitlines():
        name, used, available, mountpoint, automatic = line.split("\t")
        snaps = by_dataset.get(name, [])
        managed = [
            created
            for suffix, created in snaps
            if suffix.startswith("zfs-auto-snap_frequent-")
        ]
        included = mountpoint.startswith("/") and any(
            mountpoint == path or mountpoint.startswith(path.rstrip("/") + "/")
            for path in paths
        )
        excluded = mountpoint.startswith("/") and any(
            mountpoint == path or mountpoint.startswith(path.rstrip("/") + "/")
            for path in exclusions
        )
        result.append(
            Dataset(
                name=name,
                used=int(used),
                available=int(available),
                mountpoint=mountpoint,
                snapshots_enabled=automatic != "false",
                snapshot_count=len(snaps),
                latest_snapshot=max((s[1] for s in snaps), default=None),
                latest_automatic=max(managed, default=None),
                offsite="Excluded from offsite backup"
                if excluded
                else "Included, subject to exclusions"
                if included
                else "Not included as a whole dataset",
            )
        )
    return result


def parse_snapshots(raw):
    result = []
    for item in json.loads(raw):
        summary = item.get("summary") or {}
        result.append(
            Snapshot(
                id=item["id"],
                time=dt.datetime.fromisoformat(
                    item["time"].replace("Z", "+00:00")
                ).timestamp(),
                hostname=item.get("hostname", "Unknown"),
                paths=item.get("paths", []),
                bytes_processed=summary.get("total_bytes_processed"),
                duration=summary.get("total_duration"),
            )
        )
    return sorted(result, key=lambda s: s.time, reverse=True)


def collect(config, root, probe=command, now=None):
    root = Path(root)
    report = Report(
        collected_at=time.time() if now is None else now,
        repository=config["repository"],
        paths=config["paths"],
        exclusions=config["exclusions"],
        retention=config["retention"],
        backup=Run.model_validate(read_json(root / "run.json", {})),
        history=read_json(root / "history.json", []),
    )
    try:
        previous = Report.model_validate(read_json(root / "report.json", {}))
        previous_scrubs = {pool.name: pool.scrub_at for pool in previous.pools}
    except ValueError:
        previous_scrubs = {}
    try:
        lines = probe(
            ["zpool", "list", "-Hp", "-o", "name,size,allocated,free,capacity,health"]
        )
        for line in lines.splitlines():
            name = line.split("\t")[0]
            pool = parse_pool(line, probe(["zpool", "status", "-p", name]))
            if "scrub in progress" in pool.scan or "resilver in progress" in pool.scan:
                pool.scrub_at = previous_scrubs.get(name)
            report.pools.append(pool)
    except (OSError, ValueError, subprocess.SubprocessError):
        report.errors.append("ZFS pool status could not be collected")
    try:
        report.datasets = parse_datasets(
            probe(
                [
                    "zfs",
                    "list",
                    "-Hp",
                    "-t",
                    "filesystem",
                    "-o",
                    "name,used,available,mountpoint,com.sun:auto-snapshot",
                ]
            ),
            probe(["zfs", "list", "-Hp", "-t", "snapshot", "-o", "name,creation"]),
            config["paths"],
            config["exclusions"],
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        report.errors.append("ZFS snapshot status could not be collected")
    try:
        snapshots = parse_snapshots(
            probe(
                [
                    "restic",
                    "snapshots",
                    "--json",
                    "--no-lock",
                    "--host",
                    config["hostname"],
                ],
                timeout=120,
            )
        )
        report.retained_snapshots = len(snapshots)
        report.snapshots = snapshots[:30]
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        report.errors.append("Offsite repository could not be read")
    for field, unit, prop in (
        ("backup_state", "restic-backups-backblaze.service", "ActiveState"),
        ("database_state", "database-backup.service", "ActiveState"),
        ("next_backup", "restic-backups-backblaze.timer", "NextElapseUSecRealtime"),
    ):
        try:
            setattr(
                report,
                field,
                probe(
                    ["systemctl", "show", unit, "--value", f"--property={prop}"]
                ).strip()
                or "Unknown",
            )
        except (OSError, ValueError, subprocess.SubprocessError):
            report.errors.append(f"Service status unavailable: {unit}")
    atomic_json(root / "report.json", report.model_dump())
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--config")
    parser.add_argument("--record", choices=["start", "finish"])
    args = parser.parse_args()
    if args.record:
        record_run(args.root, args.record)
    else:
        collect(json.loads(Path(args.config).read_text()), args.root)


if __name__ == "__main__":
    main()
