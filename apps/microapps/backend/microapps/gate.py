"""One accepted TCP socket, one consumed grant, one bounded sshd process tree.

Run only through the NixOS socket service, which owns the cgroup deadline and
kills descendants on exit, including after crashes or disconnected clients.
"""

import ipaddress
import json
import os
import pwd
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from .connection import ConnectionScope
from .http import call

REQUEST_ID = re.compile(r"[A-Za-z0-9_-]{24}")


def selector(connection):
    connection.settimeout(5)
    deadline = time.monotonic() + 5
    data = bytearray()
    while len(data) <= 24:
        connection.settimeout(max(0.001, deadline - time.monotonic()))
        byte = connection.recv(1)
        if not byte or time.monotonic() > deadline:
            raise ValueError("Missing request ID")
        if byte == b"\n":
            value = data.decode("ascii")
            if not REQUEST_ID.fullmatch(value):
                raise ValueError("Invalid request ID")
            connection.settimeout(None)
            return value
        data.extend(byte)
    raise ValueError("Request ID too long")


def validate_grant(grant, rid):
    if (
        grant["id"] != rid
        or grant["state"] != "claimed"
        or grant["operation"] != "ssh.connect"
    ):
        raise ValueError("Unexpected grant")
    scope = ConnectionScope.model_validate(grant["connection"])
    remaining = grant["connection_deadline"] - time.time()
    if not 0 < remaining <= scope.max_seconds:
        raise ValueError("Invalid connection deadline")
    return scope, remaining


def serve(connection, api, sshd, config, runtime, session_command=None):
    # The systemd deadline starts even earlier, at service activation.
    started = time.monotonic()
    rid = selector(connection)
    grant = api(f"/api/gate/{rid}/claim", {})
    record = Path(runtime) / "result.json"
    record.write_text(json.dumps({"id": rid, "outcome": "failed"}))
    record.chmod(0o600)
    outcome = "failed"
    try:
        scope, remaining = validate_grant(grant, rid)
        remaining = min(remaining, scope.max_seconds - (time.monotonic() - started))
        if remaining <= 0:
            raise ValueError("Connection deadline reached")
        with tempfile.TemporaryDirectory(
            prefix="connection-", dir=runtime
        ) as directory:
            os.chmod(directory, 0o755)
            key = Path(directory) / "authorized_key"
            key.write_text(scope.public_key + "\n")
            key.chmod(
                0o644
            )  # Public, root-owned; readable after sshd drops privileges.
            marker = Path(directory) / "session-started"
            marker.touch(mode=0o600)
            os.chown(marker, pwd.getpwnam(scope.account).pw_uid, -1)
            print(
                json.dumps({"request_id": rid, "event": "starting"}),
                file=sys.stderr,
                flush=True,
            )
            with subprocess.Popen(
                [
                    sshd,
                    "-i",
                    "-e",
                    "-f",
                    config,
                    "-o",
                    f"AuthorizedKeysFile={key}",
                    "-o",
                    "ForceCommand=" + shlex.join([session_command, str(marker)]),
                ],
                stdin=connection,
                stdout=connection,
            ) as process:
                try:
                    process.wait(timeout=remaining)
                    # sshd can exit nonzero on an ordinary client disconnect,
                    # independently of the remote command's exit status.
                    outcome = "closed" if marker.stat().st_size else "failed"
                except subprocess.TimeoutExpired:
                    outcome = "expired"
                    process.kill()
                    process.wait()
                finally:
                    # Drop transport before reporting completion. systemd then kills
                    # all surviving descendants when this main process exits.
                    connection.shutdown(socket.SHUT_RDWR)
    finally:
        print(
            json.dumps({"request_id": rid, "event": outcome}),
            file=sys.stderr,
            flush=True,
        )
        record.write_text(json.dumps({"id": rid, "outcome": outcome}))


def finish(api, runtime, service_result):
    # ExecStopPost runs after systemd has killed the connection's cgroup.
    # A slow/unavailable API must not delay terminating session descendants.
    record = Path(runtime) / "result.json"
    if not record.exists():
        return
    result = json.loads(record.read_text())
    if not REQUEST_ID.fullmatch(result["id"]):
        raise ValueError("Invalid recorded request ID")
    outcome = result["outcome"] if service_result == "success" else "failed"
    if service_result == "timeout":
        outcome = "expired"
    try:
        api(f"/api/gate/{result['id']}/finish", {"outcome": outcome})
    except Exception:
        print(
            "Could not record connection end; grant remains consumed", file=sys.stderr
        )


def main():
    os.umask(0o077)
    origin = os.environ["GATE_ORIGIN"]
    finishing = sys.argv[1:] == ["finish"]
    # systemd removes the per-invocation credential mount before ExecStopPost.
    # This root-only cleanup process can read the original root-owned file.
    token = (
        Path(os.environ["GATE_FINISH_CREDENTIAL" if finishing else "GATE_CREDENTIAL"])
        .read_text()
        .strip()
    )

    def api(path, body):
        return call(origin, token, path, body)

    if finishing:
        finish(
            api,
            os.environ["RUNTIME_DIRECTORY"],
            os.environ.get("SERVICE_RESULT", "failed"),
        )
        return 0
    with socket.socket(fileno=os.dup(0)) as connection:
        try:
            peer = ipaddress.ip_address(connection.getpeername()[0])
            if not any(
                peer in ipaddress.ip_network(network)
                for network in os.environ["GATE_ALLOWED_PEERS"].split(",")
            ):
                raise ValueError("Peer is outside allowed networks")
            serve(
                connection,
                api,
                os.environ["GATE_SSHD"],
                os.environ["GATE_SSHD_CONFIG"],
                os.environ["RUNTIME_DIRECTORY"],
                os.environ["GATE_SESSION_COMMAND"],
            )
        except Exception as error:
            # No credential, response body, or command output in the journal.
            print(f"Connection refused: {type(error).__name__}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
