"""Scoped approval requests on the client; host-only claiming on the broker."""

import json
import math
import re
import sys
import time
from urllib.parse import urlsplit
from urllib.request import Request, build_opener

from .backend import BrokerError
from .client import NoRedirect

ID = re.compile(r"^[A-Za-z0-9_-]{24}$")


def call(origin, token, path, body=None):
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
        raise ValueError("Approval service must be an HTTPS origin")
    request = Request(
        origin + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
    )
    with build_opener(NoRedirect).open(request, timeout=20) as response:
        return json.loads(response.read(65536))


def request_approval(origin, token, scope, reason, send=call, pause=time.sleep):
    result = send(
        origin,
        token,
        "/api/requests",
        {"operation": "git.push", "reason": reason, "push": scope},
    )
    rid = result["id"]
    if not ID.fullmatch(rid):
        raise ValueError("Invalid approval request")
    print(
        "Approve this exact push on your phone: " + origin + "/?request=" + rid,
        file=sys.stderr,
        flush=True,
    )
    for _ in range(300):
        status = send(origin, token, "/api/requester/requests/" + rid)
        if status["state"] == "approved":
            return rid
        if status["state"] != "pending":
            raise ValueError("Push was denied or expired")
        pause(2)
    raise ValueError("Push approval timed out")


class Gate:
    def __init__(self, origin, token, send=call):
        if len(token) < 32:
            raise ValueError("Approval claiming credential is required")
        self.origin, self.token, self.send = origin, token, send

    def claim(self, rid, scope):
        if not ID.fullmatch(rid):
            raise BrokerError(403, "A push approval is required")
        try:
            receipt = self.send(
                self.origin, self.token, "/api/git-broker/" + rid + "/claim", scope
            )
            deadline = float(receipt["push_deadline"])
            if (
                receipt["id"] != rid
                or receipt["operation"] != "git.push"
                or receipt["state"] != "claimed"
                or receipt["push"] != scope
                or not math.isfinite(deadline)
                or not time.time() < deadline <= time.time() + 181
            ):
                raise ValueError()
            return deadline
        except (OSError, ValueError, KeyError, TypeError):
            raise BrokerError(
                403, "No available approval for this exact push"
            ) from None

    def finish(self, rid, outcome):
        try:
            self.send(
                self.origin,
                self.token,
                "/api/git-broker/" + rid + "/finish",
                {"outcome": outcome},
            )
        except (OSError, ValueError):
            # A reporting failure never retries a remote write. Claimed requests
            # expire if final status cannot be delivered.
            pass
