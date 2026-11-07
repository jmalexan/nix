"""Disposable browser-test server with a realistic report and test-only setup code."""

import shutil
import sys
import tempfile
import time
from pathlib import Path

import uvicorn

repository = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repository / "apps/backups"))
from api import Settings, create_app  # noqa: E402
from collector import atomic_json  # noqa: E402
from models import Dataset, Disk, Pool, Report, Run, Snapshot  # noqa: E402

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    static = root / "web"
    source = repository / "apps/backups/web"
    shutil.copytree(source, static)
    shared = repository / "apps/microapps/web/src/shared"
    for name in ("components.js", "component-shadow.css"):
        shutil.copy(shared / name, static / name)
    shutil.copy(repository / "apps/microapps/web/dist-auth/auth.js", static / "auth.js")
    (static / "styles.css").write_text(
        "\n".join(
            (shared / name).read_text() for name in ("tokens.css", "components.css")
        )
        + (source / "styles.css").read_text()
    )
    now = time.time()
    report = Report(
        collected_at=now,
        repository="Backblaze B2",
        paths=["/Data/smb"],
        exclusions=["/Data/smb/Imports", "/Data/smb/Internal/Services/frigate/media"],
        retention=["--keep-daily 14", "--keep-weekly 8", "--keep-monthly 12"],
        pools=[
            Pool(
                name="Data",
                health="ONLINE",
                size=16 * 1024**4,
                allocated=6 * 1024**4,
                free=10 * 1024**4,
                capacity=37.5,
                scan="scrub repaired 0B with 0 errors",
                scrub_at=now - 86400,
                disks=[
                    Disk(
                        name="ata-WDC-WD180EDGZ",
                        state="ONLINE",
                        read=0,
                        write=0,
                        checksum=0,
                    )
                ],
                data_errors="No known data errors",
            )
        ],
        datasets=[
            Dataset(
                name="Data/smb",
                used=6 * 1024**4,
                available=10 * 1024**4,
                mountpoint="/Data/smb",
                snapshots_enabled=True,
                snapshot_count=62,
                latest_automatic=now - 900,
                offsite="Included, subject to exclusions",
            )
        ],
        snapshots=[
            Snapshot(
                id="a" * 64,
                time=now - 3600,
                hostname="nasa",
                paths=["/Data/smb"],
                bytes_processed=6 * 1024**4,
                duration=1800,
            )
        ],
        retained_snapshots=34,
        backup=Run(last_success=now - 1800, result="success"),
        backup_state="inactive",
        database_state="inactive",
        next_backup="Tomorrow at midnight",
    )
    atomic_json(root / "report.json", report.model_dump())
    app = create_app(
        Settings(
            "http://localhost:5175",
            str(root / "auth.sqlite"),
            "b" * 32,
            str(root / "report.json"),
            str(static),
        )
    )
    uvicorn.run(app, host="127.0.0.1", port=5175)
