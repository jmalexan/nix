"""Disposable browser-test server with a realistic report and test-only setup code."""

import datetime as dt
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path

import uvicorn
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from microapps.accounts import Account
from microapps.accounts import create_app as account_app
from microapps.auth_store import AuthStore

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
    # Test-only account setup; production requires the host account socket.
    account = Account(AuthStore(root / "accounts.sqlite"), "e" * 32)
    account.enroll("one shared password for NASA apps", "e" * 32)
    socket = str(root / "accounts.sock")
    server = uvicorn.Server(
        uvicorn.Config(account_app(account), uds=socket, log_level="error")
    )
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "backups.example.test")])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=1))
        .not_valid_after(now + dt.timedelta(days=1))
        .add_extension(
            x509.SubjectAlternativeName(
                [x509.DNSName("backups"), x509.DNSName("backups.example.test")]
            ),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    (root / "key.pem").write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    (root / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    try:
        deadline = time.monotonic() + 10
        while not server.started:
            assert thread.is_alive() and time.monotonic() < deadline
            time.sleep(0.01)
        app = create_app(
            Settings(
                "https://backups.example.test:5177",
                str(root / "auth.sqlite"),
                "",
                str(root / "report.json"),
                str(static),
                aliases=("https://backups:5177",),
                account_socket=socket,
            )
        )
        uvicorn.run(
            app,
            host="127.0.0.1",
            port=5177,
            ssl_keyfile=str(root / "key.pem"),
            ssl_certfile=str(root / "cert.pem"),
        )
    finally:
        server.should_exit = True
        thread.join(10)
