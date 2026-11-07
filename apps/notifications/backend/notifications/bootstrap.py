"""Provision the local publisher credential without putting it in the Nix store."""

import argparse
import fcntl
import json
import os
import secrets
import stat
import tempfile
from pathlib import Path

from .models import Service


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
    ):
        raise ValueError(
            "Credential directories must be private and owned by the operator"
        )


def read_private(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise ValueError(
                "Credential files must be private regular files owned by the operator"
            )
        return source.read()


def provision(registry, publisher, origin, recipient="owner"):
    registry, publisher = Path(registry), Path(publisher)
    private_directory(registry.parent)
    private_directory(publisher.parent)
    lock = os.open(
        registry.parent / ".bootstrap.lock",
        os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(lock, "w") as locked:
        fcntl.flock(locked, fcntl.LOCK_EX)
        raw = read_private(registry)
        try:
            entries = json.loads(raw) if raw is not None else {}
            if not isinstance(entries, dict):
                raise ValueError()
            for entry in entries.values():
                Service.model_validate(entry)
        except (ValueError, TypeError):
            raise ValueError("Invalid notification service registry") from None
        saved = read_private(publisher)
        existing = entries.get("approve")
        token = (
            saved.strip()
            if saved is not None
            else existing["token"]
            if existing
            else secrets.token_urlsafe(48)
        )
        try:
            expected = Service(
                token=token, origins=[origin], recipients=[recipient]
            ).model_dump()
        except ValueError:
            raise ValueError("Invalid publisher configuration") from None
        if existing is not None and existing != expected:
            raise ValueError(
                "Existing approval notification credentials or scope do not match; refusing to replace them"
            )
        if any(
            name != "approve" and entry["token"] == token
            for name, entry in entries.items()
        ):
            raise ValueError("Publisher credentials must be distinct across services")
        if saved is None:
            fd = os.open(
                publisher, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            with os.fdopen(fd, "w") as destination:
                destination.write(token + "\n")
                destination.flush()
                os.fsync(destination.fileno())
        if existing is None:
            entries["approve"] = expected
            fd, temporary = tempfile.mkstemp(dir=registry.parent, prefix=".services-")
            try:
                with os.fdopen(fd, "w") as destination:
                    json.dump(entries, destination, sort_keys=True)
                    destination.write("\n")
                    destination.flush()
                    os.fsync(destination.fileno())
                os.replace(temporary, registry)
            finally:
                Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True)
    parser.add_argument("--publisher", required=True)
    parser.add_argument("--origin", required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit("Credential provisioning requires the host operator")
    provision(args.registry, args.publisher, args.origin)
    print("Notification publisher credentials are ready")


if __name__ == "__main__":
    main()
