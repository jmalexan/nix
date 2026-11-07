"""Host-only claiming of exact, one-use Git push approvals."""

import math
import time

from .backend import BrokerError
from .request import ID, call


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
