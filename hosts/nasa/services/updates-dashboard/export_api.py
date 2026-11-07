import json
import tempfile

from updates_api import Settings, create_app

with tempfile.TemporaryDirectory() as directory:
    app = create_app(
        Settings(
            "http://localhost:5174",
            directory + "/auth.sqlite",
            "u" * 32,
            directory + "/reports",
        )
    )
    print(json.dumps(app.openapi(), indent=2))
