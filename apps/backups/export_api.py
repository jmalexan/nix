import json
import tempfile

from api import Settings, create_app

with tempfile.TemporaryDirectory() as directory:
    app = create_app(
        Settings(
            "http://localhost:5175",
            directory + "/auth.sqlite",
            "b" * 32,
            directory + "/report.json",
        )
    )
    print(json.dumps(app.openapi(), indent=2))
