"""Disposable HTTPS server for browser tests of actual short hostnames."""

import datetime as dt
import tempfile
from pathlib import Path

import uvicorn
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from microapps.api import Settings, create_app

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
                [x509.DNSName("approve"), x509.DNSName("approve.example.test")]
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
        )
    )
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=5175,
        ssl_keyfile=str(root / "key.pem"),
        ssl_certfile=str(root / "cert.pem"),
    )
