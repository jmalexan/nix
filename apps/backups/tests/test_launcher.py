"""Exercise the packaged executable with an assigned listener port."""

import json
import os
import socket
import subprocess
import time
from urllib.error import URLError
from urllib.request import urlopen

import pytest


def test_packaged_listener(tmp_path):
    launcher = os.environ.get("BACKUPS_TEST_LAUNCHER")
    if not launcher:
        pytest.skip("Run the packaged Backups check to test the installed launcher")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    origin = f"http://localhost:{port}"
    process = subprocess.Popen(
        [launcher],
        env={
            **os.environ,
            "PORT": str(port),
            "BACKUPS_ORIGIN": origin,
            "BACKUPS_DATABASE": str(tmp_path / "auth.sqlite"),
            "MICROAPP_ACCOUNT_SOCKET": str(tmp_path / "missing.sock"),
            "BACKUPS_REPORT": str(tmp_path / "report.json"),
            "BACKUPS_STATIC": str(tmp_path),
        },
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 10
        while True:
            assert process.poll() is None, (
                "Packaged server exited before becoming ready"
            )
            try:
                with urlopen(origin + "/health", timeout=1) as response:
                    assert json.load(response) == {"status": "ok"}
                break
            except URLError:
                assert time.monotonic() < deadline, (
                    "Configured listener never became ready"
                )
                time.sleep(0.05)
    finally:
        process.terminate()
        process.wait(timeout=10)
