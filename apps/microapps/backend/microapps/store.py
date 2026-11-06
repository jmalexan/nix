import contextlib
import hashlib
import os
import secrets
import sqlite3
import time
from pathlib import Path


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Store:
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
                CREATE TABLE IF NOT EXISTS requests (
                    id TEXT PRIMARY KEY, requester TEXT NOT NULL, reason TEXT NOT NULL,
                    operation TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL,
                    expires REAL NOT NULL, result TEXT);
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY, request_id TEXT NOT NULL, actor TEXT NOT NULL,
                    event TEXT NOT NULL, time REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS subscriptions (
                    id TEXT PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS outbox (
                    id INTEGER PRIMARY KEY, request_id TEXT NOT NULL, subscription_id TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                    done INTEGER NOT NULL DEFAULT 0, UNIQUE(request_id, subscription_id));
                CREATE TABLE IF NOT EXISTS connections (
                    request_id TEXT PRIMARY KEY, scope TEXT NOT NULL, deadline REAL);
                CREATE TABLE IF NOT EXISTS notification_bridge_outbox (
                    request_id TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0,
                    next_attempt REAL NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0);
                PRAGMA user_version = 2;
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

    @staticmethod
    def event(db, request_id, actor, event):
        db.execute(
            "INSERT INTO events(request_id,actor,event,time) VALUES(?,?,?,?)",
            (request_id, actor, event, time.time()),
        )

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

    @staticmethod
    def expire(db):
        rows = db.execute(
            """SELECT id FROM requests WHERE
            (state IN ('pending','approved') AND expires <= ?) OR
            (state='claimed' AND id IN
                (SELECT request_id FROM connections WHERE deadline <= ?))""",
            (time.time(), time.time()),
        ).fetchall()
        for row in rows:
            db.execute("UPDATE requests SET state='expired' WHERE id=?", (row["id"],))
            Store.event(db, row["id"], "system", "expired")
