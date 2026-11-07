import time

from .auth_store import AuthStore
from .auth_store import digest as digest


class Store(AuthStore):
    def __init__(self, path):
        super().__init__(path)
        with self.transaction() as db:
            db.executescript("""
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
                CREATE TABLE IF NOT EXISTS notification_bridge_messages (
                    request_id TEXT PRIMARY KEY, snapshot TEXT NOT NULL,
                    recipient TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS notification_bridge_responses (
                    id TEXT PRIMARY KEY, request_id TEXT NOT NULL);
                PRAGMA user_version = 3;
            """)

    @staticmethod
    def event(db, request_id, actor, event):
        db.execute(
            "INSERT INTO events(request_id,actor,event,time) VALUES(?,?,?,?)",
            (request_id, actor, event, time.time()),
        )

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
