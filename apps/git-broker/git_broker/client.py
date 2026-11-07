"""Clone/fetch/push client. The only credential here authenticates to the broker."""

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def local_git(*arguments, cwd=None, check=True):
    return subprocess.run(
        [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "credential.helper=",
            *arguments,
        ],
        cwd=cwd,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


class Client:
    def __init__(self, origin, token):
        url = urlsplit(origin)
        if (
            url.scheme != "https"
            or not url.hostname
            or url.path
            or url.query
            or url.fragment
            or url.username
        ):
            raise ValueError("Broker must be an HTTPS origin")
        self.origin, self.token = origin, token

    def call(self, path, body=None, output=None):
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            headers["Content-Type"] = "application/x-git-bundle"
            headers["Content-Length"] = str(Path(body).stat().st_size)
        with (
            Path(body).open("rb") if body is not None else open(os.devnull, "rb")
        ) as source:
            request = Request(
                self.origin + path,
                data=source if body is not None else None,
                headers=headers,
            )
            with build_opener(NoRedirect).open(request, timeout=240) as response:
                if output:
                    with Path(output).open("wb") as target:
                        while chunk := response.read(1024 * 1024):
                            target.write(chunk)
                    return None
                return json.load(response)

    def snapshot(self, alias, path):
        # Quote aliases as a single URL segment; the server still enforces its allowlist.
        from urllib.parse import quote

        return self.call(
            "/v1/repositories/" + quote(alias, safe="") + "/snapshot", output=path
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("repositories")
    clone = sub.add_parser("clone")
    clone.add_argument("alias")
    clone.add_argument("destination")
    sub.add_parser("fetch")
    push = sub.add_parser("push")
    push.add_argument("branch", nargs="?")
    push.add_argument("--reason", required=True, help="Why this exact push is needed")
    args = parser.parse_args()
    try:
        client = Client(
            os.environ.get("GIT_BROKER_ORIGIN", "https://git-broker.nasa.jmalexan.com"),
            Path(
                os.environ.get(
                    "GIT_BROKER_TOKEN_FILE",
                    str(Path.home() / ".local/share/git-broker/token"),
                )
            )
            .read_text()
            .strip(),
        )
        if args.command == "repositories":
            print(json.dumps(client.call("/v1/repositories"), indent=2))
            return
        with tempfile.TemporaryDirectory(prefix="git-broker-") as temporary:
            bundle = Path(temporary) / "transfer.bundle"
            if args.command == "clone":
                client.snapshot(args.alias, bundle)
                local_git("clone", "--template=", "--", str(bundle), args.destination)
                cwd = Path(args.destination)
                local_git("config", "broker.alias", args.alias, cwd=cwd)
                local_git(
                    "remote", "set-url", "origin", "broker://" + args.alias, cwd=cwd
                )
            else:
                alias = local_git("config", "--get", "broker.alias").stdout.strip()
                if args.command == "fetch":
                    client.snapshot(alias, bundle)
                    local_git(
                        "fetch",
                        "--prune",
                        "--no-tags",
                        str(bundle),
                        "+refs/heads/*:refs/remotes/origin/*",
                        "refs/tags/*:refs/tags/*",
                    )
                else:
                    branch = (
                        args.branch
                        or local_git("symbolic-ref", "--short", "HEAD").stdout.strip()
                    )
                    local_git("check-ref-format", "refs/heads/" + branch)
                    commit = local_git(
                        "rev-parse", "--verify", "refs/heads/" + branch
                    ).stdout.strip()
                    previous = local_git(
                        "rev-parse",
                        "--verify",
                        "refs/remotes/origin/" + branch,
                        check=False,
                    )
                    expected = (
                        previous.stdout.strip()
                        if previous.returncode == 0
                        else "0" * 40
                    )
                    local_git("bundle", "create", str(bundle), "refs/heads/" + branch)
                    from urllib.parse import quote

                    from .approval import request_approval

                    policy = client.call("/v1/repositories")[alias]
                    if not branch.startswith(tuple(policy["write_prefixes"])):
                        raise ValueError("Branch is outside allowed namespaces")
                    scope = {
                        "repository": policy["github"],
                        "branch": branch,
                        "commit": commit,
                        "expected": expected,
                    }
                    approval = request_approval(
                        os.environ.get(
                            "GIT_BROKER_APPROVAL_ORIGIN",
                            "https://approve.nasa.jmalexan.com",
                        ),
                        Path(
                            os.environ.get(
                                "NASA_APPROVAL_REQUESTER_FILE",
                                str(Path.home() / ".local/share/nasa-access/requester"),
                            )
                        )
                        .read_text()
                        .strip(),
                        scope,
                        args.reason,
                    )
                    query = urlencode(
                        {
                            "branch": branch,
                            "commit": commit,
                            "expected": expected,
                            "approval": approval,
                        }
                    )
                    result = client.call(
                        "/v1/repositories/" + quote(alias, safe="") + "/push?" + query,
                        body=bundle,
                    )
                    local_git(
                        "update-ref", "refs/remotes/origin/" + branch, result["commit"]
                    )
                    print("Pushed " + branch)
    except (OSError, ValueError, subprocess.CalledProcessError, HTTPError):
        # Never reflect provider output or credential-bearing requests into logs.
        parser.exit(
            1,
            "Broker operation failed. Check repository policy, connectivity, and whether a fetch is needed.\n",
        )


if __name__ == "__main__":
    main()
