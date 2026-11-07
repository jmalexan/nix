"""Persistent, per-app passkey credentials, challenges, and sessions."""

import contextlib
import hashlib
import os
import secrets
import sqlite3
import time
from pathlib import Path


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class AuthStore:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = path
        with self.transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS credentials (
                    id TEXT PRIMARY KEY, public_key TEXT NOT NULL, counter INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS challenges (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, value TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY, csrf TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS passwords (
                    owner INTEGER PRIMARY KEY CHECK(owner = 1),
                    salt BLOB NOT NULL, hash BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS password_attempts (created REAL NOT NULL);
            """)
        os.chmod(path, 0o600)

    @contextlib.contextmanager
    def transaction(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def challenge(self, kind, value):
        token = secrets.token_urlsafe(32)
        with self.transaction() as db:
            db.execute("DELETE FROM challenges WHERE expires < ?", (time.time(),))
            db.execute(
                "INSERT INTO challenges VALUES(?,?,?,?)",
                (digest(token), kind, value, time.time() + 300),
            )
        return token

    def consume_challenge(self, token, kind):
        with self.transaction() as db:
            row = db.execute(
                "SELECT * FROM challenges WHERE id=? AND kind=?", (digest(token), kind)
            ).fetchone()
            db.execute("DELETE FROM challenges WHERE id=?", (digest(token),))
        if not row or row["expires"] < time.time():
            raise ValueError("Challenge expired; try again")
        return row["value"]
