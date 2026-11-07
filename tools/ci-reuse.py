#!/usr/bin/env python3
"""Reuse successful same-tree PR validation, never its deployment plan or code."""

import argparse
import io
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

SHA = re.compile(r"[0-9a-f]{40}")


def git(value):
    return subprocess.check_output(["git", "rev-parse", value], text=True).strip()


class GitHub:
    def __init__(self):
        self.root = os.environ.get("GITHUB_API_URL", "https://api.github.com")
        self.repo = os.environ["GITHUB_REPOSITORY"]

    def get(self, path, binary=False):
        request = urllib.request.Request(
            f"{self.root}/repos/{self.repo}/{path}",
            headers={
                "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )

        # Follow artifact redirects explicitly without forwarding the API token.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        opener = urllib.request.build_opener(NoRedirect)
        try:
            response = opener.open(request, timeout=15)
        except urllib.error.HTTPError as error:
            if not binary or error.code != 302:
                raise
            target = error.headers["Location"]
            if not target.startswith("https://"):
                raise ValueError("Artifact redirect must use HTTPS") from error
            response = urllib.request.urlopen(target, timeout=15)
        with response as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("Unexpectedly large GitHub response")
        return data if binary else json.loads(data)


def record(path):
    commit = git("HEAD")
    if commit != os.environ["GITHUB_SHA"]:
        raise ValueError("Checkout differs from the workflow revision")
    Path(path).write_text(
        json.dumps(
            {
                "commit": commit,
                "tree": git("HEAD^{tree}"),
                "run_id": int(os.environ["GITHUB_RUN_ID"]),
                "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
            }
        )
        + "\n"
    )


def manifest(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if (
            len(entries) != 1
            or entries[0].filename != "validation.json"
            or entries[0].file_size > 4096
        ):
            raise ValueError("Unexpected validation artifact contents")
        return json.loads(archive.read(entries[0]))


def find_run(api, workflow, commit, tree):
    # Restrict reuse to PR heads associated with this merged main revision.
    pulls = api.get(f"commits/{commit}/pulls?per_page=100")
    heads = {
        pr["head"]["sha"]
        for pr in pulls
        if pr.get("merged_at")
        and pr["base"]["ref"] == "main"
        and pr["base"]["repo"]["full_name"] == api.repo
        and (pr["head"].get("repo") or {}).get("full_name") == api.repo
    }
    if not heads:
        return None
    runs = api.get(
        f"actions/workflows/{workflow}/runs?event=pull_request&status=success&per_page=50"
    )["workflow_runs"]
    for run in runs:
        if (
            run["head_sha"] not in heads
            or run["event"] != "pull_request"
            or run["status"] != "completed"
            or run["conclusion"] != "success"
            or run["path"] != f".github/workflows/{workflow}"
            or run["head_repository"]["full_name"] != api.repo
        ):
            continue
        # This also binds the workflow and helper code to the approved main tree.
        head = api.get(f"git/commits/{run['head_sha']}")
        if head["tree"]["sha"] != tree:
            continue
        artifacts = api.get(f"actions/runs/{run['id']}/artifacts?per_page=100")[
            "artifacts"
        ]
        matches = [
            artifact
            for artifact in artifacts
            if artifact["name"] == f"validated-tree-{run['run_attempt']}"
            and not artifact["expired"]
        ]
        if len(matches) != 1:
            continue
        proof = manifest(
            api.get(f"actions/artifacts/{matches[0]['id']}/zip", binary=True)
        )
        if (
            proof.get("run_id") != run["id"]
            or proof.get("attempt") != run["run_attempt"]
            or proof.get("tree") != tree
            or not SHA.fullmatch(proof.get("commit", ""))
        ):
            continue
        tested = api.get(f"git/commits/{proof['commit']}")
        parents = [parent["sha"] for parent in tested["parents"]]
        if (
            tested["tree"]["sha"] == tree
            and len(parents) == 2
            and parents[1] == run["head_sha"]
        ):
            return run["html_url"]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record")
    parser.add_argument("--workflow", choices=("check.yml", "notification-ios.yml"))
    args = parser.parse_args()
    if args.record:
        record(args.record)
        return
    if not args.workflow:
        parser.error("--workflow is required for lookup")
    url = None
    if (
        os.environ.get("GITHUB_REF") == "refs/heads/main"
        and os.environ.get("GITHUB_EVENT_NAME") in ("push", "workflow_dispatch")
        and os.environ.get("CI_FORCE_VALIDATION") != "true"
    ):
        try:
            commit = git("HEAD")
            if commit != os.environ["GITHUB_SHA"]:
                raise ValueError("Checkout differs from the workflow revision")
            url = find_run(GitHub(), args.workflow, commit, git("HEAD^{tree}"))
        except Exception as error:
            # An optimization must never turn an unavailable proof into a pass.
            print(
                f"Reuse unavailable ({type(error).__name__}); running full validation."
            )
    message = (
        f"Reusing successful PR validation: {url}"
        if url
        else "No verified PR result; running full validation."
    )
    print(message)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"reused={str(bool(url)).lower()}\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(message + "\n\n")


if __name__ == "__main__":
    main()
