import hashlib
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Store:
    def __init__(self, path):
        Path(path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = path
        with self.transaction() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS grants (
                    code TEXT PRIMARY KEY, recipient TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY, recipient TEXT NOT NULL, name TEXT NOT NULL,
                    token TEXT UNIQUE NOT NULL, apns TEXT NOT NULL, environment TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1);
                CREATE UNIQUE INDEX IF NOT EXISTS active_apns ON devices(apns,environment)
                    WHERE active=1;
                CREATE TABLE IF NOT EXISTS preferences (
                    device TEXT REFERENCES devices(id), service TEXT, enabled INTEGER,
                    PRIMARY KEY(device,service));
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY, service TEXT NOT NULL, recipient TEXT NOT NULL,
                    dedupe TEXT NOT NULL, content TEXT NOT NULL, created REAL, expires REAL,
                    UNIQUE(service,recipient,dedupe));
                CREATE TABLE IF NOT EXISTS deliveries (
                    message TEXT REFERENCES messages(id) ON DELETE CASCADE,
                    device TEXT REFERENCES devices(id), attempts INTEGER DEFAULT 0,
                    next REAL DEFAULT 0, state TEXT DEFAULT 'pending',
                    PRIMARY KEY(message,device));
                CREATE TABLE IF NOT EXISTS responses (
                    message TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                    device TEXT REFERENCES devices(id), action TEXT, text TEXT,
                    created REAL, acknowledged INTEGER DEFAULT 0);
                CREATE TABLE IF NOT EXISTS tickets (
                    token TEXT PRIMARY KEY, device TEXT REFERENCES devices(id), expires REAL);
                CREATE TABLE IF NOT EXISTS sessions (
                    token TEXT PRIMARY KEY, device TEXT REFERENCES devices(id), expires REAL);
            """)
        os.chmod(path, 0o600)

    @contextmanager
    def transaction(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("BEGIN IMMEDIATE")
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def grant(self, recipient, ttl=600):
        code = secrets.token_urlsafe(32)
        with self.transaction() as db:
            db.execute("DELETE FROM grants WHERE expires<=?", (time.time(),))
            db.execute(
                "INSERT INTO grants VALUES(?,?,?)",
                (digest(code), recipient, time.time() + ttl),
            )
        return code

    @staticmethod
    def prune(db):
        now = time.time()
        db.execute("DELETE FROM tickets WHERE expires<=?", (now,))
        db.execute("DELETE FROM sessions WHERE expires<=?", (now,))
        # Bound retained content and reply text to seven days after expiry.
        db.execute("DELETE FROM messages WHERE expires<?", (now - 7 * 86400,))
