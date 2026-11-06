import json
import tempfile
from pathlib import Path

from microapps.api import Settings, create_app

with tempfile.TemporaryDirectory() as directory:
    app = create_app(
        Settings(
            "http://localhost:5173", directory + "/db", "r" * 32, "w" * 32, "e" * 32
        )
    )
    Path(__file__).with_name("openapi.json").write_text(
        json.dumps(app.openapi(), indent=2) + "\n"
    )
