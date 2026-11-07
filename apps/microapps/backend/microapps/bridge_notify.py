"""Publish scoped native choices and consume authenticated, single-use responses."""

import json
import os
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit

from .connection import request_view
from .http import call
from .store import Store


def snapshot(db, row):
    view = request_view(db, row)
    return json.dumps(
        {
            k: view[k]
            for k in ("id", "requester", "reason", "operation", "expires", "connection")
        },
        sort_keys=True,
    )


def native_body(view):
    body = view["reason"] + "\nOperation: " + view["operation"]
    scope = view["connection"]
    if scope:
        body += (
            f"\n{scope['account']}@{scope['target']}; "
            f"maximum {scope['max_seconds']} seconds; no sudo."
            f"\nTemporary key: {scope['public_key']}"
        )
    return body


def receive_bridge(store, origin, token, recipient, send=call):
    events = send(origin, token, "/v1/responses")
    for event in events:
        with store.transaction() as db:
            Store.expire(db)
            known = db.execute(
                "SELECT 1 FROM notification_bridge_responses WHERE id=?", (event["id"],)
            ).fetchone()
            binding = db.execute(
                "SELECT * FROM notification_bridge_messages WHERE request_id=?",
                (event["key"],),
            ).fetchone()
            row = db.execute(
                "SELECT * FROM requests WHERE id=?", (event["key"],)
            ).fetchone()
            now = time.time()
            if (
                not known
                and binding
                and row
                and row["state"] == "pending"
                and event["recipient"] == recipient == binding["recipient"]
                and event["action"] in ("approve", "reject")
                and event["text"] is None
                and row["operation"] in ("demo.verify", "ssh.connect")
                and now < event["expires"] <= binding["expires"]
                and row["created"] <= event["created"] <= now
                and binding["snapshot"] == snapshot(db, row)
            ):
                state = "approved" if event["action"] == "approve" else "denied"
                db.execute(
                    "UPDATE requests SET state=?,expires=min(expires,?) WHERE id=? AND state='pending'",
                    (state, now + 120, row["id"]),
                )
                Store.event(db, row["id"], "owner-native", state)
            # Record both applied and rejected events before acknowledging. A failed
            # ack retries safely without reapplying a decision or extending expiry.
            db.execute(
                "INSERT OR IGNORE INTO notification_bridge_responses VALUES(?,?)",
                (event["id"], event["key"]),
            )
        send(origin, token, "/v1/responses/" + event["id"] + "/ack", {})


def deliver_bridge(store, origin, token, recipient, app_origin, send=call):
    url = urlsplit(origin)
    if (
        url.scheme != "https"
        or not url.hostname
        or url.username
        or url.password
        or url.path
        or url.query
        or url.fragment
    ):
        raise ValueError("Notification bridge must be an HTTPS origin")
    with store.transaction() as db:
        Store.expire(db)
        rows = db.execute(
            """SELECT o.*,r.state,r.expires FROM notification_bridge_outbox o
               JOIN requests r ON r.id=o.request_id
               WHERE o.done=0 AND o.next_attempt<=? LIMIT 50""",
            (time.time(),),
        ).fetchall()
    for row in rows:
        done = row["state"] != "pending" or row["expires"] <= time.time()
        if not done:
            with store.transaction() as db:
                current = db.execute(
                    "SELECT * FROM requests WHERE id=?", (row["request_id"],)
                ).fetchone()
                view = request_view(db, current)
                body = native_body(view)
                choices = len(body) <= 500 and view["operation"] in (
                    "demo.verify",
                    "ssh.connect",
                )
                if choices:
                    db.execute(
                        "INSERT OR IGNORE INTO notification_bridge_messages VALUES(?,?,?,?)",
                        (
                            row["request_id"],
                            snapshot(db, current),
                            recipient,
                            row["expires"],
                        ),
                    )
            try:
                send(
                    origin,
                    token,
                    "/v1/notifications",
                    {
                        "recipient": recipient,
                        "key": row["request_id"],
                        "title": "Approval requested",
                        "body": body
                        if choices
                        else "Open Approve to review the full request details.",
                        "url": app_origin + "/?request=" + row["request_id"],
                        "group": "approvals",
                        "ttl": 600,
                        "expires_at": row["expires"],
                        "actions": (
                            [
                                {
                                    "id": "approve",
                                    "title": "Approve",
                                    "kind": "respond",
                                },
                                {"id": "reject", "title": "Reject", "kind": "respond"},
                            ]
                            if choices
                            else []
                        ),
                    },
                )
                done = True
            except HTTPError as error:
                done = error.code not in (429, 500, 502, 503, 504)
            except (OSError, URLError, ValueError):
                pass
        done = done or row["attempts"] >= 7
        with store.transaction() as db:
            db.execute(
                "UPDATE notification_bridge_outbox SET done=?,attempts=attempts+1,next_attempt=? WHERE request_id=?",
                (
                    done,
                    time.time() + min(300, 2 ** (row["attempts"] + 2)),
                    row["request_id"],
                ),
            )


if __name__ == "__main__":
    arguments = (
        Store(os.environ["MICROAPP_DATABASE"]),
        os.environ["NOTIFICATIONS_ORIGIN"],
        Path(os.environ["NOTIFICATIONS_TOKEN_FILE"]).read_text().strip(),
        os.environ["NOTIFICATIONS_RECIPIENT"],
        os.environ["MICROAPP_ORIGIN"],
    )
    deliver_bridge(*arguments)
    receive_bridge(*arguments[:4])
