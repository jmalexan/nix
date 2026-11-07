#!/usr/bin/env python3
"""Compare committed NixOS derivations to select deployment hosts."""

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOSTS = ("nasa", "htpc")
REVISION = re.compile(r"[0-9a-f]{40}")
DRV = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/\n]+\.drv")


def revision(value):
    if not REVISION.fullmatch(value):
        raise argparse.ArgumentTypeError("Expected a full Git commit SHA")
    return value


def derivations(repo, commit, directory, validate=False):
    # An archive excludes uncommitted files and credentials. path: also avoids
    # Git metadata making an otherwise identical configuration look different.
    archive = subprocess.run(
        ["git", "-C", str(repo), "archive", commit], check=True, capture_output=True
    )
    subprocess.run(
        ["tar", "-x", "-C", str(directory)], input=archive.stdout, check=True
    )
    if validate:
        # flake check does not use Nix's evaluation cache. Leave host validation
        # to the drvPath evaluation below instead of evaluating each host twice.
        # The wrapper forwards all other outputs, preserving their original self.
        wrapper = directory.parent / "validation"
        wrapper.mkdir()
        (wrapper / "flake.nix").write_text(
            "{ inputs.repo.url = "
            + json.dumps(f"path:{directory}")
            + "; outputs = { repo, ... }: "
            'builtins.removeAttrs repo.outputs [ "nixosConfigurations" ]; }\n'
        )
        subprocess.run(
            [
                "nix",
                "flake",
                "check",
                "--no-build",
                "--all-systems",
                "--no-write-lock-file",
                f"path:{wrapper}",
            ],
            check=True,
        )
    # Evaluate both hosts in one process so they can share imported Nix modules.
    expression = (
        "configs: assert builtins.attrNames configs == "
        + "[ "
        + " ".join(json.dumps(host) for host in sorted(HOSTS))
        + " ]"
        + "; { "
        + " ".join(
            f"{host} = assert configs.{host}.config.system.build.toplevel.type "
            f'== "derivation"; configs.{host}.config.system.build.toplevel.drvPath;'
            for host in HOSTS
        )
        + " }"
    )
    return json.loads(
        subprocess.check_output(
            [
                "nix",
                "eval",
                "--json",
                "--no-write-lock-file",
                "--option",
                "allow-import-from-derivation",
                "false",
                f"path:{directory}#nixosConfigurations",
                "--apply",
                expression,
            ],
            text=True,
        )
    )


def evaluation_context():
    return {
        "schema": 1,
        "planner": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "nix": subprocess.check_output(["nix", "--version"], text=True).strip(),
        "platform": f"{platform.system()}-{platform.machine()}",
    }


def source_tree(repo, commit):
    return subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", f"{commit}^{{tree}}"], text=True
    ).strip()


def cache_key(tree, context):
    signature = hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()
    return f"deployment-derivations-{signature}-{tree}"


def valid_record(record, tree, context):
    if not isinstance(record, dict):
        return False
    values = record.get("derivations")
    return (
        record.get("tree") == tree
        and record.get("context") == context
        and isinstance(values, dict)
        and set(values) == set(HOSTS)
        and all(
            isinstance(value, str) and DRV.fullmatch(value) for value in values.values()
        )
    )


def read_record(path):
    if path:
        try:
            # Only metadata is cached, not Nix store contents or executable files.
            if Path(path).stat().st_size <= 4096:
                return json.loads(Path(path).read_text())
        except (OSError, ValueError):
            pass
    return None


def plan(
    repo,
    base,
    head,
    force=None,
    cache=None,
    verified_head=None,
    fresh=False,
    validate=False,
):
    context = evaluation_context()
    records = [] if fresh else [read_record(cache), read_record(verified_head)]
    resolved = {}
    with tempfile.TemporaryDirectory(prefix="deployment-plan-") as temp:

        def resolve(commit, label, validate=False):
            tree = source_tree(repo, commit)
            if tree in resolved and not validate:
                return resolved[tree]
            for record in [] if validate else records:
                if valid_record(record, tree, context):
                    print(
                        f"{label}: reused derivations for tree {tree}", file=sys.stderr
                    )
                    resolved[tree] = record
                    return record
            directory = Path(temp) / label
            directory.mkdir()
            started = time.monotonic()
            record = {
                "tree": tree,
                "context": context,
                "derivations": (
                    derivations(repo, commit, directory, validate=True)
                    if validate
                    else derivations(repo, commit, directory)
                ),
            }
            if not valid_record(record, tree, context):
                raise ValueError("Nix returned invalid host derivations")
            print(
                f"{label}: evaluated in {time.monotonic() - started:.1f}s",
                file=sys.stderr,
            )
            resolved[tree] = record
            return record

        # Validate before consulting metadata, even when the new tree is cached.
        # Resolving head first also avoids duplicate work for identical trees.
        after = resolve(head, "head", validate=True) if validate else None
        # A forced reconciliation only needs the new configurations validated.
        before = (
            resolve(base, "base")["derivations"]
            if base != "0" * 40 and not force
            else {}
        )
        if after is None:
            after = resolve(head, "head")
    hosts = select_hosts(before, after["derivations"], force)
    if cache:
        Path(cache).parent.mkdir(parents=True, exist_ok=True)
        Path(cache).write_text(json.dumps(after, sort_keys=True) + "\n")
    return hosts


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
    parser.add_argument(
        "--cache", help="Read a previous record and write the new head record"
    )
    parser.add_argument(
        "--verified-head", help="Derivations from verified PR validation"
    )
    parser.add_argument("--cache-keys", action="store_true")
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Validate all flake outputs while evaluating the head hosts once",
    )
    args = parser.parse_args()
    repo = Path.cwd()
    if args.cache_keys:
        context = evaluation_context()
        keys = {
            "base_key": cache_key(source_tree(repo, args.base), context)
            if args.base != "0" * 40
            else "",
            "head_key": cache_key(source_tree(repo, args.head), context),
        }
        print(json.dumps(keys))
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a") as stream:
                for key, value in keys.items():
                    stream.write(f"{key}={value}\n")
        return
    hosts = plan(
        repo,
        args.base,
        args.head,
        args.force,
        args.cache,
        args.verified_head,
        fresh=os.environ.get("CI_FORCE_VALIDATION") == "true",
        validate=args.validate,
    )
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
