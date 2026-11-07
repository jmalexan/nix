"""Request one phone-approved NASA connection without a forwarded SSH agent."""

import argparse
import json
import os
import re
import select
import shlex
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from .http import call

ORIGIN = "https://approve.nasa.jmalexan.com"
HOST = "10.0.1.10"
PORT = 2222
REQUEST_ID = re.compile(r"[A-Za-z0-9_-]{24}")


def proxy(host, port, rid):
    if not REQUEST_ID.fullmatch(rid):
        raise ValueError("Invalid request ID")
    with socket.create_connection((host, port), timeout=10) as connection:
        connection.sendall((rid + "\n").encode())
        connection.settimeout(None)
        inputs = [sys.stdin.buffer, connection]
        while connection in inputs:
            ready, _, _ = select.select(inputs, [], [])
            for source in ready:
                if source is connection:
                    data = connection.recv(65536)
                    if not data:
                        return
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                else:
                    data = os.read(sys.stdin.fileno(), 65536)
                    if data:
                        connection.sendall(data)
                    else:
                        inputs.remove(sys.stdin.buffer)
                        connection.shutdown(socket.SHUT_WR)


def ssh_command(key, rid, command):
    proxy_command = shlex.join(
        [
            sys.executable,
            "-m",
            "microapps.access",
            "--proxy",
            HOST,
            str(PORT),
            rid,
        ]
    )
    return [
        "ssh",
        "-F",
        "/dev/null",
        "-T",
        "-p",
        str(PORT),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"HostKeyAlias={HOST}",
        "-o",
        "UpdateHostKeys=no",
        "-o",
        "IdentityAgent=none",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
        "-o",
        "ControlPersist=no",
        "-o",
        "ConnectTimeout=15",
        "-o",
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=2",
        "-o",
        f"ProxyCommand={proxy_command}",
        "-i",
        str(key),
        f"nasa-automation@{HOST}",
        shlex.join(command),
    ]


def main():
    os.umask(0o077)
    if sys.argv[1:2] == ["--proxy"]:
        proxy(sys.argv[2], int(sys.argv[3]), sys.argv[4])
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reason", required=True)
    parser.add_argument(
        "--credential",
        type=Path,
        default=Path(
            os.environ.get("NASA_APPROVAL_REQUESTER_FILE", ".local/approvals/requester")
        ),
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not args.reason.strip() or len(args.reason) > 1000:
        parser.error(
            "a command and nonempty reason of at most 1000 characters are required"
        )
    if args.dry_run:
        print(
            json.dumps(
                {
                    "target": HOST,
                    "account": "nasa-automation",
                    "max_seconds": 900,
                    "reason": args.reason,
                    "command": shlex.join(command),
                }
            )
        )
        return 0
    token = args.credential.read_text().strip()
    with tempfile.TemporaryDirectory(prefix="nasa-connection-") as directory:
        key = Path(directory) / "identity"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(key)],
            check=True,
        )
        result = call(
            ORIGIN,
            token,
            "/api/requests",
            {
                "operation": "ssh.connect",
                "reason": args.reason,
                "connection": {
                    "public_key": key.with_suffix(".pub").read_text().strip()
                },
            },
        )
        rid = result["id"]
        print(
            f"Approve on your phone: https://approve/?request={rid}",
            file=sys.stderr,
            flush=True,
        )
        stop = time.monotonic() + 600
        while result["state"] == "pending" and time.monotonic() < stop:
            time.sleep(2)
            result = call(ORIGIN, token, f"/api/requester/requests/{rid}")
        if result["state"] != "approved":
            print(f"Connection not approved ({result['state']})", file=sys.stderr)
            return 1
        # No retries: even a failed SSH handshake consumes this approval.
        return subprocess.run(ssh_command(key, rid, command)).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"NASA connection failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
