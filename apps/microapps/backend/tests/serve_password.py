"""Disposable HTTPS server for browser tests of actual short hostnames."""

import datetime as dt
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
from microapps.api import Settings, create_app
from microapps.auth_store import AuthStore
from serve_updates import prepare_static
from updates_api import Settings as UpdateSettings
from updates_api import create_app as update_app

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "approve.example.test")])
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
                [
                    x509.DNSName(host)
                    for host in (
                        "approve",
                        "approve.example.test",
                        "updates",
                        "updates.example.test",
                    )
                ]
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
    app = create_app(
        Settings(
            "https://approve.example.test:5175",
            str(root / "db"),
            "r" * 32,
            "w" * 32,
            "e" * 32,
            static=str(Path(__file__).resolve().parents[2] / "web/dist"),
            aliases=("https://approve:5175",),
            account_socket=str(root / "accounts.sock"),
        )
    )
    static = root / "updates-static"
    prepare_static(static)
    updates = update_app(
        UpdateSettings(
            "https://updates.example.test:5176",
            str(root / "updates.db"),
            "",
            str(root / "reports"),
            str(static),
            aliases=("https://updates:5176",),
            account_socket=str(root / "accounts.sock"),
            systemctl="/no-systemctl",
        )
    )
    servers = [
        uvicorn.Server(
            uvicorn.Config(
                account_app(Account(AuthStore(root / "accounts.db"), "e" * 32)),
                uds=str(root / "accounts.sock"),
                log_level="error",
            )
        ),
        uvicorn.Server(
            uvicorn.Config(
                updates,
                host="127.0.0.1",
                port=5176,
                ssl_keyfile=str(root / "key.pem"),
                ssl_certfile=str(root / "cert.pem"),
                log_level="error",
            )
        ),
    ]
    threads = [threading.Thread(target=server.run, daemon=True) for server in servers]
    for thread in threads:
        thread.start()
    try:
        deadline = time.monotonic() + 10
        while not all(server.started for server in servers):
            if time.monotonic() > deadline:
                raise RuntimeError("Test account servers did not start")
            time.sleep(0.01)
        uvicorn.run(
            app,
            host="127.0.0.1",
            port=5175,
            ssl_keyfile=str(root / "key.pem"),
            ssl_certfile=str(root / "cert.pem"),
        )
    finally:
        for server in servers:
            server.should_exit = True
        for thread in threads:
            thread.join(10)
