#!/usr/bin/env python3
"""Explicit, audited NAS SSH fallback using a temporarily forwarded agent."""

import argparse
import glob
import hashlib
import json
import os
import shlex
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = "jmalexan@10.0.1.10"
AUDIT = ROOT / ".local/nasa-access/events.jsonl"


def agent_candidates():
    candidates = [os.environ.get("SSH_AUTH_SOCK", "")]
    candidates.extend(sorted(glob.glob("/tmp/ssh-*/agent.*")))
    candidates.extend(sorted(glob.glob(str(Path.home() / ".ssh/agent/*"))))
    result = []
    for candidate in dict.fromkeys(candidates):
        if not candidate:
            continue
        try:
            info = os.lstat(candidate)
        except OSError:
            continue
        if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid():
            result.append(candidate)
    return result


def choose_agent(explicit=None):
    candidates = [explicit] if explicit else agent_candidates()
    available = []
    for candidate in candidates:
        try:
            info = os.lstat(candidate)
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                continue
            check = subprocess.run(
                ["ssh-add", "-l"],
                env={**os.environ, "SSH_AUTH_SOCK": candidate},
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
            if check.returncode == 0:
                available.append(candidate)
        except (OSError, subprocess.TimeoutExpired):
            continue
    if not available:
        raise ValueError(
            "No usable SSH agent. From your trusted computer, connect with "
            "ssh -A jmalexan@home.nasa.lan and leave that session open."
        )
    if len(available) > 1 and not explicit:
        current = os.environ.get("SSH_AUTH_SOCK")
        if current in available:
            return current
        raise ValueError("Several agents are available; select one with --agent PATH.")
    return available[0]


def ssh_command(command, agent):
    return [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "RequestTTY=no",
        "-o",
        "IdentityFile=none",
        "-o",
        f"IdentityAgent={agent}",
        TARGET,
        shlex.join(command),
    ]


def audit(reason, command, event, **details):
    AUDIT.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(AUDIT.parent, 0o700)
    entry = {
        "time": datetime.now(timezone.utc).isoformat(),
        "target": TARGET,
        "reason": reason,
        "executable": command[0],
        "commandSha256": hashlib.sha256(shlex.join(command).encode()).hexdigest(),
        "event": event,
        **details,
    }
    # Arguments, stdin, and output may contain secrets; never save their contents.
    fd = os.open(AUDIT, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(json.dumps(entry) + "\n")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reason",
        required=True,
        help="Why APIs or copied logs cannot perform this operation",
    )
    parser.add_argument(
        "--agent", help="Select a forwarded agent socket when several are available"
    )
    parser.add_argument(
        "--approved",
        action="store_true",
        help="Request a phone-approved connection as nasa-automation (requires gate deployment)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Review the operation without connecting"
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not args.reason.strip():
        parser.error("a nonempty reason and remote command are required")
    if args.approved and args.agent:
        parser.error("--approved does not use a forwarded agent")
    target = "nasa-automation@10.0.1.10:2222" if args.approved else TARGET
    try:
        if args.dry_run:
            print(
                json.dumps(
                    {
                        "target": target,
                        "reason": args.reason,
                        "command": shlex.join(command),
                    },
                    indent=2,
                )
            )
            return 0
        if args.approved:
            audit(args.reason, command, "approval-requested", target=target)
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "microapps.access",
                    "--credential",
                    os.environ.get(
                        "NASA_APPROVAL_REQUESTER_FILE",
                        str(ROOT / ".local/approvals/requester"),
                    ),
                    "--reason",
                    args.reason,
                    "--",
                    *command,
                ],
                env={**os.environ, "PYTHONPATH": str(ROOT / "apps/microapps/backend")},
            )
        else:
            agent = choose_agent(args.agent)
            audit(args.reason, command, "start")
            result = subprocess.run(ssh_command(command, agent))
        audit(args.reason, command, "end", exitCode=result.returncode, target=target)
        return result.returncode
    except (OSError, ValueError) as error:
        print(f"NAS access: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        audit(args.reason, command, "interrupted", target=target)
        return 130


if __name__ == "__main__":
    sys.exit(main())
