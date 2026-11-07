import concurrent.futures
import json
import os

import pytest
from notifications.bootstrap import provision


def paths(tmp_path):
    return (
        tmp_path / "notifications/services.json",
        tmp_path / "approvals/notifications",
    )


def run(registry, publisher):
    provision(registry, publisher, "https://approve.example.com")


def test_bootstrap_is_private_idempotent_and_consistent(tmp_path, capsys):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    token = publisher.read_text().strip()
    assert len(token) >= 32
    assert json.loads(registry.read_text())["approve"]["token"] == token
    assert registry.stat().st_mode & 0o777 == 0o600
    assert publisher.stat().st_mode & 0o777 == 0o600
    assert registry.parent.stat().st_mode & 0o777 == 0o700
    run(registry, publisher)
    assert publisher.read_text().strip() == token
    assert token not in capsys.readouterr().out


def test_partial_provisioning_recovers_without_rotation(tmp_path):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    token = publisher.read_text()
    registry.unlink()
    run(registry, publisher)
    assert publisher.read_text() == token
    publisher.unlink()
    run(registry, publisher)
    assert publisher.read_text() == token


def test_mismatch_is_rejected_without_overwrites(tmp_path):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    original = registry.read_bytes()
    publisher.write_text("different" * 8)
    with pytest.raises(ValueError, match="refusing to replace"):
        run(registry, publisher)
    assert registry.read_bytes() == original


def test_other_services_are_preserved_and_concurrent_bootstrap_is_safe(tmp_path):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    entries = json.loads(registry.read_text())
    other = {
        "token": "x" * 32,
        "origins": ["https://backup.example.com"],
        "recipients": ["owner"],
    }
    entries["backup"] = other
    registry.write_text(json.dumps(entries))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: run(registry, publisher), range(8)))
    assert json.loads(registry.read_text())["backup"] == other


def test_unsafe_files_and_symlinks_are_rejected(tmp_path):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    os.chmod(registry, 0o644)
    with pytest.raises(ValueError, match="private regular"):
        run(registry, publisher)
    os.chmod(registry, 0o600)
    publisher.unlink()
    publisher.symlink_to(registry)
    with pytest.raises(OSError):
        run(registry, publisher)


def test_explicit_short_origin_migration_keeps_credentials_and_other_services(tmp_path):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    token = publisher.read_text()
    provision(
        registry,
        publisher,
        "https://approve.example.com",
        additional_origin="https://approve",
    )
    expected = json.loads(registry.read_text())["approve"]
    assert expected["origins"] == ["https://approve.example.com", "https://approve"]
    assert publisher.read_text() == token
    provision(
        registry,
        publisher,
        "https://approve.example.com",
        additional_origin="https://approve",
    )
    assert json.loads(registry.read_text())["approve"] == expected
    with pytest.raises(ValueError, match="refusing to replace"):
        provision(
            registry,
            publisher,
            "https://approve.example.com",
            additional_origin="https://unrelated",
        )
    assert json.loads(registry.read_text())["approve"] == expected


def test_independent_backups_publisher_and_scope(tmp_path):
    registry, publisher = paths(tmp_path)
    run(registry, publisher)
    original = json.loads(registry.read_text())["approve"]
    backup_publisher = tmp_path / "backups/publisher"
    provision(
        registry,
        backup_publisher,
        "https://backups.example.com",
        service="backups",
        additional_origin="https://backups",
    )
    provision(
        registry,
        backup_publisher,
        "https://backups.example.com",
        service="backups",
        additional_origin="https://backups",
    )
    entries = json.loads(registry.read_text())
    assert entries["approve"] == original
    assert entries["backups"]["token"] != original["token"]
    assert entries["backups"]["origins"] == [
        "https://backups.example.com",
        "https://backups",
    ]
    assert entries["backups"]["recipients"] == ["owner"]
    with pytest.raises(ValueError, match="refusing to replace"):
        provision(
            registry, backup_publisher, "https://other.example.com", service="backups"
        )
    assert json.loads(registry.read_text()) == entries
