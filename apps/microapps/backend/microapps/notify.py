"""Run as a serialized systemd oneshot; retries are persisted between runs."""

import json
import os
import time

from pywebpush import WebPushException, webpush

from .store import Store


def deliver(store, private_key, subject, send=webpush):
    with store.transaction() as db:
        Store.expire(db)
        rows = db.execute(
            """SELECT o.*, s.body, r.state, r.expires FROM outbox o
            JOIN subscriptions s ON s.id=o.subscription_id
            JOIN requests r ON r.id=o.request_id
            WHERE o.done=0 AND o.next_attempt<=? ORDER BY o.id LIMIT 50""",
            (time.time(),),
        ).fetchall()
    for row in rows:
        permanent = row["state"] != "pending" or row["expires"] <= time.time()
        remove = False
        if not permanent:
            try:
                send(
                    subscription_info=json.loads(row["body"]),
                    data=json.dumps({"request_id": row["request_id"]}),
                    vapid_private_key=private_key,
                    vapid_claims={"sub": subject},
                    ttl=max(0, int(row["expires"] - time.time())),
                    timeout=10,
                )
                permanent = True
            except WebPushException as error:
                status = error.response.status_code if error.response is not None else 0
                remove = status in (404, 410)
                permanent = remove or row["attempts"] >= 7
            except (OSError, ValueError):
                permanent = row["attempts"] >= 7
        with store.transaction() as db:
            db.execute(
                "UPDATE outbox SET done=?,attempts=attempts+1,next_attempt=? WHERE id=?",
                (
                    permanent,
                    time.time() + min(300, 2 ** (row["attempts"] + 2)),
                    row["id"],
                ),
            )
            if remove:
                db.execute(
                    "DELETE FROM subscriptions WHERE id=?", (row["subscription_id"],)
                )
                db.execute(
                    "UPDATE outbox SET done=1 WHERE subscription_id=?",
                    (row["subscription_id"],),
                )


if __name__ == "__main__":
    deliver(
        Store(os.environ["MICROAPP_DATABASE"]),
        os.environ["MICROAPP_VAPID_PRIVATE_FILE"],
        os.environ["MICROAPP_PUSH_SUBJECT"],
    )
