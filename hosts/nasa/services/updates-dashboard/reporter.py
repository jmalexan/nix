import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

ANSI_SEQUENCE = re.compile(
    r"\x1b(?:\][^\x07]*(?:\x07|\x1b\\)|\[[0-?]*[ -/]*[@-~]|[@-_])"
)
SIZE_SUFFIX = re.compile(r", [+-]?\d+(?:\.\d+)? (?:B|[KMGTPE]iB)$")
ACTION_USE = re.compile(
    r"uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(v[0-9]+(?:\.[A-Za-z0-9_.-]+)*)"
)


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


def release_notes_url(service, item):
    metadata = service.get("releaseNotes")
    version = item.get("availableTag")
    if not metadata or not version:
        return None
    suffix = metadata.get("stripSuffix", "")
    if suffix and version.endswith(suffix):
        version = version[: -len(suffix)]
    tag = metadata.get("tagPrefix", "") + version
    return f"https://github.com/{metadata['repository']}/releases/tag/{quote(tag)}"


def external_release_notes_url(service, item):
    metadata = service.get("releaseNotes") or {}
    prefix = metadata.get("externalUrlPrefix")
    notes_url = release_notes_url(service, item)
    if not prefix or not notes_url:
        return None

    tag = notes_url.rsplit("/", 1)[-1]
    request = Request(
        (f"https://api.github.com/repos/{metadata['repository']}/releases/tags/{tag}"),
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "nasa-updates-dashboard",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=15) as response:
            body = json.load(response).get("body") or ""
    except (OSError, HTTPError, json.JSONDecodeError) as error:
        print(f"Optional release-post lookup failed: {error}", file=sys.stderr)
        return None

    for url in re.findall(r"https?://[^\s<>()\[\]]+", body):
        url = url.rstrip(".,;:'\"")
        if url.startswith(prefix):
            return url
    return None


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
            item = {**observed[service["name"]]}
            notes_url = release_notes_url(service, item)
            if notes_url:
                item["releaseNotesUrl"] = notes_url
            if args.kind == "releases" and item.get("status") == "update":
                external_url = external_release_notes_url(service, item)
                if external_url:
                    item["externalReleaseNotesUrl"] = external_url
            if service.get("updateGroup"):
                item["updateGroup"] = service["updateGroup"]
            items.append(item)
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


def run(command, capture=False, cwd=None):
    print("+ " + " ".join(command), flush=True)
    if capture:
        result = subprocess.run(
            command,
            check=True,
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
        )
        return result.stdout.strip()
    subprocess.run(command, check=True, cwd=cwd)
    return ""


def plain_terminal_text(value):
    return ANSI_SEQUENCE.sub("", value).replace("\r", "")


def version_change_text(value):
    cleaned = plain_terminal_text(value)
    return "\n".join(
        SIZE_SUFFIX.sub("", line) for line in cleaned.splitlines() if " → " in line
    )


def action_version_key(value):
    match = re.fullmatch(r"v(\d+)(?:\.(\d+))?(?:\.(\d+))?", value)
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def newest_action_ref(git, action, current_ref):
    output = run(
        [git, "ls-remote", "--tags", "--refs", f"https://github.com/{action}.git"],
        capture=True,
    )
    tags = [line.rsplit("refs/tags/", 1)[-1] for line in output.splitlines()]
    if re.fullmatch(r"v\d+", current_ref):
        candidates = [tag for tag in tags if re.fullmatch(r"v\d+", tag)]
    else:
        candidates = [tag for tag in tags if action_version_key(tag) is not None]
    if not candidates:
        raise RuntimeError(f"No version tags were found for {action}")
    return max(candidates, key=action_version_key)


def actions_scan(args):
    checked_at = utc_now()
    output_path = Path(args.output)
    try:
        with tempfile.TemporaryDirectory(prefix="actions-update-scan.") as root:
            checkout = Path(root) / "repository"
            run(
                [
                    args.git,
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    "main",
                    args.repository,
                    str(checkout),
                ]
            )
            discovered = {}
            workflow_root = checkout / ".github" / "workflows"
            for path in sorted(workflow_root.glob("*.y*ml")):
                for action, current_ref in ACTION_USE.findall(path.read_text()):
                    discovered.setdefault(
                        action,
                        {"name": action, "currentRef": current_ref, "files": []},
                    )["files"].append(str(path.relative_to(checkout)))

            items = []
            for action, item in sorted(discovered.items()):
                try:
                    available_ref = newest_action_ref(
                        args.git, action, item["currentRef"]
                    )
                    item.update(
                        {
                            "availableRef": available_ref,
                            "releaseNotesUrl": (
                                f"https://github.com/{action}/releases/tag/"
                                f"{quote(available_ref)}"
                            ),
                            "status": (
                                "update"
                                if available_ref != item["currentRef"]
                                else "current"
                            ),
                        }
                    )
                except Exception as error:
                    item.update({"status": "error", "error": str(error)})
                items.append(item)

            counts = {
                status: sum(item["status"] == status for item in items)
                for status in ("update", "current", "error")
            }
            report = {
                "schemaVersion": 1,
                "type": "actions",
                "title": "GitHub Actions",
                "checkedAt": checked_at,
                "status": "partial" if counts["error"] else "ok",
                "counts": counts,
                "items": items,
            }
            write_report(output_path, report)
    except Exception as error:
        write_report(
            output_path,
            {
                "schemaVersion": 1,
                "type": "actions",
                "title": "GitHub Actions",
                "checkedAt": checked_at,
                "status": "failed",
                "counts": {"update": 0, "current": 0, "error": 1},
                "items": [],
                "error": str(error),
            },
        )
        raise


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

            if (current / "flake.lock").read_bytes() == (
                candidate / "flake.lock"
            ).read_bytes():
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
                changes = version_change_text(
                    run(
                        [
                            args.nix,
                            "store",
                            "diff-closures",
                            current_path,
                            candidate_path,
                        ],
                        capture=True,
                    )
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


def load_report(root, name):
    try:
        return json.loads((Path(root) / name).read_text())
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise RuntimeError(
            f"A usable {name} report is required; run its scan first"
        ) from error


def result_key(kind, target):
    safe_target = re.sub(r"[^A-Za-z0-9_.-]+", "--", target)
    return f"{kind}--{safe_target}"


def resolve_digest(skopeo, repository, tag):
    return run(
        [
            skopeo,
            "inspect",
            "--no-tags",
            "--format",
            "{{.Digest}}",
            f"docker://{repository}:{tag}",
        ],
        capture=True,
    )


def replace_container_image(checkout, current_image, target_image):
    needle = f'image = "{current_image}";'
    replacement = f'image = "{target_image}";'
    matches = []
    for path in checkout.rglob("*.nix"):
        count = path.read_text().count(needle)
        if count:
            matches.extend([path] * count)
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one declaration for {current_image}, found {len(matches)}"
        )
    path = matches[0]
    path.write_text(path.read_text().replace(needle, replacement, 1))
    return str(path.relative_to(checkout))


def prepare_container_pr(args, checkout, target):
    inventory = load_report(Path(args.inventory).parent, Path(args.inventory).name)[
        "services"
    ]
    inventory_by_name = {item["name"]: item for item in inventory}
    if target not in inventory_by_name:
        raise RuntimeError(f"Unknown container service: {target}")

    releases = {
        item["name"]: item
        for item in load_report(args.state, "releases.json").get("items", [])
    }
    digests = {
        item["name"]: item
        for item in load_report(args.state, "digests.json").get("items", [])
    }
    selected = inventory_by_name[target]
    group = selected.get("updateGroup")
    names = [
        item["name"]
        for item in inventory
        if item["name"] == target or (group and item.get("updateGroup") == group)
    ]

    changes = []
    notes = []
    for name in names:
        installed = inventory_by_name[name]
        release = releases.get(name, {})
        digest = digests.get(name, {})
        if release.get("status") != "update" and digest.get("status") != "update":
            continue

        target_tag = (
            release.get("availableTag")
            if release.get("status") == "update"
            else installed["currentTag"]
        )
        if target_tag != installed["currentTag"]:
            target_digest = resolve_digest(
                args.skopeo, installed["repository"], target_tag
            )
        else:
            target_digest = digest.get("availableDigest")
        if not target_digest:
            raise RuntimeError(f"No target digest is available for {name}")

        current_image = f"{installed['repository']}:{installed['currentTag']}"
        if installed.get("currentDigest"):
            current_image += f"@{installed['currentDigest']}"
        target_image = f"{installed['repository']}:{target_tag}@{target_digest}"
        path = replace_container_image(checkout, current_image, target_image)
        changes.append(
            {
                "name": name,
                "path": path,
                "current": installed["currentTag"],
                "available": target_tag,
            }
        )
        if release.get("releaseNotesUrl"):
            notes.append((f"{name} GitHub release", release["releaseNotesUrl"]))
        if release.get("externalReleaseNotesUrl"):
            notes.append((f"{name} release post", release["externalReleaseNotesUrl"]))

    if not changes:
        raise RuntimeError(
            "The latest reports do not contain an update for this service"
        )

    display = group or target
    versions = sorted({change["available"] for change in changes})
    title = f"Update {display} to {', '.join(versions)}"
    body = ["Created from the System updates dashboard.", "", "Changes:"]
    body.extend(
        f"- `{change['name']}`: `{change['current']}` → `{change['available']}`"
        for change in changes
    )
    if notes:
        body.extend(["", "Release notes:"])
        body.extend(f"- [{label}]({url})" for label, url in notes)
    return title, "\n".join(body), display


def prepare_action_pr(args, checkout, target):
    report = load_report(args.state, "actions.json")
    item = next(
        (
            candidate
            for candidate in report.get("items", [])
            if candidate["name"] == target
        ),
        None,
    )
    if not item or item.get("status") != "update":
        raise RuntimeError(
            "The latest report does not contain an update for this action"
        )
    needle = f"uses: {target}@{item['currentRef']}"
    replacement = f"uses: {target}@{item['availableRef']}"
    replacements = 0
    for path in (checkout / ".github" / "workflows").glob("*.y*ml"):
        text = path.read_text()
        count = text.count(needle)
        if count:
            path.write_text(text.replace(needle, replacement))
            replacements += count
    if not replacements:
        raise RuntimeError(f"No workflow references matched {needle}")
    title = f"Update {target} to {item['availableRef']}"
    body = "\n".join(
        [
            "Created from the System updates dashboard.",
            "",
            f"- `{target}`: `{item['currentRef']}` → `{item['availableRef']}`",
            f"- [Release notes]({item['releaseNotesUrl']})",
        ]
    )
    return title, body, target


def prepare_nix_pr(args, checkout):
    report = load_report(args.state, "nix.json")
    if report.get("inputsChanged") is not True:
        raise RuntimeError("The latest Nix report does not contain flake input changes")
    run([args.nix, "flake", "update", "--flake", f"path:{checkout}"])
    return (
        "Update Nix flake inputs",
        "Created from the System updates dashboard after a successful closure forecast.",
        "nix-flake",
    )


def github_request(token, repository, path, method="GET", payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    request = Request(
        f"https://api.github.com/repos/{repository}{path}",
        data=body,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "nasa-updates-dashboard",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"GitHub API returned {error.code}: {detail}") from error


def pull_request_state(pull):
    if pull.get("merged_at"):
        return "merged"
    return pull.get("state", "unknown")


def pull_request_result(pull):
    return {
        "status": pull_request_state(pull),
        "url": pull["html_url"],
        "number": pull["number"],
    }


def publish_pull_request(args, checkout, title, body, target):
    changed = run(
        [args.git, "diff", "--name-only", "--"], capture=True, cwd=checkout
    ).splitlines()
    if not changed:
        raise RuntimeError("The proposed update did not change any repository files")

    fingerprint = hashlib.sha256()
    for relative in sorted(changed):
        fingerprint.update(relative.encode())
        fingerprint.update((checkout / relative).read_bytes())
    slug = re.sub(r"[^a-z0-9]+", "-", target.lower()).strip("-")[:45]
    branch = f"updates-dashboard/{slug}-{fingerprint.hexdigest()[:10]}"

    token = Path(args.token).read_text().strip()
    if not token:
        raise RuntimeError("The GitHub token file is empty")
    owner = args.github_repository.split("/", 1)[0]
    query = urlencode({"state": "all", "head": f"{owner}:{branch}"})
    existing = github_request(token, args.github_repository, f"/pulls?{query}")
    open_pull = next(
        (pull for pull in existing if pull_request_state(pull) == "open"), None
    )
    if open_pull:
        return pull_request_result(open_pull)
    if existing:
        branch = f"{branch}-retry-{os.urandom(3).hex()}"

    base_commit = run([args.git, "rev-parse", "HEAD"], capture=True, cwd=checkout)
    commit = github_request(
        token, args.github_repository, f"/git/commits/{base_commit}"
    )
    entries = []
    for relative in changed:
        blob = github_request(
            token,
            args.github_repository,
            "/git/blobs",
            method="POST",
            payload={
                "content": base64.b64encode(
                    (checkout / relative).read_bytes()
                ).decode(),
                "encoding": "base64",
            },
        )
        entries.append(
            {"path": relative, "mode": "100644", "type": "blob", "sha": blob["sha"]}
        )
    tree = github_request(
        token,
        args.github_repository,
        "/git/trees",
        method="POST",
        payload={"base_tree": commit["tree"]["sha"], "tree": entries},
    )
    new_commit = github_request(
        token,
        args.github_repository,
        "/git/commits",
        method="POST",
        payload={"message": title, "tree": tree["sha"], "parents": [base_commit]},
    )
    github_request(
        token,
        args.github_repository,
        "/git/refs",
        method="POST",
        payload={"ref": f"refs/heads/{branch}", "sha": new_commit["sha"]},
    )
    pull = github_request(
        token,
        args.github_repository,
        "/pulls",
        method="POST",
        payload={"title": title, "body": body, "head": branch, "base": "main"},
    )
    return pull_request_result(pull)


def create_pr(args, job):
    kind = job.get("kind")
    target = job.get("target", kind)
    with tempfile.TemporaryDirectory(prefix="updates-dashboard-pr.") as root:
        checkout = Path(root) / "repository"
        run(
            [
                args.git,
                "clone",
                "--depth",
                "1",
                "--branch",
                "main",
                args.repository,
                str(checkout),
            ]
        )
        if kind == "container":
            title, body, branch_target = prepare_container_pr(args, checkout, target)
        elif kind == "action":
            title, body, branch_target = prepare_action_pr(args, checkout, target)
        elif kind == "nix":
            title, body, branch_target = prepare_nix_pr(args, checkout)
        else:
            raise RuntimeError(f"Unsupported pull request kind: {kind}")
        return publish_pull_request(args, checkout, title, body, branch_target)


def pr_queue(args):
    queue = Path(args.queue)
    results = Path(args.results)
    queue.mkdir(parents=True, exist_ok=True)
    results.mkdir(parents=True, exist_ok=True)
    for path in sorted(queue.glob("*.json")):
        try:
            job = json.loads(path.read_text())
            key = result_key(job.get("kind", "unknown"), job.get("target", "unknown"))
            result_path = results / f"{key}.json"
            state = {
                "kind": job.get("kind"),
                "target": job.get("target"),
                "status": "running",
                "startedAt": utc_now(),
            }
            atomic_json(result_path, state)
            try:
                pull = create_pr(args, job)
                state.update({**pull, "finishedAt": utc_now()})
            except Exception as error:
                state.update(
                    {"status": "failed", "error": str(error), "finishedAt": utc_now()}
                )
                print(f"Pull request job failed: {error}", file=sys.stderr)
            atomic_json(result_path, state)
        finally:
            path.unlink(missing_ok=True)


def optional_json(path, fallback):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError):
        return fallback


def visible_pull_request_keys(state_root, inventory_path):
    state_root = Path(state_root)
    inventory = optional_json(inventory_path, {"services": []}).get("services", [])
    inventory_by_name = {item["name"]: item for item in inventory}
    keys = set()

    updates = set()
    for report_name in ("releases.json", "digests.json"):
        report = optional_json(state_root / report_name, {})
        updates.update(
            item["name"]
            for item in report.get("items", [])
            if item.get("status") == "update"
        )
    for name in updates:
        service = inventory_by_name.get(name, {})
        group = service.get("updateGroup")
        if group:
            targets = sorted(
                item["name"] for item in inventory if item.get("updateGroup") == group
            )
            target = targets[0] if targets else name
        else:
            target = name
        keys.add(result_key("container", target))

    actions = optional_json(state_root / "actions.json", {})
    keys.update(
        result_key("action", item["name"])
        for item in actions.get("items", [])
        if item.get("status") == "update"
    )
    nix = optional_json(state_root / "nix.json", {})
    if nix.get("inputsChanged") is True:
        keys.add(result_key("nix", "nix"))
    return keys


def pr_status(args):
    candidates = []
    visible_keys = visible_pull_request_keys(args.state, args.inventory)
    for key in visible_keys:
        path = Path(args.results) / f"{key}.json"
        result = optional_json(path, {})
        if result.get("status") in ("complete", "open") and result.get("url"):
            candidates.append((path, result))
    if not candidates:
        return

    token = Path(args.token).read_text().strip()
    if not token:
        return
    query = urlencode(
        {
            "state": "all",
            "sort": "updated",
            "direction": "desc",
            "per_page": 100,
        }
    )
    pulls = github_request(token, args.github_repository, f"/pulls?{query}")
    by_url = {pull["html_url"]: pull for pull in pulls}
    for path, result in candidates:
        pull = by_url.get(result.get("url"))
        if not pull:
            continue
        status = pull_request_state(pull)
        if result.get("status") != status:
            result["status"] = status
            atomic_json(path, result)


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

    actions_parser = commands.add_parser("actions-scan")
    actions_parser.add_argument("output")
    actions_parser.add_argument("repository")
    actions_parser.add_argument("git")
    actions_parser.set_defaults(handler=actions_scan)

    pr_parser = commands.add_parser("pr-queue")
    pr_parser.add_argument("queue")
    pr_parser.add_argument("results")
    pr_parser.add_argument("state")
    pr_parser.add_argument("inventory")
    pr_parser.add_argument("repository")
    pr_parser.add_argument("github_repository")
    pr_parser.add_argument("token")
    pr_parser.add_argument("git")
    pr_parser.add_argument("nix")
    pr_parser.add_argument("skopeo")
    pr_parser.set_defaults(handler=pr_queue)

    status_parser = commands.add_parser("pr-status")
    status_parser.add_argument("results")
    status_parser.add_argument("state")
    status_parser.add_argument("inventory")
    status_parser.add_argument("github_repository")
    status_parser.add_argument("token")
    status_parser.set_defaults(handler=pr_status)
    return result


if __name__ == "__main__":
    arguments = parser().parse_args()
    arguments.handler(arguments)
