"""Provision a private local broker credential without printing or rotating it."""

import argparse
import os
import secrets
import stat
from pathlib import Path


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
            "Broker credential directory must be private and owned by the operator"
        )
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as source:
            info = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.geteuid()
                or info.st_mode & 0o077
                or len(source.read().strip()) < 32
            ):
                raise ValueError(
                    "Existing broker credential is invalid; refusing to replace it"
                )
    else:
        with os.fdopen(fd, "w") as target:
            target.write(secrets.token_urlsafe(48) + "\n")
            target.flush()
            os.fsync(target.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", required=True)
    args = parser.parse_args()
    provision(args.path)


if __name__ == "__main__":
    main()
