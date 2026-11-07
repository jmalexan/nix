"""Git operations over server-owned bare caches; never check out repository code."""

import base64
import contextlib
import fcntl
import math
import os
import re
import signal
import subprocess
import tempfile
import time
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, model_validator

OID = r"^[0-9a-f]{40}$"
ALIAS = r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"


class Repo(BaseModel):
    model_config = ConfigDict(extra="forbid")
    github: str = Field(
        pattern=r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"
    )
    write_prefixes: list[str] = Field(default_factory=list)

    @model_validator(mode="after")
    def valid(self):
        if self.github.split("/")[1] in (".", ".."):
            raise ValueError("Invalid GitHub repository")
        for prefix in self.write_prefixes:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*/", prefix):
                raise ValueError("Write prefixes must be top-level branch namespaces")
        return self


class BrokerError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


class Backend:
    def __init__(self, state, repositories, upstream_token):
        self.state = Path(state).resolve()
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.repositories = {
            alias: Repo.model_validate(repo) for alias, repo in repositories.items()
        }
        if any(not re.fullmatch(ALIAS, alias) for alias in self.repositories):
            raise ValueError("Invalid repository alias")
        names = [repo.github.lower() for repo in self.repositories.values()]
        if len(names) != len(set(names)):
            raise ValueError("Each repository must have one alias")
        if len(upstream_token) < 32 or any(ord(c) < 33 for c in upstream_token):
            raise ValueError("Invalid upstream credential")
        self.upstream_token = upstream_token
        # One server process owns this state directory. Remove transfers left by
        # a crash; bare caches and lock files are retained.
        for transfer in self.state.glob("*.bundle"):
            transfer.unlink()

    def repo(self, alias):
        try:
            return self.repositories[alias]
        except KeyError:
            raise BrokerError(404, "Repository is not allowed") from None

    def upstream(self, repo):
        return "https://github.com/" + repo.github + ".git"

    def environment(self, authenticated=False):
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.state),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ALLOW_PROTOCOL": "https",
            "GIT_SSL_CAINFO": os.environ.get(
                "SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt"
            ),
        }
        config = [
            ("core.hooksPath", "/dev/null"),
            ("credential.helper", ""),
            ("http.followRedirects", "false"),
            ("protocol.allow", "never"),
            ("protocol.https.allow", "always"),
            ("maintenance.auto", "false"),
            ("gc.auto", "0"),
            ("fetch.fsckObjects", "true"),
            ("transfer.fsckObjects", "true"),
        ]
        # Only outbound GitHub commands receive the upstream credential.
        if authenticated:
            value = base64.b64encode(
                ("x-access-token:" + self.upstream_token).encode()
            ).decode()
            config.append(
                (
                    "http.https://github.com/.extraHeader",
                    "Authorization: Basic " + value,
                )
            )
        env["GIT_CONFIG_COUNT"] = str(len(config))
        for i, (key, value) in enumerate(config):
            env[f"GIT_CONFIG_KEY_{i}"] = key
            env[f"GIT_CONFIG_VALUE_{i}"] = value
        return env

    def git(
        self,
        cwd,
        *arguments,
        authenticated=False,
        status=503,
        message="Git operation failed",
        timeout=180,
    ):
        try:
            process = subprocess.Popen(
                ["git", *arguments],
                cwd=cwd,
                env=self.environment(authenticated),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                stdout, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                # Kill Git's HTTPS/pack helpers too, not only the parent process.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise BrokerError(status, message) from None
        except OSError:
            raise BrokerError(status, message) from None
        if process.returncode:
            raise BrokerError(status, message)
        return stdout.decode("utf-8", errors="replace").strip()

    @contextlib.contextmanager
    def locked(self, alias):
        repo = self.repo(alias)
        with (self.state / (alias + ".lock")).open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            cache = self.state / (alias + ".git")
            if not cache.exists():
                self.git(self.state, "init", "--bare", "--template=", str(cache))
            yield repo, cache

    def refresh(self, repo, cache):
        self.git(
            cache,
            "fetch",
            "--prune",
            "--no-tags",
            self.upstream(repo),
            "+refs/heads/*:refs/heads/*",
            "+refs/tags/*:refs/tags/*",
            authenticated=True,
        )

    def snapshot(self, alias, destination):
        with self.locked(alias) as (repo, cache):
            self.refresh(repo, cache)
            refs = self.git(
                cache, "for-each-ref", "--format=%(refname)", "refs/heads/"
            ).splitlines()
            if not refs:
                raise BrokerError(409, "Repository has no branches yet")
            head = self.git(
                cache,
                "ls-remote",
                "--symref",
                self.upstream(repo),
                "HEAD",
                authenticated=True,
            )
            default = next(
                (
                    line.split("\t")[0][5:]
                    for line in head.splitlines()
                    if line.startswith("ref: refs/heads/") and "\tHEAD" in line
                ),
                refs[0],
            )
            if default not in refs:
                default = refs[0]
            self.git(cache, "symbolic-ref", "HEAD", default)
            self.git(
                cache,
                "bundle",
                "create",
                str(destination),
                "--branches",
                "--tags",
                "HEAD",
            )

    def push(self, alias, branch, commit, expected, bundle, authorize=None):
        repo = self.repo(alias)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}", branch):
            raise BrokerError(422, "Invalid branch")
        if not branch.startswith(tuple(repo.write_prefixes)):
            raise BrokerError(403, "Branch is outside the allowed write namespaces")
        if not re.fullmatch(OID, commit) or not re.fullmatch(OID, expected):
            raise BrokerError(422, "SHA-1 commit IDs are required")
        if commit == "0" * 40:
            raise BrokerError(403, "Branch deletion is not permitted")
        ref = "refs/heads/" + branch
        with self.locked(alias) as (repo, cache):
            self.git(
                cache, "check-ref-format", ref, status=422, message="Invalid branch"
            )
            self.refresh(repo, cache)
            # for-each-ref can also match descendants; resolve the exact ref.
            refs = self.git(
                cache,
                "for-each-ref",
                "--format=%(refname) %(objectname)",
                "refs/heads/",
            )
            actual = dict(line.split(" ", 1) for line in refs.splitlines()).get(
                ref, "0" * 40
            )
            if actual != expected:
                raise BrokerError(409, "Remote branch changed; fetch before pushing")
            # Imported objects stay in a disposable bare repository. Rejected
            # uploads never accumulate in the trusted upstream cache.
            with tempfile.TemporaryDirectory(prefix="git-broker-upload-") as temporary:
                staging = Path(temporary)
                self.git(self.state, "init", "--bare", "--template=", str(staging))
                (staging / "objects/info/alternates").write_text(
                    str(cache / "objects") + "\n"
                )
                self.git(
                    staging,
                    "bundle",
                    "verify",
                    str(bundle),
                    status=422,
                    message="Invalid or incomplete Git bundle",
                )
                self.git(
                    staging,
                    "bundle",
                    "unbundle",
                    str(bundle),
                    status=422,
                    message="Invalid Git bundle",
                )
                kind = self.git(
                    staging,
                    "cat-file",
                    "-t",
                    commit,
                    status=422,
                    message="Commit is missing from bundle",
                )
                if kind != "commit":
                    raise BrokerError(422, "A commit is required")
                self.git(
                    staging,
                    "fsck",
                    "--strict",
                    "--no-dangling",
                    commit,
                    status=422,
                    message="Invalid commit graph",
                )
                if expected != "0" * 40:
                    self.git(
                        staging,
                        "merge-base",
                        "--is-ancestor",
                        expected,
                        commit,
                        status=409,
                        message="Non-fast-forward push is not permitted",
                    )
                if authorize is None:
                    raise BrokerError(403, "A push approval is required")
                deadline = authorize()
                if (
                    not isinstance(deadline, (int, float))
                    or not math.isfinite(deadline)
                    or deadline <= time.time()
                ):
                    raise BrokerError(403, "Push approval expired")
                lease = "" if expected == "0" * 40 else expected
                # An exact lease protects against upstream races; ancestry was checked above.
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise BrokerError(403, "Push approval expired")
                self.git(
                    staging,
                    "push",
                    "--porcelain",
                    "--force-with-lease=" + ref + ":" + lease,
                    self.upstream(repo),
                    commit + ":" + ref,
                    authenticated=True,
                    status=409,
                    message="Upstream rejected push; fetch and request a new approval",
                    timeout=min(180, remaining),
                )
                return {"branch": branch, "commit": commit}
