"""Request phone approval for an exact branch push."""

import json
import re
import sys
import time
from urllib.parse import urlsplit
from urllib.request import Request, build_opener

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
