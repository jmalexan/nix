"""Optional generic notification adapter; decisions stay in the approval web app."""

import os
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit

from .http import call
from .store import Store


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
            try:
                send(
                    origin,
                    token,
                    "/v1/notifications",
                    {
                        "recipient": recipient,
                        "key": row["request_id"],
                        "title": "Approval requested",
                        "body": "Open Approve to review a pending request.",
                        "url": app_origin + "/?request=" + row["request_id"],
                        "group": "approvals",
                        "ttl": 600,
                        "expires_at": row["expires"],
                        "actions": [
                            {
                                "id": "review",
                                "title": "Review",
                                "kind": "open",
                                "url": app_origin + "/?request=" + row["request_id"],
                            }
                        ],
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
    deliver_bridge(
        Store(os.environ["MICROAPP_DATABASE"]),
        os.environ["NOTIFICATIONS_ORIGIN"],
        Path(os.environ["NOTIFICATIONS_TOKEN_FILE"]).read_text().strip(),
        os.environ["NOTIFICATIONS_RECIPIENT"],
        os.environ["MICROAPP_ORIGIN"],
    )
