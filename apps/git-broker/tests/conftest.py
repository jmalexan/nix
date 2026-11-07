import pytest
from helpers import LocalBackend, git


@pytest.fixture
def repository(tmp_path):
    upstream = tmp_path / "upstream.git"
    git(tmp_path, "init", "--bare", "--initial-branch=main", str(upstream))
    local = tmp_path / "local"
    git(tmp_path, "clone", str(upstream), str(local))
    (local / "README").write_text("initial\n")
    git(local, "add", ".")
    git(local, "commit", "-m", "Initial")
    git(local, "push", "origin", "main")
    backend = LocalBackend(tmp_path / "broker", upstream)
    return backend, local, upstream
