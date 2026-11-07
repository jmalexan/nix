"""Disposable Updates browser-test server; never imported by production."""

import json
import shutil
import sys
import tempfile
from pathlib import Path

import uvicorn

repository = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(repository / "hosts/nasa/services/updates-dashboard"))
from updates_api import Settings, create_app  # noqa: E402

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    static = root / "static"
    static.mkdir()
    shared = repository / "apps/microapps/web/src/shared"
    source = repository / "hosts/nasa/services/updates-dashboard"
    for name in ("index.html", "app.js"):
        shutil.copy(source / name, static / name)
    for name in ("components.js", "component-shadow.css"):
        shutil.copy(shared / name, static / name)
    shutil.copy(repository / "apps/microapps/web/dist-auth/auth.js", static / "auth.js")
    (static / "styles.css").write_text(
        "\n".join(
            (shared / name).read_text() for name in ("tokens.css", "components.css")
        )
        + (source / "styles.css").read_text()
    )
    reports = root / "reports"
    reports.mkdir()
    (reports / "releases.json").write_text(
        json.dumps({"checkedAt": "2026-11-06T12:00:00Z", "items": []})
    )
    app = create_app(
        Settings(
            "http://localhost:5174",
            str(root / "auth.sqlite"),
            "u" * 32,
            str(reports),
            str(static),
            systemctl="/no-systemctl",
        )
    )
    uvicorn.run(app, host="127.0.0.1", port=5174)
