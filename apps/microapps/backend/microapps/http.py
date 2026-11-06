"""Small credential-bearing API client; never follow redirects with credentials."""

import json
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def call(origin, token, path, body=None):
    request = urllib.request.Request(
        origin + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
        return json.load(response)
