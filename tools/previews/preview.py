"""Local preview lifecycle and a read-only HTTP/WebSocket router. No remote control API."""

import argparse
import asyncio
import contextlib
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from aiohttp import (
    ClientError,
    ClientSession,
    ClientTimeout,
    DummyCookieJar,
    WSMsgType,
    web,
)
from yarl import URL

RELOAD_SCRIPT = """
(() => {
  let previous;
  setInterval(async () => {
    try {
      const response = await fetch('/_preview/version', {cache: 'no-store'});
      if (!response.ok) return;
      const {version} = await response.json();
      if (previous !== undefined && version !== previous) location.reload();
      previous = version;
    } catch (_) { /* A refresh may briefly restart the backend. */ }
  }, 1500);
})();
"""
DOMAIN = "preview.nasa.jmalexan.com"
NAME = re.compile(r"[a-z][a-z0-9-]{0,39}")
FIRST_PORT = 18100
SLOTS = 8
STATE = Path.home() / ".local/share/robot-previews"
HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def load(root=STATE):
    try:
        return json.loads((root / "registry.json").read_text())
    except FileNotFoundError:
        return {}


def save(records, root=STATE):
    temporary = root / "registry.tmp"
    temporary.write_text(json.dumps(records, indent=2) + "\n")
    temporary.replace(root / "registry.json")


def unit(name):
    return f"robot-preview-{name}.service"


def active(name):
    return (
        subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", unit(name)]
        ).returncode
        == 0
    )


def remove(name, records):
    result = subprocess.run(
        ["systemctl", "--user", "stop", unit(name)], capture_output=True
    )
    if result.returncode and active(name):
        raise RuntimeError(f"Could not stop {name}; keeping its registry and data")
    shutil.rmtree(STATE / name, ignore_errors=True)
    del records[name]


def clean(records):
    for name, record in list(records.items()):
        if record["expires"] <= time.time() or not active(name):
            remove(name, records)


def target(host, records, now=None):
    suffix = "." + DOMAIN
    if not host.endswith(suffix):
        return None
    name = host[: -len(suffix)]
    record = records.get(name)
    if not NAME.fullmatch(name) or not record:
        return None
    port = record.get("port")
    if type(port) is not int or not FIRST_PORT <= port < FIRST_PORT + SLOTS:
        return None
    if record.get("expires", 0) <= (time.time() if now is None else now):
        return None
    return f"http://127.0.0.1:{port}"


def headers_without_hops(headers):
    excluded = HOP | {
        part.strip().lower() for part in headers.get("Connection", "").split(",")
    }
    return [
        (key, value) for key, value in headers.items() if key.lower() not in excluded
    ]


async def proxy(request):
    records = load(request.app["root"])
    upstream = target(request.host, records)
    if not upstream:
        raise web.HTTPNotFound(text="Preview is stopped, expired, or unknown.\n")
    url = URL(upstream + request.raw_path, encoded=True)
    headers = headers_without_hops(request.headers)
    headers = [
        (k, v)
        for k, v in headers
        if k.lower()
        not in {"x-forwarded-proto", "x-forwarded-host", "x-forwarded-for", "forwarded"}
    ]
    headers = [(k, v) for k, v in headers if k.lower() != "accept-encoding"]
    headers.append(("Accept-Encoding", "identity"))
    headers.append(("X-Forwarded-Proto", "https"))
    if request.path == "/_preview/version":
        return web.json_response(
            {"version": records[request.host.split(".")[0]].get("version", 0)},
            headers={"Cache-Control": "no-store"},
        )
    if request.path == "/_preview/reload.js":
        return web.Response(
            text=RELOAD_SCRIPT,
            content_type="application/javascript",
            headers={"Cache-Control": "no-store"},
        )
    try:
        if request.headers.get("Upgrade", "").lower() == "websocket":
            protocols = tuple(
                p.strip()
                for p in request.headers.get("Sec-WebSocket-Protocol", "").split(",")
                if p.strip()
            )
            headers = [
                (k, v) for k, v in headers if not k.lower().startswith("sec-websocket-")
            ]
            async with request.app["client"].ws_connect(
                url,
                headers=headers,
                protocols=protocols,
                origin=request.headers.get("Origin"),
            ) as backend:
                browser = web.WebSocketResponse(protocols=protocols)
                await browser.prepare(request)

                async def relay(source, destination):
                    async for message in source:
                        if message.type == WSMsgType.TEXT:
                            await destination.send_str(message.data)
                        elif message.type == WSMsgType.BINARY:
                            await destination.send_bytes(message.data)
                    await destination.close()

                await asyncio.gather(relay(browser, backend), relay(backend, browser))
                return browser
        async with request.app["client"].request(
            request.method,
            url,
            headers=headers,
            data=request.content,
            allow_redirects=False,
        ) as backend:
            response_headers = headers_without_hops(backend.headers)
            if (
                request.method != "HEAD"
                and backend.content_type == "text/html"
                and not backend.headers.get("Content-Encoding")
            ):
                body = await backend.read()
                script = b'<script src="/_preview/reload.js" defer></script>'
                body = (
                    body.replace(b"</head>", script + b"</head>", 1)
                    if b"</head>" in body
                    else script + body
                )
                response_headers = [
                    (k, v) for k, v in response_headers if k.lower() != "content-length"
                ]
                return web.Response(
                    body=body,
                    status=backend.status,
                    headers=response_headers
                    + [
                        ("Cache-Control", "no-store"),
                        ("X-Robots-Tag", "noindex, nofollow"),
                    ],
                )
            response = web.StreamResponse(
                status=backend.status, headers=response_headers
            )
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Robots-Tag"] = "noindex, nofollow"
            await response.prepare(request)
            async for chunk in backend.content.iter_chunked(65536):
                await response.write(chunk)
            await response.write_eof()
            return response
    except (ClientError, OSError, asyncio.TimeoutError) as error:
        raise web.HTTPBadGateway(
            text="Preview is starting or unavailable.\n"
        ) from error


def router(root=STATE):
    app = web.Application(client_max_size=1024**2)
    app["root"] = root

    async def session(app):
        async with ClientSession(
            auto_decompress=False,
            cookie_jar=DummyCookieJar(),
            timeout=ClientTimeout(total=None, sock_connect=5, sock_read=120),
        ) as client:
            app["client"] = client
            yield

    app.cleanup_ctx.append(session)
    app.router.add_route("*", "/{path:.*}", proxy)
    return app


def build(repo):
    frontend = Path(repo) / "apps/microapps/web"
    if not (frontend / "node_modules").exists():
        subprocess.run(["npm", "ci"], cwd=frontend, check=True)
    subprocess.run(["npm", "run", "build"], cwd=frontend, check=True)


def ready(name, metadata):
    import urllib.error
    import urllib.request

    request = urllib.request.Request(
        f"http://127.0.0.1:{metadata['port']}/",
        headers={"Host": metadata["origin"].removeprefix("https://")},
    )
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if not active(name):
            raise RuntimeError(
                f"Preview failed; inspect journalctl --user -u {unit(name)}"
            )
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                if response.status < 500:
                    return
        except urllib.error.HTTPError as error:
            if error.code < 500:
                return
        except (OSError, TimeoutError):
            pass
        time.sleep(0.2)
    raise RuntimeError(
        f"Preview did not become ready; inspect journalctl --user -u {unit(name)}"
    )


def refresh(name, records):
    record = records[name]
    if record["app"] != "custom":
        build(record["repo"])
    subprocess.run(["systemctl", "--user", "restart", unit(name)], check=True)
    ready(name, record)
    record["version"] = time.time_ns()
    save(records)
    print(record["origin"])


def start(args, records):
    if args.name in records:
        raise ValueError("Name already running; stop it first or choose another name")
    if len(records) >= SLOTS:
        raise ValueError(f"At most {SLOTS} previews may run concurrently")
    repo = Path(args.repo).resolve()
    if not (repo / "flake.nix").is_file():
        raise ValueError("--repo must point to a repository checkout")
    port = next(
        p
        for p in range(FIRST_PORT, FIRST_PORT + SLOTS)
        if p not in {r["port"] for r in records.values()}
    )
    if args.app != "custom":
        build(repo)
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if args.app == "custom" and not command:
        raise ValueError(
            "custom needs a command after --; use PORT and PREVIEW_ORIGIN from its environment"
        )
    directory = STATE / args.name
    if directory.exists() and not active(args.name):
        shutil.rmtree(directory)
    directory.mkdir(mode=0o700)
    origin = f"https://{args.name}.{DOMAIN}"
    metadata = {
        "port": port,
        "version": time.time_ns(),
        "origin": origin,
        "repo": str(repo),
        "app": args.app,
        "expires": time.time() + args.hours * 3600,
    }
    (directory / "instance.json").write_text(json.dumps(metadata))
    if args.app != "custom":
        command = [
            sys.executable,
            str(Path(__file__).with_name("serve.py")),
            str(directory),
        ]
    # Reserve the port durably before launching; interrupted starts are cleaned
    # on the next lifecycle operation instead of becoming untracked processes.
    records[args.name] = metadata
    save(records)
    try:
        subprocess.run(
            [
                "systemd-run",
                "--user",
                "--collect",
                "--slice=robot-previews.slice",
                f"--unit={unit(args.name)}",
                f"--working-directory={repo}",
                "--property=MemoryMax=768M",
                "--property=CPUQuota=100%",
                "--property=TasksMax=128",
                f"--property=RuntimeMaxSec={args.hours * 3600}",
                "--property=KillMode=control-group",
                "--property=UMask=0077",
                f"--setenv=PATH={os.environ['PATH']}",
                f"--setenv=PORT={port}",
                f"--setenv=PREVIEW_ORIGIN={origin}",
                *command,
            ],
            check=True,
        )
        ready(args.name, metadata)
        records[args.name] = metadata
        save(records)
    except BaseException:
        subprocess.run(["systemctl", "--user", "stop", unit(args.name)], check=False)
        shutil.rmtree(directory, ignore_errors=True)
        records.pop(args.name, None)
        save(records)
        raise
    print(origin)
    print(f"Logs: journalctl --user -u {unit(args.name)} -f")
    if args.app != "custom":
        print("Preview account password: NASA preview password")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("start")
    p.add_argument("name")
    p.add_argument(
        "--app", choices=["approve", "updates", "backups", "custom"], default="approve"
    )
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--hours", type=int, choices=range(1, 25), default=8)
    for action in ("stop", "refresh", "watch"):
        p = sub.add_parser(action)
        p.add_argument("name")
    sub.add_parser("list")
    sub.add_parser("cleanup")
    sub.add_parser("router")
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        separator = argv.index("--")
        argv, command = argv[:separator], argv[separator + 1 :]
    args = parser.parse_args(argv)
    if command and (args.action != "start" or args.app != "custom"):
        parser.error("commands after -- require start --app custom")
    args.command = command
    if hasattr(args, "name") and not NAME.fullmatch(args.name):
        parser.error(
            "name must be 1–40 lowercase letters, digits or hyphens, starting with a letter"
        )
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.action == "router":
        web.run_app(router(), host="10.200.201.2", port=8099, access_log=None)
        return
    with (STATE / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        records = load()
        clean(records)
        save(records)
        if args.action == "start":
            start(args, records)
        elif args.action in {"refresh", "watch"}:
            if args.name not in records:
                parser.error("preview is not running")
            if args.action == "refresh":
                refresh(args.name, records)
            else:
                if records[args.name]["app"] == "custom":
                    parser.error("custom previews use their server's own file watcher")
                # A watcher is optional; the managed preview outlives this command.
                record = records[args.name]
                repo = Path(record["repo"])
                roots = [
                    repo / "apps/microapps/backend",
                    repo / "apps/microapps/web/src",
                ]
                roots += [repo / "apps/backups"] if record["app"] == "backups" else []
                roots += (
                    [repo / "hosts/nasa/services/updates-dashboard"]
                    if record["app"] == "updates"
                    else []
                )

                def signature():
                    return sorted(
                        (str(p), p.stat().st_mtime_ns)
                        for root in roots
                        for p in root.rglob("*")
                        if p.is_file() and "__pycache__" not in p.parts
                    )

                previous = signature()
                # Release the lifecycle lock while waiting; refresh uses its own CLI.
                fcntl.flock(lock, fcntl.LOCK_UN)
                while active(args.name) and time.time() < record["expires"]:
                    time.sleep(1)
                    current = signature()
                    if current != previous:
                        time.sleep(0.5)
                        result = subprocess.run(
                            [sys.executable, __file__, "refresh", args.name]
                        )
                        previous = signature()
                        if result.returncode:
                            print(
                                "Refresh failed; fix the change and save again",
                                file=sys.stderr,
                            )
        elif args.action == "stop":
            if args.name not in records:
                parser.error("preview is not running")
            remove(args.name, records)
            save(records)
        elif args.action == "list":
            for name, record in records.items():
                remaining = max(0, int((record["expires"] - time.time()) / 60))
                print(
                    f"{name}\t{record['app']}\t{record['origin']}\t{remaining}m\t{record['repo']}"
                )


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        main()
