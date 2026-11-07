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
VM_CHECKS = ("approval-ssh-gate", "agent-network", "agent-guest", "robots-backup")
CHECK_NAME = re.compile(r"[a-zA-Z0-9_-]+")
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
    # Evaluate both hosts in one process so they can share imported Nix modules.
    expression = (
        "flake: let configs = flake.nixosConfigurations; in "
        + "assert builtins.attrNames configs == "
        + "[ "
        + " ".join(json.dumps(host) for host in sorted(HOSTS))
        + " ]"
        + "; { hosts = { "
        + " ".join(
            f"{host} = assert configs.{host}.config.system.build.toplevel.type "
            f'== "derivation"; configs.{host}.config.system.build.toplevel.drvPath;'
            for host in HOSTS
        )
        + " }; checks = builtins.mapAttrs (_: drv: "
        + 'assert drv.type == "derivation"; drv.drvPath) flake.checks.x86_64-linux; }'
    )
    # A temporary wrapper exposes metadata under lib without altering the source
    # flake's self. Both validation and metadata evaluation use this same wrapper.
    wrapper = directory.parent / f"{directory.name}-validation"
    wrapper.mkdir()
    (wrapper / "flake.nix").write_text(
        "{ inputs.repo.url = "
        + json.dumps(f"path:{directory}")
        + "; outputs = { repo, ... }: "
        + '(builtins.removeAttrs repo.outputs [ "nixosConfigurations" ]) // { '
        + "lib = (repo.lib or {}) // { ciDerivations = ("
        + expression
        + ") repo; }; }; }\n"
    )
    if validate:
        # flake check does not cache evaluations. The host derivation checks are
        # performed by ciDerivations; all other outputs retain native validation.
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
                f"path:{wrapper}#lib.ciDerivations",
            ],
            text=True,
        )
    )


def evaluation_context():
    return {
        "schema": 2,
        "planner": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "nix": subprocess.check_output(["nix", "--version"], text=True).strip(),
        "platform": f"{platform.system()}-{platform.machine()}",
        "runner_image": f"{os.environ.get('ImageOS', 'local')}:{os.environ.get('ImageVersion', 'local')}",
    }


def source_tree(repo, commit):
    return subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", f"{commit}^{{tree}}"], text=True
    ).strip()


def cache_key(tree, context):
    signature = hashlib.sha256(json.dumps(context, sort_keys=True).encode()).hexdigest()
    return f"deployment-derivations-{signature}-{tree}"


def valid_record(record, tree, context, require_vm_checks=True):
    if not isinstance(record, dict):
        return False
    values = record.get("derivations")
    checks = record.get("checks")
    return (
        record.get("tree") == tree
        and record.get("context") == context
        and isinstance(values, dict)
        and set(values) == set(HOSTS)
        and isinstance(checks, dict)
        and (not require_vm_checks or set(VM_CHECKS) <= set(checks))
        and all(isinstance(name, str) and CHECK_NAME.fullmatch(name) for name in checks)
        and all(
            isinstance(value, str) and DRV.fullmatch(value) for value in checks.values()
        )
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
    vm_selection=None,
    select_vm=False,
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
            evaluated = (
                derivations(repo, commit, directory, validate=True)
                if validate
                else derivations(repo, commit, directory)
            )
            record = {
                "tree": tree,
                "context": context,
                "derivations": evaluated["hosts"],
                "checks": evaluated["checks"],
            }
            # A historical base may predate a newly introduced VM check.
            # Head and reusable records must still include every required check.
            if not valid_record(
                record, tree, context, require_vm_checks=label == "head"
            ):
                raise ValueError("Nix returned invalid host/check derivations")
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
        before_record = (
            resolve(base, "base") if base != "0" * 40 and not force else None
        )
        if after is None:
            after = resolve(head, "head")
    before = before_record["derivations"] if before_record else {}
    hosts = select_hosts(before, after["derivations"], force)
    # Only an exact base record restored from successful main validation can
    # justify skipping. A freshly evaluated base is not evidence its tests ran.
    cached_base = records[0] if records else None
    trusted_base = (
        cached_base
        if before_record
        and cached_base == before_record
        and valid_record(cached_base, before_record["tree"], context)
        else None
    )
    selected = select_vm_checks(
        trusted_base, after, enabled=select_vm and not fresh and not force
    )
    if vm_selection is not None:
        vm_selection.extend(selected)
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


def select_vm_checks(before, after, enabled=False):
    if not enabled or before is None:
        return list(VM_CHECKS)
    return [
        name for name in VM_CHECKS if before["checks"][name] != after["checks"][name]
    ]


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
    vm_checks = []
    hosts = plan(
        repo,
        args.base,
        args.head,
        args.force,
        args.cache,
        args.verified_head,
        fresh=os.environ.get("CI_FORCE_VALIDATION") == "true",
        validate=args.validate,
        vm_selection=vm_checks,
        select_vm=os.environ.get("GITHUB_EVENT_NAME") == "pull_request",
    )
    result = json.dumps(hosts)
    print(result)
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"hosts={result}\nhas_changes={str(bool(hosts)).lower()}\n")
            stream.write(f"vm_checks={json.dumps(vm_checks)}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write("## Deployment plan\n\n")
            stream.write("| Host | After merge |\n| --- | --- |\n")
            for host in HOSTS:
                action = "Deploy" if host in hosts else "Unchanged"
                stream.write(f"| {host} | {action} |\n")
            stream.write("\n| VM check | Validation |\n| --- | --- |\n")
            for name in VM_CHECKS:
                action = (
                    "Covered by verified PR validation"
                    if os.environ.get("REUSED_VALIDATION") == "true"
                    else "Run"
                    if name in vm_checks
                    else "Unchanged from validated base"
                )
                stream.write(f"| {name} | {action} |\n")
            stream.write(
                "\nPR checks never connect to a host. Deployment uses the exact merged revision.\n"
            )


if __name__ == "__main__":
    main()
