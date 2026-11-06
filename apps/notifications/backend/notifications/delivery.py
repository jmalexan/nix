"""Serialized APNs outbox worker. Provider acceptance is not device delivery."""

import json
import os
import time
from pathlib import Path

import httpx
import jwt

from .store import Store, digest


def payload(row):
    content = json.loads(row["content"])
    return {
        "aps": {
            "alert": {
                "title": content["title"],
                "subtitle": row["service"],
                "body": content["body"],
            },
            "sound": "default",
            "mutable-content": 1,
            "thread-id": digest(row["service"] + ":" + content["group"]),
        },
        "bridge": {"version": 1, "id": row["message"], "url": content["url"]},
    }


class APNs:
    def __init__(self, key, key_id, team_id, topic):
        self.key, self.key_id, self.team_id, self.topic = key, key_id, team_id, topic
        self.token = None
        self.issued = 0
        self.client = httpx.Client(http2=True, timeout=10, follow_redirects=False)

    def __call__(self, row, content):
        now = time.time()
        if self.token is None or now - self.issued > 3000:
            self.token = jwt.encode(
                {"iss": self.team_id, "iat": int(now)},
                self.key,
                algorithm="ES256",
                headers={"kid": self.key_id},
            )
            self.issued = now
        host = (
            "api.sandbox.push.apple.com"
            if row["environment"] == "sandbox"
            else "api.push.apple.com"
        )
        response = self.client.post(
            f"https://{host}/3/device/{row['apns']}",
            content=json.dumps(content, ensure_ascii=False).encode(),
            headers={
                "authorization": "bearer " + self.token,
                "apns-topic": self.topic,
                "apns-push-type": "alert",
                "apns-priority": "10",
                "apns-expiration": str(int(row["expires"])),
                "apns-collapse-id": digest(row["message"]),
            },
        )
        return response.status_code, response.json() if response.content else {}


def deliver(store, send, now=time.time):
    # The systemd oneshot serializes workers. The lease also recovers crashes.
    for _ in range(50):
        with store.transaction() as db:
            Store.prune(db)
            row = db.execute(
                """SELECT o.*,m.content,m.expires,m.service,d.apns,d.environment
                   FROM deliveries o JOIN messages m ON m.id=o.message
                   JOIN devices d ON d.id=o.device
                   LEFT JOIN preferences p ON p.device=d.id AND p.service=m.service
                   WHERE o.state IN ('pending','sending') AND o.next<=?
                   AND d.active=1 AND COALESCE(p.enabled,1)=1
                   ORDER BY o.next LIMIT 1""",
                (now(),),
            ).fetchone()
            if row is None:
                break
            if row["expires"] <= now():
                db.execute(
                    "UPDATE deliveries SET state='expired' WHERE message=? AND device=?",
                    (row["message"], row["device"]),
                )
                continue
            db.execute(
                "UPDATE deliveries SET state='sending',next=?,attempts=attempts+1 WHERE message=? AND device=?",
                (now() + 60, row["message"], row["device"]),
            )
        try:
            status, result = send(row, payload(row))
        except (httpx.HTTPError, OSError, ValueError):
            status, result = 503, {}
        state = "accepted" if status == 200 else "pending"
        invalid = status == 410 or (
            status == 400 and result.get("reason") == "BadDeviceToken"
        )
        if status != 200 and (status not in (429, 500, 503) or row["attempts"] >= 7):
            state = "failed"
        with store.transaction() as db:
            db.execute(
                "UPDATE deliveries SET state=?,next=? WHERE message=? AND device=?",
                (
                    state,
                    now() + min(300, 2 ** (row["attempts"] + 2)),
                    row["message"],
                    row["device"],
                ),
            )
            if invalid:
                db.execute(
                    "UPDATE devices SET active=0 WHERE id=? AND apns=? AND environment=?",
                    (row["device"], row["apns"], row["environment"]),
                )


def main():
    send = APNs(
        Path(os.environ["NOTIFICATIONS_APNS_KEY_FILE"]).read_text(),
        os.environ["NOTIFICATIONS_APNS_KEY_ID"],
        os.environ["NOTIFICATIONS_APNS_TEAM_ID"],
        os.environ["NOTIFICATIONS_APNS_TOPIC"],
    )
    try:
        store = Store(os.environ["NOTIFICATIONS_DATABASE"])
        while True:
            # Reuse HTTP/2 connections and provider JWTs across delivery batches.
            # Recreating the provider every timer tick can trigger APNs token throttling.
            deliver(store, send)
            time.sleep(10)
    finally:
        send.client.close()


if __name__ == "__main__":
    main()
