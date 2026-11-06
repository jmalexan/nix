import json
import tempfile

from notifications.api import Settings, create_app

with tempfile.TemporaryDirectory() as directory:
    app = create_app(
        Settings("https://notifications.example.com", directory + "/state.sqlite", {})
    )
    print(json.dumps(app.openapi(), indent=2, sort_keys=True))
