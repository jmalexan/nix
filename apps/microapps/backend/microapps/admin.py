"""Local operator-only maintenance; no HTTP recovery endpoint."""

import argparse
import os
import sqlite3
from pathlib import Path

from .store import Store


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["backup", "reset-auth"])
    parser.add_argument("--database", required=True)
    parser.add_argument("--output")
    parser.add_argument("--confirm-reset", action="store_true")
    args = parser.parse_args()
    if args.command == "backup":
        if not args.output:
            parser.error("--output is required")
        destination = Path(args.output)
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        with (
            sqlite3.connect(args.database) as source,
            sqlite3.connect(destination) as target,
        ):
            source.backup(target)
    else:
        if not args.confirm_reset:
            parser.error(
                "--confirm-reset required; stop the app and gate socket and rotate the enrollment credential first"
            )
        with Store(args.database).transaction() as db:
            for table in [
                "credentials",
                "sessions",
                "challenges",
                "subscriptions",
                "passwords",
                "password_attempts",
            ]:
                db.execute(f"DELETE FROM {table}")
            db.execute(
                "UPDATE requests SET state='expired' WHERE state IN ('pending','approved','claimed')"
            )
            db.execute("UPDATE outbox SET done=1")
            Store.event(db, "", "local-operator", "reset-auth")


if __name__ == "__main__":
    main()
