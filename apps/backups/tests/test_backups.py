import json
import time

import pytest
from api import Settings, create_app
from collector import (
    atomic_json,
    collect,
    parse_datasets,
    parse_pool,
    parse_snapshots,
    record_run,
    snapshot_duration,
)
from fastapi.testclient import TestClient
from microapps.auth_store import digest
from models import Dataset, Disk, Pool, Report, Run, Snapshot
from notify import notify
from status import evaluate, load_status

NOW = 1800000000


@pytest.fixture
def report():
    return Report(
        collected_at=NOW,
        repository="Backblaze B2",
        paths=["/Data/smb"],
        exclusions=["/Data/smb/Imports"],
        retention=["--keep-daily 14"],
        pools=[
            Pool(
                name="Data",
                health="ONLINE",
                size=1000,
                allocated=500,
                free=500,
                capacity=50,
                scan="scrub repaired 0B in 01:00:00 with 0 errors",
                scrub_at=NOW - 86400,
                disks=[Disk(name="disk1", state="ONLINE", read=0, write=0, checksum=0)],
                data_errors="No known data errors",
            )
        ],
        datasets=[
            Dataset(
                name="Data/smb",
                used=500,
                available=500,
                mountpoint="/Data/smb",
                snapshots_enabled=True,
                snapshot_count=30,
                latest_automatic=NOW - 900,
                offsite="Included",
            )
        ],
        snapshots=[
            Snapshot(id="a" * 64, time=NOW - 3600, hostname="nasa", paths=["/Data/smb"])
        ],
        backup=Run(
            started=NOW - 7200,
            finished=NOW - 3600,
            result="success",
            last_success=NOW - 3600,
        ),
        backup_state="inactive",
        database_state="inactive",
        retained_snapshots=30,
    )


def ids(status):
    return {a.id for a in status.alerts}


def test_healthy_and_stale_evidence(report):
    assert not evaluate(report, NOW).alerts
    assert "report-stale" in ids(evaluate(report, NOW + 1801))
    assert "report-stale" in ids(evaluate(report, NOW - 61))
    assert "report-missing" in ids(evaluate(None, NOW))
    report.backup.last_success = None
    assert "backup-overdue" in ids(evaluate(report, NOW))
    # A current repository snapshot never substitutes for a successful run.
    report.backup.result = "exit-code"
    assert "backup-failed" in ids(evaluate(report, NOW))


def test_all_health_failures(report):
    report.pools[0].health = "DEGRADED"
    report.pools[0].capacity = 95
    report.pools[0].disks[0].checksum = 2
    report.pools[0].data_errors = "Permanent errors detected"
    report.pools[0].scrub_at = NOW - 41 * 86400
    report.pools[0].scan = "scrub repaired 1M with 2 errors"
    report.datasets[0].latest_automatic = None
    report.backup_state = "failed"
    report.database_state = "failed"
    report.backup.last_success = NOW - 37 * 3600
    report.snapshots = []
    report.errors = ["Repository unavailable"]
    assert ids(evaluate(report, NOW)) == {
        "collector-0",
        "pool-Data",
        "capacity-Data",
        "disks-Data",
        "data-Data",
        "scrub-Data",
        "scrub-errors-Data",
        "snapshots-Data/smb",
        "backup-service",
        "database-failed",
        "backup-overdue",
        "offsite-overdue",
    }
    report.datasets[0].snapshots_enabled = False
    assert "snapshots-Data/smb" not in ids(evaluate(report, NOW))


def test_run_history_preserves_success_on_partial_backup(tmp_path):
    record_run(tmp_path, "start", NOW)
    record_run(
        tmp_path, "finish", NOW + 10, {"SERVICE_RESULT": "success", "EXIT_STATUS": "0"}
    )
    record_run(tmp_path, "start", NOW + 100)
    record_run(
        tmp_path,
        "finish",
        NOW + 110,
        {"SERVICE_RESULT": "exit-code", "EXIT_STATUS": "3"},
    )
    run = Run.model_validate_json((tmp_path / "run.json").read_text())
    assert run.result == "exit-code"
    assert run.last_success == NOW + 10
    assert run.exit_status == "3"
    assert len(json.loads((tmp_path / "history.json").read_text())) == 2
    record_run(tmp_path, "start", NOW + 200)
    record_run(tmp_path, "finish", NOW + 210, {})
    assert json.loads((tmp_path / "run.json").read_text())["last_success"] == NOW + 10


def test_parse_realistic_pool_status():
    status = """  pool: Data
 state: ONLINE
  scan: scrub repaired 0B in 02:10:10 with 0 errors on Sun Nov  1 00:00:00 2026
config:

        NAME        STATE     READ WRITE CKSUM
        Data        ONLINE       0     0     0
          mirror-0  ONLINE       0     0     0
            disk-a  ONLINE       0     0     2
            disk-b  ONLINE       0     0     0

errors: No known data errors
"""
    pool = parse_pool("Data\t1000\t500\t500\t50\tONLINE", status)
    assert pool.scrub_at == 1793491200
    assert pool.disks[2].checksum == 2
    assert pool.data_errors == "No known data errors"
    running = parse_pool(
        "Data\t1000\t500\t500\t50\tONLINE",
        status.replace(
            "scrub repaired 0B in 02:10:10 with 0 errors on Sun Nov  1 00:00:00 2026",
            "scrub in progress since Sun Nov  1 00:00:00 2026\n        45% done",
        ),
    )
    assert "45% done" in running.scan
    assert running.scrub_at is None


def test_dataset_coverage_and_automatic_freshness():
    datasets = "Data/smb\t500\t500\t/Data/smb\ttrue\nData/smb2\t1\t9\t/Data/smb2\tfalse\nroot\t1\t9\t/\t-"
    datasets = "\n".join(
        line + "\tyes\t-\t-\t-\t-\t-" for line in datasets.splitlines()
    )
    snapshots = (
        "Data/smb@manual\t1800000000\nData/smb@zfs-auto-snap_frequent-2026\t1799999000"
    )
    result = parse_datasets(
        datasets, snapshots, ["/Data/smb", "/.zfs/snapshot/root.img"]
    )
    assert result[0].latest_automatic == 1799999000
    assert result[0].latest_snapshot == 1800000000
    assert result[0].snapshot_count == 2
    assert result[0].offsite.startswith("Included")
    assert not result[1].snapshots_enabled
    assert result[1].offsite.startswith("Not included")
    assert result[2].offsite.startswith("Not included")


def test_restic_sorting_and_optional_summaries():
    data = [
        {"id": "old", "time": "2026-11-01T00:00:00Z", "paths": ["/Data/smb"]},
        {
            "id": "new",
            "time": "2026-11-02T00:00:00.123456789Z",
            "summary": {
                "total_bytes_processed": 123,
                "backup_start": "2026-11-02T00:00:00.123456789Z",
                "backup_end": "2026-11-02T01:00:10.623456789+01:00",
            },
        },
    ]
    snapshots = parse_snapshots(json.dumps(data))
    assert [s.id for s in snapshots] == ["new", "old"]
    assert snapshots[0].bytes_processed == 123
    assert snapshots[1].duration is None


def test_failed_probes_are_reported_without_leaking_stderr(tmp_path):
    config = dict(
        repository="b2", paths=[], exclusions=[], retention=[], hostname="nasa"
    )
    calls = []

    def fail(args, **kwargs):
        calls.append(args)
        raise ValueError("SECRET")

    report = collect(config, tmp_path, probe=fail, now=NOW)
    assert len(report.errors) == 6
    assert "SECRET" not in (tmp_path / "report.json").read_text()
    assert all(args[1] in ("list", "snapshots", "show") for args in calls)
    assert "--no-lock" in next(args for args in calls if args[0] == "restic")


def test_corrupt_report_fails_closed(tmp_path):
    path = tmp_path / "report.json"
    for value in ("{", '{"collected_at": 123}'):
        path.write_text(value)
        assert "report-missing" in ids(load_status(path, NOW))


def test_reports_require_independent_session_and_no_controls(tmp_path, report):
    static = tmp_path / "web"
    static.mkdir()
    (static / "index.html").write_text("App shell")
    path = tmp_path / "private" / "report.json"
    atomic_json(path, report.model_dump())
    app = create_app(
        Settings(
            "https://backups.example.test",
            str(tmp_path / "auth.sqlite"),
            "b" * 32,
            str(path),
            str(static),
        )
    )
    client = TestClient(app, base_url="https://backups.example.test")
    assert client.get("/").status_code == 200
    assert client.get("/health").json() == {"status": "ok"}
    assert client.get("/api/status").status_code == 401
    assert client.get("/report.json").status_code == 404
    assert client.get("/run.json").status_code == 404
    assert (
        client.get(
            "/api/status", headers={"Authorization": "Bearer " + "b" * 32}
        ).status_code
        == 401
    )
    assert (
        client.get("/api/status", headers={"Host": "other.example.test"}).status_code
        == 400
    )
    assert client.post("/api/actions", json={"action": "restore"}).status_code in (
        404,
        405,
    )
    with app.state.store.transaction() as db:
        db.execute(
            "INSERT INTO sessions VALUES(?,?,?)",
            (digest("backups-session"), "csrf", time.time() + 60),
        )
    client.cookies.set("__Host-microapp", "other-app-session")
    assert client.get("/api/status").status_code == 401
    client.cookies.set("__Host-microapp", "backups-session")
    response = client.get("/api/status")
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert response.json()["report"]["repository"] == "Backblaze B2"
    assert client.post("/api/logout", json={}).status_code == 403
    assert (
        client.post(
            "/api/logout",
            json={},
            headers={"Origin": "https://backups.example.test", "X-CSRF-Token": "csrf"},
        ).status_code
        == 200
    )
    assert client.get("/api/status").status_code == 401


def test_notification_dedup_recovery_and_retry(tmp_path, report):
    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    sent = []

    def send(*args):
        sent.append(args)

    args = (path, state, "https://notify.test", "token", "https://backups.test")
    atomic_json(path, report.model_dump())
    assert not notify(*args, send=send, now=NOW)
    report.backup.result = "exit-code"
    atomic_json(path, report.model_dump())
    assert notify(*args, send=send, now=NOW)
    assert not notify(*args, send=send, now=NOW + 60)
    assert sent[0][3]["actions"] == []
    assert sent[0][3]["url"] == "https://backups.test/"
    report.backup.result = "success"
    report.backup.last_success = NOW + 100
    report.collected_at = NOW + 120
    atomic_json(path, report.model_dump())

    def fail(*args):
        raise OSError("unreachable")

    with pytest.raises(OSError):
        notify(*args, send=fail, now=NOW + 120)
    assert notify(*args, send=send, now=NOW + 120)
    assert sent[-1][3]["title"] == "Backups recovered"
    assert not notify(*args, send=send, now=NOW + 180)


def test_complete_collection_and_bounded_remote_history(tmp_path):
    config = dict(
        repository="b2",
        paths=["/Data/smb"],
        exclusions=["/Data/smb/Imports"],
        retention=["--keep-daily 14"],
        hostname="nasa",
    )
    record_run(tmp_path, "start", NOW - 120)
    record_run(
        tmp_path, "finish", NOW - 60, {"SERVICE_RESULT": "success", "EXIT_STATUS": "0"}
    )

    def probe(args, **kwargs):
        if args[:2] == ["zpool", "list"]:
            return "Data\t1000\t500\t500\t50\tONLINE\n"
        if args[:2] == ["zpool", "status"]:
            return "  scan: scrub repaired 0B with 0 errors on Sun Nov  1 00:00:00 2026\nconfig:\n        Data ONLINE 0 0 0\nerrors: No known data errors\n"
        if args[0] == "zfs":
            if "filesystem" in args:
                return "Data/smb\t500\t500\t/Data/smb\ttrue\tyes\t-\t-\t-\t-\t-\n"
            return f"Data/smb@zfs-auto-snap_frequent-2026\t{NOW - 900}\n"
        if args[0] == "restic":
            assert args[-2:] == ["--host", "nasa"]
            return json.dumps(
                [{"id": str(i), "time": "2026-11-07T00:00:00Z"} for i in range(35)]
            )
        if args[2].endswith(".timer"):
            return "Sun 2026-11-08 00:00:00 UTC"
        return "inactive\n"

    report = collect(config, tmp_path, probe=probe, now=NOW)
    assert not report.errors
    assert report.retained_snapshots == 35
    assert len(report.snapshots) == 30
    assert report.backup.last_success == NOW - 60
    assert len(report.history) == 1
    assert report.datasets[0].latest_automatic == NOW - 900
    assert report.pools[0].disks[0].state == "ONLINE"
    assert Report.model_validate_json((tmp_path / "report.json").read_text()) == report


def test_entire_dataset_exclusion_is_visible():
    result = parse_datasets(
        "Data/imports\t1\t9\t/Data/smb/Imports\ttrue\tyes\t-\t-\t-\t-\t-",
        "",
        ["/Data/smb"],
        ["/Data/smb/Imports"],
    )
    assert result[0].offsite == "Excluded from offsite backup"


def test_new_alert_after_recovery_gets_a_new_notification_key(tmp_path, report):
    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    sent = []
    args = (path, state, "https://notify.test", "token", "https://backups.test")

    def send(*args):
        sent.append(args[3])

    for index, result in enumerate(["exit-code", "success", "exit-code"]):
        report.backup.result = result
        report.collected_at = NOW + index * 60
        if result == "success":
            report.backup.last_success = NOW + index * 60 - 1
        atomic_json(path, report.model_dump())
        assert notify(*args, send=send, now=NOW + index * 60)
    assert len({notification["key"] for notification in sent}) == 3


@pytest.mark.parametrize("code", [408, 429, 500, 502, 503, 504, None])
def test_transient_notify_failure_retries(tmp_path, report, capsys, code):
    from urllib.error import HTTPError, URLError

    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    report.backup.result = "exit-code"
    atomic_json(path, report.model_dump())
    args = (path, state, "https://notify.test", "token", "https://backups")

    def fail(*args):
        if code is None:
            raise URLError("sensitive internal error")
        raise HTTPError(
            "https://notify.test", code, "sensitive internal error", {}, None
        )

    assert not notify(*args, send=fail, now=NOW)
    assert not state.exists()
    assert "sensitive" not in capsys.readouterr().err
    sent = []
    assert notify(*args, send=lambda *args: sent.append(args), now=NOW + 300)
    assert len(sent) == 1
    assert state.exists()


def test_notify_bad_credentials_still_fail(tmp_path, report):
    from urllib.error import HTTPError

    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    report.backup.result = "exit-code"
    atomic_json(path, report.model_dump())

    def fail(*args):
        raise HTTPError("https://notify.test", 403, "Forbidden", {}, None)

    with pytest.raises(HTTPError):
        notify(
            path,
            state,
            "https://notify.test",
            "token",
            "https://backups",
            send=fail,
            now=NOW,
        )
    assert not state.exists()


def dataset_properties(base="-", mounted="yes", **overrides):
    classes = ("frequent", "hourly", "daily", "weekly", "monthly")
    return "\t".join(
        [
            "rpool/root",
            "123",
            "456",
            "legacy",
            base,
            mounted,
            *(overrides.get(interval, "-") for interval in classes),
        ]
    )


def test_unset_snapshot_policy_does_not_alert(report):
    dataset = parse_datasets(dataset_properties(), "", ["/Data/smb"])[0]
    assert not dataset.snapshots_enabled
    assert dataset.snapshot_policy == "Not configured"
    report.datasets.append(dataset)
    assert not evaluate(report, NOW).alerts
    # Enabling snapshots with no snapshot evidence must still alert.
    report.datasets[-1] = parse_datasets(dataset_properties(base="true"), "", [])[0]
    assert "snapshots-rpool/root" in ids(evaluate(report, NOW))


def test_snapshot_interval_override_and_mount_state(report):
    raw = dataset_properties(base="true", frequent="false")
    snapshots = f"rpool/root@zfs-auto-snap_hourly-2026\t{NOW - 3700}\n"
    dataset = parse_datasets(raw, snapshots, [])[0]
    assert dataset.snapshot_interval == "hourly"
    assert dataset.snapshot_policy == "Hourly"
    report.datasets = [dataset]
    assert not evaluate(report, NOW).alerts
    assert "snapshots-rpool/root" in ids(evaluate(report, NOW + 3600))
    opted_in = parse_datasets(dataset_properties(base="false", daily="true"), "", [])[0]
    assert opted_in.snapshots_enabled and opted_in.snapshot_interval == "daily"
    unmounted = parse_datasets(dataset_properties(base="true", mounted="no"), "", [])[0]
    assert not unmounted.snapshots_enabled
    assert "not mounted" in unmounted.snapshot_policy
    unscheduled = parse_datasets(raw, snapshots, [], intervals=[])[0]
    assert not unscheduled.snapshots_enabled
    daily_only = parse_datasets(
        dataset_properties(base="true"), "", [], intervals=["daily"]
    )[0]
    assert daily_only.snapshot_interval == "daily"


@pytest.mark.parametrize("value", ["true", "mysql", "postgresql"])
def test_zfstools_opt_in_values(value):
    assert parse_datasets(dataset_properties(base=value), "", [])[0].snapshots_enabled


@pytest.mark.parametrize(
    "summary",
    [
        {},
        {"total_duration": 100},
        {"backup_start": "garbage", "backup_end": "2026-11-02T00:00:10Z"},
        {"backup_start": None, "backup_end": None},
        {"backup_start": "2026-11-02T00:00:10Z", "backup_end": "2026-11-02T00:00:00Z"},
        {"backup_start": "0001-01-01T00:00:00Z", "backup_end": "0001-01-01T00:00:00Z"},
        {"backup_start": "2026-11-02T00:00:00", "backup_end": "2026-11-02T00:00:01"},
    ],
)
def test_missing_or_invalid_snapshot_timing_is_not_fabricated(summary):
    assert snapshot_duration(summary) is None


def test_zero_duration_is_recorded():
    stamp = "2026-11-02T00:00:00Z"
    assert snapshot_duration({"backup_start": stamp, "backup_end": stamp}) == 0


def refresh_healthy_report(report, now, success_at=None):
    report.collected_at = now
    report.backup.result = "success"
    report.backup.last_success = now - 60 if success_at is None else success_at
    report.backup_state = "inactive"
    report.pools[0].scrub_at = now - 86400
    report.datasets[0].latest_automatic = now - 900
    report.snapshots[0].time = now - 120


def test_routine_healthy_days_are_silent(tmp_path, report):
    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    sent = []
    for day in range(4):
        now = NOW + day * 86400
        refresh_healthy_report(report, now)
        atomic_json(path, report.model_dump())
        assert not notify(
            path,
            state,
            "https://notify.test",
            "token",
            "https://backups",
            send=lambda *args: sent.append(args),
            now=now,
        )
    assert not sent


def test_recovery_waits_for_new_backup_and_sends_once(tmp_path, report):
    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    sent = []

    def send(*args):
        sent.append(args[3])

    def run(now):
        atomic_json(path, report.model_dump())
        return notify(
            path,
            state,
            "https://notify.test",
            "token",
            "https://backups",
            send=send,
            now=now,
        )

    report.pools[0].capacity = 90
    assert run(NOW)
    # A more recent observation still advances the incident while alerts deduplicate.
    report.collected_at = NOW + 600
    assert not run(NOW + 600)
    assert json.loads(state.read_text())["last_issue_at"] == NOW + 600
    report.pools[0].capacity = 50
    refresh_healthy_report(report, NOW + 900, success_at=NOW + 300)
    assert not run(NOW + 900)  # This backup preceded the latest problem evidence.
    refresh_healthy_report(report, NOW + 86400)
    report.backup_state = "activating"
    assert not run(NOW + 86400)
    report.backup_state = "inactive"
    assert run(NOW + 86400)
    assert sent[-1]["title"] == "Backups recovered"
    for day in (2, 3, 4):
        now = NOW + day * 86400
        refresh_healthy_report(report, now)
        assert not run(now)
    assert [message["title"] for message in sent] == [
        "Backups need attention",
        "Backups recovered",
    ]


def test_delayed_collector_does_not_delay_recovery_an_extra_backup(tmp_path, report):
    path, state = tmp_path / "report.json", tmp_path / "notify.json"
    sent = []

    def send(*args):
        sent.append(args[3])

    report.backup.result = "exit-code"
    atomic_json(path, report.model_dump())
    assert notify(
        path,
        state,
        "https://notify.test",
        "token",
        "https://backups",
        send=send,
        now=NOW + 300,
    )
    # A still-cached report is observed again after the backup actually completed.
    assert not notify(
        path,
        state,
        "https://notify.test",
        "token",
        "https://backups",
        send=send,
        now=NOW + 600,
    )
    refresh_healthy_report(report, NOW + 900, success_at=NOW + 500)
    atomic_json(path, report.model_dump())
    assert notify(
        path,
        state,
        "https://notify.test",
        "token",
        "https://backups",
        send=send,
        now=NOW + 900,
    )
    assert sent[-1]["title"] == "Backups recovered"
