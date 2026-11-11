"""One scoped storage-health notification per change, with daily reminders."""

import hashlib
import json
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError

from collector import atomic_json, read_json
from microapps.http import call
from status import load_status


def notify(report, state, origin, token, app_origin, send=call, now=None):
    now = time.time() if now is None else now
    status = load_status(report, now)
    alerts = sorted((a.id, a.message, a.severity) for a in status.alerts)
    signature = hashlib.sha256(json.dumps(alerts).encode()).hexdigest()
    previous = read_json(state, {})
    issue_at = None
    if alerts:
        # Use the report's evidence time so collector lag does not make a
        # completed backup appear older than the failure it actually fixed.
        issue_at = status.report.collected_at if status.report else now
        if any(alert.id == "report-stale" for alert in status.alerts):
            issue_at = now
        if previous.get("alerting"):
            issue_at = max(
                issue_at, previous.get("last_issue_at", previous.get("sent", now))
            )
            if issue_at != previous.get("last_issue_at"):
                previous = {**previous, "last_issue_at": issue_at}
                atomic_json(state, previous)
    else:
        if not previous.get("alerting"):
            return False
        backup = status.report.backup
        if (
            backup.result != "success"
            or backup.last_success is None
            or backup.last_success
            <= previous.get("last_issue_at", previous.get("sent", now))
            or status.report.backup_state in ("active", "activating", "deactivating")
        ):
            return False
    if previous.get("signature") == signature and now - previous.get("sent", 0) < 86400:
        return False
    body = (
        "; ".join(a[1] for a in alerts)
        if alerts
        else "A new backup completed successfully and all monitored issues have cleared."
    )
    try:
        send(
            origin,
            token,
            "/v1/notifications",
            {
                "recipient": "owner",
                "key": f"storage-{signature[:24]}-{int(previous.get('sent', 0) * 1000)}-{int(now // 86400)}",
                "title": "Backups need attention" if alerts else "Backups recovered",
                "body": body[:500],
                "url": app_origin + "/",
                "group": "backups",
                "ttl": 86400,
                "actions": [],
            },
        )
    except HTTPError as error:
        if error.code not in (408, 429, 500, 502, 503, 504):
            raise
        print(
            "Notification service unavailable; retrying on the next timer",
            file=sys.stderr,
        )
        return False
    except (URLError, TimeoutError, ConnectionError):
        print(
            "Notification service unavailable; retrying on the next timer",
            file=sys.stderr,
        )
        return False
    saved = {"signature": signature, "sent": now, "alerting": bool(alerts)}
    if alerts:
        saved["last_issue_at"] = issue_at
    atomic_json(state, saved)
    return True


if __name__ == "__main__":
    notify(
        os.environ["BACKUPS_REPORT"],
        os.environ["BACKUPS_NOTIFY_STATE"],
        os.environ["NOTIFICATIONS_ORIGIN"],
        Path(os.environ["NOTIFICATIONS_TOKEN_FILE"]).read_text().strip(),
        os.environ["BACKUPS_ORIGIN"],
    )
