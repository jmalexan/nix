"""Real TLS + CLI + local upstream: no production credentials or writes."""

import datetime as dt
import os
import socket
import subprocess
import sys
import threading
import time

import uvicorn
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from fastapi import HTTPException, Request
from git_broker.api import create_app
from helpers import ApprovedGate, git


def test_client_clone_fetch_push_over_verified_https(repository, tmp_path):
    backend, local, upstream = repository
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
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
            x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False
        )
        .sign(key, hashes.SHA256())
    )
    certfile, keyfile = tmp_path / "cert.pem", tmp_path / "key.pem"
    certfile.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    keyfile.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    tokenfile = tmp_path / "broker-token"
    tokenfile.write_text("c" * 32)
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    pending = {}

    class PhoneGate(ApprovedGate):
        def claim(self, rid, scope):
            assert pending.pop(rid) == scope
            return time.time() + 180

    app = create_app(backend, "c" * 32, approval_gate=PhoneGate())

    @app.post("/api/requests")
    async def approve_for_test(request: Request):
        if request.headers.get("authorization") != "Bearer " + "r" * 32:
            raise HTTPException(401)
        body = await request.json()
        assert body["operation"] == "git.push"
        pending["p" * 24] = body["push"]
        return {"id": "p" * 24}

    @app.get("/api/requester/requests/{rid}")
    def approved_for_test(rid: str):
        assert rid in pending
        return {"state": "approved"}

    requester = tmp_path / "requester"
    requester.write_text("r" * 32)
    server = uvicorn.Server(
        uvicorn.Config(
            app,
            log_level="error",
            ssl_certfile=str(certfile),
            ssl_keyfile=str(keyfile),
        )
    )
    thread = threading.Thread(
        target=server.run, kwargs={"sockets": [sock]}, daemon=True
    )
    thread.start()
    try:
        for _ in range(500):
            if server.started:
                break
            time.sleep(0.01)
        assert server.started
        env = {
            **os.environ,
            "GIT_BROKER_ORIGIN": f"https://localhost:{port}",
            "GIT_BROKER_APPROVAL_ORIGIN": f"https://localhost:{port}",
            "NASA_APPROVAL_REQUESTER_FILE": str(requester),
            "GIT_BROKER_TOKEN_FILE": str(tokenfile),
            "SSL_CERT_FILE": str(certfile),
            "NIX_SSL_CERT_FILE": str(certfile),
        }

        def client(*args, cwd=None, check=True):
            result = subprocess.run(
                (
                    [os.environ["GIT_BROKER_TEST_CLIENT"], *args]
                    if os.environ.get("GIT_BROKER_TEST_CLIENT")
                    else [sys.executable, "-m", "git_broker.client", *args]
                ),
                cwd=cwd,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            if check:
                assert result.returncode == 0, result.stderr
            return result

        clone = tmp_path / "client-clone"
        client("clone", "project", str(clone))
        assert (clone / "README").read_text() == "initial\n"
        config = (clone / ".git/config").read_text()
        assert "broker://project" in config and "upstream-secret" not in config
        git(clone, "checkout", "-b", "robot/client")
        (clone / "README").write_text("from client\n")
        git(clone, "commit", "-am", "Client change")
        result = client("push", "--reason", "Publish test commit", cwd=clone)
        assert (
            result.returncode == 0
            and "upstream-secret" not in result.stdout + result.stderr
        )
        assert git(upstream, "rev-parse", "robot/client") == git(
            clone, "rev-parse", "HEAD"
        )
        (local / "README").write_text("updated main\n")
        git(local, "commit", "-am", "Upstream change")
        git(local, "push", "origin", "main")
        client("fetch", cwd=clone)
        assert git(clone, "rev-parse", "origin/main") == git(local, "rev-parse", "main")
        assert (
            client(
                "push", "main", "--reason", "Must reject", cwd=clone, check=False
            ).returncode
            == 1
        )
        assert git(upstream, "rev-parse", "main") == git(local, "rev-parse", "main")
    finally:
        server.should_exit = True
        thread.join(timeout=10)
        sock.close()
