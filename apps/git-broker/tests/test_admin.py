import os

import pytest
from git_broker.admin import provision


def test_private_credential_is_idempotent_and_not_printed(tmp_path, capsys):
    path = tmp_path / "credentials/client"
    provision(path)
    token = path.read_text()
    provision(path)
    assert path.read_text() == token
    assert len(token.strip()) >= 32
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700
    assert token.strip() not in capsys.readouterr().out


def test_unsafe_credential_is_not_overwritten(tmp_path):
    path = tmp_path / "credentials/client"
    provision(path)
    original = path.read_text()
    path.chmod(0o644)
    with pytest.raises(ValueError):
        provision(path)
    assert path.read_text() == original
    path.unlink()
    path.symlink_to(tmp_path / "target")
    with pytest.raises(OSError):
        provision(path)


def test_nonregular_credential_is_rejected_without_blocking(tmp_path):
    folder = tmp_path / "credentials"
    folder.mkdir(mode=0o700)
    os.mkfifo(folder / "client", 0o600)
    with pytest.raises(ValueError):
        provision(folder / "client")
