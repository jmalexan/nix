"""Local-only setup and recovery for owner accounts."""

import argparse
import os
import secrets
import stat
from pathlib import Path

from .accounts import Account
from .auth_store import AuthStore


def provision(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.parent.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
    ):
        raise ValueError(
            "Setup credential directory must be private and owned by the operator"
        )
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd) as source:
            info = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or info.st_mode & 0o077
                or len(source.read().strip()) < 32
            ):
                raise ValueError(
                    "Existing setup credential is invalid; refusing to replace it"
                )
    else:
        with os.fdopen(fd, "w") as target:
            target.write(secrets.token_urlsafe(48) + "\n")
            target.flush()
            os.fsync(target.fileno())


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("provision")
    setup.add_argument("--token-file", required=True)
    reset = sub.add_parser("reset")
    reset.add_argument("--database", required=True)
    reset.add_argument("--confirm-reset", required=True, action="store_true")
    args = parser.parse_args()
    if args.command == "provision":
        provision(args.token_file)
    else:
        Account(AuthStore(args.database), "local-reset-only").reset()


if __name__ == "__main__":
    main()
