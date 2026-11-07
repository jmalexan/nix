import json
import subprocess

import pytest
from fastapi.testclient import TestClient
from git_broker.api import create_app
from git_broker.backend import Backend, BrokerError, Repo
from helpers import git


def commit_bundle(local, tmp_path, branch="robot/work"):
    git(local, "checkout", "-B", branch)
    (local / "README").write_text("changed\n")
    git(local, "commit", "-am", "Change")
    commit = git(local, "rev-parse", "HEAD")
    bundle = tmp_path / "incoming.bundle"
    git(local, "bundle", "create", str(bundle), "refs/heads/" + branch)
    return commit, bundle


def test_snapshot_and_push_then_reject_non_fast_forward(repository, tmp_path):
    backend, local, upstream = repository
    snapshot = tmp_path / "snapshot.bundle"
    backend.snapshot("project", snapshot)
    clone = tmp_path / "clone"
    git(tmp_path, "clone", str(snapshot), str(clone))
    assert git(clone, "branch", "--show-current") == "main"
    assert (clone / "README").read_text() == "initial\n"
    commit, bundle = commit_bundle(local, tmp_path)
    assert (
        backend.push("project", "robot/work", commit, "0" * 40, bundle)["commit"]
        == commit
    )
    assert git(upstream, "rev-parse", "robot/work") == commit
    base = git(local, "rev-parse", "main")
    with pytest.raises(BrokerError) as error:
        backend.push("project", "robot/work", base, commit, bundle)
    assert error.value.status == 409
    assert git(upstream, "rev-parse", "robot/work") == commit


def test_api_requires_client_auth_and_rejects_other_repositories(repository, tmp_path):
    backend, _, _ = repository
    client = TestClient(create_app(backend, "c" * 32))
    assert client.get("/v1/repositories").status_code == 401
    assert client.get("/v1/repositories/project/snapshot").status_code == 401
    headers = {"Authorization": "Bearer " + "c" * 32}
    result = client.get("/v1/repositories", headers=headers)
    assert result.status_code == 200
    assert "upstream-secret" not in result.text
    assert (
        client.get("/v1/repositories/other/snapshot", headers=headers).status_code
        == 404
    )
    response = client.get("/v1/repositories/project/snapshot", headers=headers)
    assert (
        response.status_code == 200 and response.headers["cache-control"] == "no-store"
    )
    assert not list(backend.state.glob("*.bundle"))


@pytest.mark.parametrize(
    "branch",
    [
        "main",
        "refs/heads/robot/work",
        "robot/../main",
        "robot//work",
        "robot/work.lock",
        "robot/work\nmain",
    ],
)
def test_forbidden_refs_never_mutate_upstream(repository, tmp_path, branch):
    backend, local, upstream = repository
    before = git(upstream, "show-ref")
    commit, bundle = commit_bundle(local, tmp_path)
    with pytest.raises(BrokerError):
        backend.push("project", branch, commit, "0" * 40, bundle)
    assert git(upstream, "show-ref") == before


def test_readonly_stale_invalid_and_delete_pushes_fail_closed(repository, tmp_path):
    backend, local, upstream = repository
    commit, bundle = commit_bundle(local, tmp_path)
    for alias, branch, oid, expected, source in [
        ("readonly", "robot/work", commit, "0" * 40, bundle),
        ("project", "robot/work", commit, "a" * 40, bundle),
        ("project", "robot/work", "0" * 40, "0" * 40, bundle),
    ]:
        with pytest.raises(BrokerError):
            backend.push(alias, branch, oid, expected, source)
    bundle.write_bytes(b"not a git bundle")
    with pytest.raises(BrokerError) as error:
        backend.push("project", "robot/work", commit, "0" * 40, bundle)
    assert error.value.status == 422
    assert "robot/work" not in git(upstream, "show-ref")


def test_api_push_and_size_limits(repository, tmp_path):
    backend, local, upstream = repository
    commit, bundle = commit_bundle(local, tmp_path)
    client = TestClient(create_app(backend, "c" * 32))
    headers = {"Authorization": "Bearer " + "c" * 32}
    path = "/v1/repositories/project/push"
    params = {"branch": "robot/work", "commit": commit, "expected": "0" * 40}
    assert (
        client.post(path, params=params, content=bundle.read_bytes()).status_code == 401
    )
    assert (
        client.post(
            path, params=params, headers=headers, content=bundle.read_bytes()
        ).status_code
        == 200
    )
    assert git(upstream, "rev-parse", "robot/work") == commit
    limited = TestClient(create_app(backend, "c" * 32, max_bytes=10))
    assert (
        limited.post(
            path, params=params, headers=headers, content=bundle.read_bytes()
        ).status_code
        == 413
    )
    assert not list(backend.state.glob("*.bundle"))


def test_upstream_credentials_are_not_persisted_or_inherited(repository, monkeypatch):
    backend, _, _ = repository
    monkeypatch.setenv("GIT_TRACE", "1")
    monkeypatch.setenv("GITHUB_TOKEN", "unrelated-personal-token")
    env = Backend.environment(backend, authenticated=False)
    assert "GITHUB_TOKEN" not in env and "GIT_TRACE" not in env
    assert "upstream-secret" not in json.dumps(env)
    upstream = Backend.environment(backend, authenticated=True)
    assert any(
        k.startswith("GIT_CONFIG_VALUE_") and v.startswith("Authorization: Basic ")
        for k, v in upstream.items()
    )
    assert not list(backend.state.glob("*token*"))


@pytest.mark.parametrize(
    "repo", ["../nix", "owner/..", "https://github.com/o/r", "owner/repo.git/extra"]
)
def test_repository_urls_are_not_user_controlled(repo):
    with pytest.raises(ValueError):
        Repo(github=repo)


def test_push_lease_rejects_an_upstream_race(repository, tmp_path, monkeypatch):
    backend, local, upstream = repository
    old, bundle = commit_bundle(local, tmp_path)
    backend.push("project", "robot/work", old, "0" * 40, bundle)
    (local / "README").write_text("second change\n")
    git(local, "commit", "-am", "Second")
    new = git(local, "rev-parse", "HEAD")
    incoming = tmp_path / "second.bundle"
    git(local, "bundle", "create", str(incoming), "refs/heads/robot/work")
    rival = git(
        local,
        "commit-tree",
        "HEAD^{tree}",
        "-p",
        old,
        "-m",
        "Concurrent upstream commit",
    )
    original = backend.git

    def racing(cwd, *arguments, **kwargs):
        if arguments[0] == "push":
            git(local, "push", "origin", rival + ":refs/heads/robot/work")
        return original(cwd, *arguments, **kwargs)

    monkeypatch.setattr(backend, "git", racing)
    with pytest.raises(BrokerError) as error:
        backend.push("project", "robot/work", new, old, incoming)
    assert error.value.status == 409
    assert git(upstream, "rev-parse", "robot/work") == rival


def test_upstream_error_is_sanitized(repository, tmp_path, monkeypatch):
    backend, _, _ = repository

    def failure(*args, **kwargs):
        return subprocess.CompletedProcess(
            args[0], 1, b"", b"upstream-secret PRIVATE SOURCE"
        )

    monkeypatch.setattr(subprocess, "run", failure)
    client = TestClient(create_app(backend, "c" * 32))
    response = client.get(
        "/v1/repositories/project/snapshot",
        headers={"Authorization": "Bearer " + "c" * 32},
    )
    assert response.status_code == 503
    assert (
        "upstream-secret" not in response.text and "PRIVATE SOURCE" not in response.text
    )


def test_rejected_uploaded_objects_do_not_pollute_persistent_cache(
    repository, tmp_path
):
    backend, local, _ = repository
    accepted, bundle = commit_bundle(local, tmp_path)
    backend.push("project", "robot/work", accepted, "0" * 40, bundle)
    git(local, "checkout", "-B", "robot/divergent", "main")
    (local / "README").write_text("unapproved divergent history\n")
    git(local, "commit", "-am", "Divergent")
    rejected = git(local, "rev-parse", "HEAD")
    divergent = tmp_path / "divergent.bundle"
    git(local, "bundle", "create", str(divergent), "refs/heads/robot/divergent")
    with pytest.raises(BrokerError) as failure:
        backend.push("project", "robot/work", rejected, accepted, divergent)
    assert failure.value.status == 409
    with pytest.raises(BrokerError):
        backend.git(backend.state / "project.git", "cat-file", "-e", rejected)
