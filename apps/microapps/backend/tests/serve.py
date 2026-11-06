"""Disposable browser-test server. Never used by the production entry point."""

import tempfile
from pathlib import Path

import uvicorn
from microapps.api import Settings, create_app

with tempfile.TemporaryDirectory() as directory:
    app = create_app(
        Settings(
            "http://localhost:5173",
            directory + "/db",
            "r" * 32,
            "w" * 32,
            "e" * 32,
            static=str(Path(__file__).resolve().parents[2] / "web/dist"),
            gate_token="g" * 32,
        )
    )
    uvicorn.run(app, host="127.0.0.1", port=5173)
