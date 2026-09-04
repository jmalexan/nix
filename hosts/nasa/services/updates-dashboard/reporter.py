import argparse
import datetime as dt
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(temporary, path)


def update_history(report_path, report):
    history_path = Path(report_path).with_name("history.json")
    lock_path = history_path.with_suffix(".lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            history = json.loads(history_path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            history = []
        history.append(
            {
                "type": report["type"],
                "title": report["title"],
                "checkedAt": report["checkedAt"],
                "status": report["status"],
                "counts": report.get("counts", {}),
            }
        )
        atomic_json(history_path, history[-100:])


def write_report(path, report):
    atomic_json(path, report)
    update_history(path, report)


def record(args):
    candidate = args.candidate
    item = {
        "name": args.name,
        "repository": args.repository,
        "currentTag": args.current_tag,
        "currentDigest": args.current_digest,
    }
    if args.kind == "releases":
        item["availableTag"] = candidate
        item["status"] = "update" if candidate != args.current_tag else "current"
        if item["status"] == "update":
            print(f"{args.current_tag} -> {candidate}")
    else:
        candidate_tag, separator, candidate_digest = candidate.partition("@")
        item["availableTag"] = candidate_tag
        item["availableDigest"] = candidate_digest if separator else ""
        item["status"] = (
            "update" if candidate_digest != args.current_digest else "current"
        )
        if item["status"] == "update":
            print(
                f"{args.current_tag}@{args.current_digest} -> "
                f"{candidate_tag}@{candidate_digest}"
            )

    items_path = Path(args.items)
    items_path.parent.mkdir(parents=True, exist_ok=True)
    with items_path.open("a") as output:
        fcntl.flock(output, fcntl.LOCK_EX)
        output.write(json.dumps(item) + "\n")


def finalize(args):
    inventory = json.loads(Path(args.inventory).read_text())["services"]
    observed = {}
    try:
        lines = Path(args.items).read_text().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        if line.strip():
            item = json.loads(line)
            observed[item["name"]] = item

    items = []
    for service in inventory:
        if service["name"] in observed:
            items.append(observed[service["name"]])
        else:
            items.append(
                {
                    **service,
                    "status": "error",
                    "error": "The registry lookup did not return a result.",
                }
            )

    counts = {
        status: sum(item["status"] == status for item in items)
        for status in ("update", "current", "error")
    }
    if args.scanner_status != 0 and counts["current"] + counts["update"] == 0:
        status = "failed"
    elif args.scanner_status != 0 or counts["error"]:
        status = "partial"
    else:
        status = "ok"

    report = {
        "schemaVersion": 1,
        "type": args.kind,
        "title": (
            "Container releases"
            if args.kind == "releases"
            else "Container digest drift"
        ),
        "checkedAt": utc_now(),
        "status": status,
        "counts": counts,
        "items": sorted(items, key=lambda item: item["name"].lower()),
    }
    write_report(args.output, report)


def run(command, capture=False):
    print("+ " + " ".join(command), flush=True)
    if capture:
        result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE)
        return result.stdout.strip()
    subprocess.run(command, check=True)
    return ""


def nix_scan(args):
    checked_at = utc_now()
    output_path = Path(args.output)
    try:
        with tempfile.TemporaryDirectory(prefix="nix-update-forecast.") as root:
            current = Path(root) / "current"
            candidate = Path(root) / "candidate"
            run(
                [
                    args.git,
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    "main",
                    args.repository,
                    str(current),
                ]
            )
            shutil.copytree(current, candidate)
            run([args.nix, "flake", "update", "--flake", f"path:{candidate}"])

            if (current / "flake.lock").read_bytes() == (candidate / "flake.lock").read_bytes():
                report = {
                    "schemaVersion": 1,
                    "type": "nix",
                    "title": "Nix flake forecast",
                    "checkedAt": checked_at,
                    "status": "ok",
                    "counts": {"update": 0, "current": 2, "error": 0},
                    "inputsChanged": False,
                    "hosts": [
                        {"name": host, "status": "current", "changes": ""}
                        for host in ("nasa", "htpc")
                    ],
                }
                write_report(output_path, report)
                print("flake.lock is current; no Nix package changes are forecast.")
                return

            hosts = []
            for host in ("nasa", "htpc"):
                current_path = run(
                    [
                        args.nix,
                        "build",
                        "--no-link",
                        "--print-out-paths",
                        "--max-jobs",
                        str(args.max_jobs),
                        "--cores",
                        str(args.cores),
                        f"path:{current}#nixosConfigurations.{host}.config.system.build.toplevel",
                    ],
                    capture=True,
                ).splitlines()[-1]
                candidate_path = run(
                    [
                        args.nix,
                        "build",
                        "--no-link",
                        "--print-out-paths",
                        "--max-jobs",
                        str(args.max_jobs),
                        "--cores",
                        str(args.cores),
                        f"path:{candidate}#nixosConfigurations.{host}.config.system.build.toplevel",
                    ],
                    capture=True,
                ).splitlines()[-1]
                changes = run(
                    [args.nix, "store", "diff-closures", current_path, candidate_path],
                    capture=True,
                )
                hosts.append(
                    {
                        "name": host,
                        "status": "update" if changes else "current",
                        "changes": changes,
                    }
                )

            updates = sum(host["status"] == "update" for host in hosts)
            report = {
                "schemaVersion": 1,
                "type": "nix",
                "title": "Nix flake forecast",
                "checkedAt": checked_at,
                "status": "ok",
                "counts": {"update": updates, "current": 2 - updates, "error": 0},
                "inputsChanged": True,
                "hosts": hosts,
            }
            write_report(output_path, report)
    except Exception as error:
        report = {
            "schemaVersion": 1,
            "type": "nix",
            "title": "Nix flake forecast",
            "checkedAt": checked_at,
            "status": "failed",
            "counts": {"update": 0, "current": 0, "error": 1},
            "inputsChanged": None,
            "hosts": [],
            "error": str(error),
        }
        write_report(output_path, report)
        raise


def parser():
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    record_parser = commands.add_parser("record")
    record_parser.add_argument("kind", choices=("releases", "digests"))
    record_parser.add_argument("items")
    record_parser.add_argument("name")
    record_parser.add_argument("repository")
    record_parser.add_argument("current_tag")
    record_parser.add_argument("current_digest")
    record_parser.add_argument("candidate")
    record_parser.set_defaults(handler=record)

    finalize_parser = commands.add_parser("finalize")
    finalize_parser.add_argument("kind", choices=("releases", "digests"))
    finalize_parser.add_argument("inventory")
    finalize_parser.add_argument("items")
    finalize_parser.add_argument("output")
    finalize_parser.add_argument("scanner_status", type=int)
    finalize_parser.set_defaults(handler=finalize)

    nix_parser = commands.add_parser("nix-scan")
    nix_parser.add_argument("output")
    nix_parser.add_argument("repository")
    nix_parser.add_argument("git")
    nix_parser.add_argument("nix")
    nix_parser.add_argument("--max-jobs", type=int, default=1)
    nix_parser.add_argument("--cores", type=int, default=8)
    nix_parser.set_defaults(handler=nix_scan)
    return result


if __name__ == "__main__":
    arguments = parser().parse_args()
    arguments.handler(arguments)
