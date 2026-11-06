#!/usr/bin/env python3
"""Run gh or Git with a short-lived, single-repository GitHub App identity."""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

REPOSITORY = "jmalexan/nix"
PERMISSIONS = {
    "contents": "write",
    "pull_requests": "write",
    "workflows": "write",
    "actions": "read",
    "checks": "read",
    "metadata": "read",
}
STATE = Path.home() / ".local/share/nasa-github-app"


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def jwt(app_id, key_bytes, now=None):
    now = int(time.time()) if now is None else now
    key = serialization.load_pem_private_key(key_bytes, password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ValueError("GitHub App key must be RSA")
    header = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = b64(
        json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)}).encode()
    )
    message = header + b"." + payload
    signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
    return (message + b"." + b64(signature)).decode()


def api(token, path, body=None, method=None):
    request = Request(
        "https://api.github.com" + path,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
            "User-Agent": "nasa-github-app",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else None
    except HTTPError as error:
        # Do not include response bodies, tokens, or signing material in logs.
        raise RuntimeError(
            f"GitHub API returned HTTP {error.code} for {path}"
        ) from None


def installation_token(app_id, key_bytes, call=api):
    signed = jwt(app_id, key_bytes)
    installation = call(signed, f"/repos/{REPOSITORY}/installation")
    if installation["account"]["login"] != REPOSITORY.split("/")[0]:
        raise ValueError("Unexpected installation owner")
    if installation["repository_selection"] != "selected":
        raise ValueError(
            "Install the App on selected repositories, not all repositories"
        )
    granted = installation["permissions"]
    if granted != PERMISSIONS:
        raise ValueError(
            "App permissions differ from the documented minimal permissions"
        )
    response = call(
        signed,
        f"/app/installations/{installation['id']}/access_tokens",
        {
            "repositories": [REPOSITORY.split("/")[1]],
            "permissions": PERMISSIONS,
        },
    )
    return response["token"], installation


def secure_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)


def read_config():
    if STATE.is_symlink() or STATE.stat().st_mode & 0o077:
        raise ValueError("GitHub App directory must be private (mode 0700)")
    for name in ("config.json", "private-key.pem"):
        path = STATE / name
        if path.is_symlink() or path.stat().st_mode & 0o077:
            raise ValueError("GitHub App credential files must be private (mode 0600)")
    return json.loads((STATE / "config.json").read_text()), (
        STATE / "private-key.pem"
    ).read_bytes()


def clean_environment(token, config_dir):
    env = {
        key: value
        for key, value in os.environ.items()
        if key
        not in {
            "GH_TOKEN",
            "GITHUB_TOKEN",
            "GH_ENTERPRISE_TOKEN",
            "GITHUB_ENTERPRISE_TOKEN",
            "GH_CONFIG_DIR",
            "GH_HOST",
            "GH_DEBUG",
            "GH_REPO",
            "GIT_ASKPASS",
            "SSH_ASKPASS",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
            "GIT_TRACE",
            "GIT_TRACE_CURL",
            "GIT_CURL_VERBOSE",
        }
        and not key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"))
    }
    env.update(
        GH_TOKEN=token,
        GH_HOST="github.com",
        GH_REPO=REPOSITORY,
        GH_CONFIG_DIR=config_dir,
        GH_PROMPT_DISABLED="1",
        GIT_TERMINAL_PROMPT="0",
        GIT_SSH_COMMAND="false",
    )
    return env


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    configure = sub.add_parser("configure")
    configure.add_argument("--app-id", required=True, type=int)
    configure.add_argument("--key-file", required=True, type=Path)
    sub.add_parser("status")
    for name in ("gh", "git"):
        command = sub.add_parser(name)
        command.add_argument("args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    token = None
    try:
        if args.operation == "configure":
            key = args.key_file.read_bytes()
            token, installation = installation_token(args.app_id, key)
            # Refuse to replace an existing identity or follow a symlink.
            STATE.mkdir(mode=0o700, parents=True, exist_ok=False)
            secure_write(STATE / "private-key.pem", key)
            secure_write(
                STATE / "config.json", json.dumps({"app_id": args.app_id}).encode()
            )
            print(f"Configured GitHub App {args.app_id} for {REPOSITORY}.")
            return 0
        config, key = read_config()
        token, installation = installation_token(config["app_id"], key)
        if args.operation == "status":
            print(
                json.dumps(
                    {
                        "app_id": config["app_id"],
                        "installation_id": installation["id"],
                        "repository": REPOSITORY,
                        "permissions": PERMISSIONS,
                    },
                    indent=2,
                )
            )
            return 0
        command = args.args[1:] if args.args[:1] == ["--"] else args.args
        if not command:
            raise ValueError("A gh or git command is required")
        with tempfile.TemporaryDirectory(prefix="github-bot-") as config_dir:
            env = clean_environment(token, config_dir)
            if args.operation == "git":
                # Override persisted owner helpers. The URL stays credential-free.
                command = [
                    "git",
                    "-c",
                    "credential.helper=",
                    "-c",
                    "http.extraHeader=",
                    "-c",
                    "http.https://github.com/.extraHeader=",
                    "-c",
                    "url.https://github.com/.insteadOf=git@github.com:",
                    "-c",
                    "url.https://github.com/.insteadOf=ssh://git@github.com/",
                    "-c",
                    "credential.https://github.com.helper=!gh auth git-credential",
                    *command,
                ]
            else:
                command = ["gh", *command]
            return subprocess.run(command, env=env, check=False).returncode
    except (OSError, ValueError, RuntimeError) as error:
        print(f"GitHub bot: {error}", file=sys.stderr)
        return 1
    finally:
        if token:
            try:
                api(token, "/installation/token", method="DELETE")
            except (OSError, RuntimeError):
                # Installation tokens expire automatically even if revocation fails.
                print(
                    "Could not revoke temporary token; its automatic expiry still applies.",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    sys.exit(main())
