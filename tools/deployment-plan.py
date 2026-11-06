#!/usr/bin/env python3
"""Compare committed NixOS derivations to select deployment hosts."""

import argparse
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

HOSTS = ("nasa", "htpc")
REVISION = re.compile(r"[0-9a-f]{40}")


def revision(value):
    if not REVISION.fullmatch(value):
        raise argparse.ArgumentTypeError("Expected a full Git commit SHA")
    return value


def derivations(repo, commit, directory):
    # An archive excludes uncommitted files and credentials. path: also avoids
    # Git metadata making an otherwise identical configuration look different.
    archive = subprocess.run(
        ["git", "-C", str(repo), "archive", commit], check=True, capture_output=True
    )
    subprocess.run(
        ["tar", "-x", "-C", str(directory)], input=archive.stdout, check=True
    )
    return {
        host: subprocess.check_output(
            [
                "nix",
                "eval",
                "--raw",
                "--no-write-lock-file",
                f"path:{directory}#nixosConfigurations.{host}.config.system.build.toplevel.drvPath",
            ],
            text=True,
        ).strip()
        for host in HOSTS
    }


def select_hosts(before, after, force=None):
    if force == "all":
        return list(HOSTS)
    if force:
        if force not in HOSTS:
            raise ValueError("Unknown deployment host")
        return [force]
    return [host for host in HOSTS if before.get(host) != after[host]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=revision, required=True)
    parser.add_argument("--head", type=revision, required=True)
    parser.add_argument("--force", choices=("all", *HOSTS))
    args = parser.parse_args()
    repo = Path.cwd()
    with tempfile.TemporaryDirectory(prefix="deployment-plan-") as temp:
        base, head = Path(temp) / "base", Path(temp) / "head"
        base.mkdir()
        head.mkdir()
        before = derivations(repo, args.base, base) if args.base != "0" * 40 else {}
        after = derivations(repo, args.head, head)
    hosts = select_hosts(before, after, args.force)
    result = json.dumps(hosts)
    print(result)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"hosts={result}\nhas_changes={str(bool(hosts)).lower()}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write("## Deployment plan\n\n")
            stream.write("| Host | After merge |\n| --- | --- |\n")
            for host in HOSTS:
                action = "Deploy" if host in hosts else "Unchanged"
                stream.write(f"| {host} | {action} |\n")
            stream.write(
                "\nPR checks never connect to a host. Deployment uses the exact merged revision.\n"
            )


if __name__ == "__main__":
    main()
