import subprocess
import time

from git_broker.backend import Backend


def git(cwd, *args):
    return subprocess.check_output(
        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", *args],
        cwd=cwd,
        text=True,
    ).strip()


class LocalBackend(Backend):
    """Local upstream injection exists only in tests, never in the production API."""

    def __init__(self, state, upstream):
        super().__init__(
            state,
            {
                "project": {"github": "owner/project", "write_prefixes": ["robot/"]},
                "readonly": {"github": "owner/readonly"},
            },
            "upstream-secret" * 4,
        )
        self.local = upstream

    def push(self, *args, authorize=None, **kwargs):
        # Direct policy tests use an explicitly fake trusted authorizer.
        return super().push(
            *args, authorize=authorize or (lambda: time.time() + 180), **kwargs
        )

    def upstream(self, repo):
        return str(self.local)

    def environment(self, authenticated=False):
        env = super().environment(authenticated)
        env["GIT_ALLOW_PROTOCOL"] = "file"
        env["GIT_CONFIG_COUNT"] = str(int(env["GIT_CONFIG_COUNT"]) + 1)
        i = int(env["GIT_CONFIG_COUNT"]) - 1
        env[f"GIT_CONFIG_KEY_{i}"] = "protocol.file.allow"
        env[f"GIT_CONFIG_VALUE_{i}"] = "always"
        return env


class ApprovedGate:
    def claim(self, rid, scope):
        return time.time() + 180

    def finish(self, rid, outcome):
        pass
