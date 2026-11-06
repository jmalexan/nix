"""Runs only inside the disposable NixOS VM, with its own keys and owner fixture."""

import json
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

from microapps import access
from microapps.http import call
from microapps.store import digest

access.HOST = "127.0.0.1"
ORIGIN = "http://localhost:8092"
TOKEN = "r" * 32


def owner_fixture():
    with sqlite3.connect("/var/lib/test-approvals/state.sqlite") as db:
        db.execute(
            "INSERT OR REPLACE INTO sessions VALUES(?,?,?)",
            (digest("test-owner"), "csrf", time.time() + 600),
        )


def submit(key, approved=True):
    result = call(
        ORIGIN,
        TOKEN,
        "/api/requests",
        {
            "operation": "ssh.connect",
            "reason": "VM integration test",
            "connection": {"public_key": key.with_suffix(".pub").read_text().strip()},
        },
    )
    if approved:
        req = urllib.request.Request(
            ORIGIN + f"/api/requests/{result['id']}/decision",
            data=json.dumps(
                {"decision": "approve", "connection": result["connection"]}
            ).encode(),
            headers={
                "Content-Type": "application/json",
                "Origin": ORIGIN,
                "X-CSRF-Token": "csrf",
                "Cookie": "microapp-dev=test-owner",
            },
        )
        with urllib.request.urlopen(req) as response:
            assert response.status == 200
    return result["id"]


def status(rid):
    return call(ORIGIN, TOKEN, f"/api/requester/requests/{rid}")["state"]


def wait_idle():
    for _ in range(60):
        processes = subprocess.run(
            ["pgrep", "-u", "nasa-automation"], capture_output=True
        )
        units = subprocess.check_output(
            [
                "systemctl",
                "list-units",
                "approval-ssh-gate@*",
                "--state=active,activating,deactivating",
                "--no-legend",
            ]
        ).strip()
        if processes.returncode == 1 and not units:
            return
        time.sleep(0.2)
    raise AssertionError("Connection processes survived service exit")


def run(key, rid, command, timeout=30):
    return subprocess.run(
        access.ssh_command(key, rid, ["bash", "-c", command]),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


owner_fixture()
Path("/var/lib/gate-writable").mkdir(mode=0o777)
Path("/var/lib/gate-writable").chmod(0o777)
Path("/root/.ssh").mkdir(mode=0o700, exist_ok=True)
Path("/root/.ssh/known_hosts").write_text(
    "127.0.0.1 " + Path("/etc/ssh/ssh_host_ed25519_key.pub").read_text()
)
with tempfile.TemporaryDirectory() as directory:
    key = Path(directory) / "key"
    other = Path(directory) / "other"
    for identity in (key, other):
        subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "",
                "-f",
                str(identity),
            ],
            check=True,
        )

    rid = submit(key, approved=False)
    assert run(key, rid, "id").returncode != 0
    assert status(rid) == "pending"
    wait_idle()
    print("PASS no approval, no connection", flush=True)

    rid = submit(key)
    assert run(other, rid, "id").returncode != 0
    wait_idle()
    assert status(rid) == "failed"
    assert run(key, rid, "id").returncode != 0
    wait_idle()
    print("PASS wrong key cannot connect or reuse consumed grant", flush=True)

    rid = submit(key)
    result = run(
        key,
        rid,
        "set -e; id -un; test ! -w /etc; test ! -w /home; test ! -w /var/lib/gate-writable; ! sudo -n true; test ! -w /run/dbus/system_bus_socket; echo approved",
    )
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert "nasa-automation" in result.stdout and "approved" in result.stdout
    wait_idle()
    assert status(rid) == "completed"
    subprocess.run(["systemctl", "restart", "test-approvals"], check=True)
    for _ in range(50):
        try:
            if status(rid) == "completed":
                break
        except OSError:
            time.sleep(0.1)
    assert run(key, rid, "id").returncode != 0
    wait_idle()
    print(
        "PASS approved connection, restricted account, replay after restart", flush=True
    )

    # Even a key placed in the normal listener's authorized_keys cannot admit
    # this account through the ordinary host sshd.
    Path("/run/test-normal-authorized-key").write_text(
        key.with_suffix(".pub").read_text()
    )
    Path("/run/test-normal-authorized-key").chmod(0o644)
    direct = subprocess.run(
        [
            "ssh",
            "-F",
            "/dev/null",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "IdentityAgent=none",
            "-i",
            str(key),
            "nasa-automation@127.0.0.1",
            "id",
        ],
        capture_output=True,
    )
    assert direct.returncode != 0
    print("PASS normal host sshd rejects gate account", flush=True)

    rid = submit(key)
    start = time.monotonic()
    # Detached session, closed stdio, ignored TERM: cgroup SIGKILL must still win.
    result = run(
        key,
        rid,
        "setsid bash -c 'trap \"\" TERM; exec sleep 120' </dev/null >/dev/null 2>&1 & echo running; sleep 120",
    )
    assert "running" in result.stdout, (result.stdout, result.stderr)
    assert time.monotonic() - start < 25
    wait_idle()
    assert status(rid) == "expired"
    assert run(key, rid, "id").returncode != 0
    wait_idle()
    print("PASS hard deadline kills SSH and detached descendants", flush=True)

    rid = submit(key)
    result = run(key, rid, "setsid sleep 120 </dev/null >/dev/null 2>&1 & echo leaving")
    assert result.returncode == 0 and "leaving" in result.stdout, (
        result.stdout,
        result.stderr,
    )
    wait_idle()
    assert status(rid) == "completed"
    print("PASS normal disconnect kills detached descendants", flush=True)

    rid = submit(key)
    process = subprocess.Popen(
        access.ssh_command(key, rid, ["sleep", "120"]),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    for _ in range(50):
        if status(rid) == "claimed":
            break
        time.sleep(0.1)
    units = (
        subprocess.check_output(
            [
                "systemctl",
                "list-units",
                "approval-ssh-gate@*",
                "--state=running",
                "--no-legend",
            ]
        )
        .decode()
        .splitlines()
    )
    assert len(units) == 1, units
    unit = units[0].split()[0]
    subprocess.run(
        ["systemctl", "kill", "--kill-whom=main", "--signal=KILL", unit], check=True
    )
    process.communicate(timeout=20)
    wait_idle()
    assert status(rid) == "failed"
    print("PASS broker crash leaves no live connection or reusable grant", flush=True)
