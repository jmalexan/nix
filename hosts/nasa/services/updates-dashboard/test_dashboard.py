import argparse
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).parent


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


reporter = load_module("dashboard_reporter", ROOT / "reporter.py")
server = load_module("dashboard_server", ROOT / "server.py")


class DashboardTests(unittest.TestCase):
    def test_home_assistant_release_post_is_optional(self):
        service = {
            "releaseNotes": {
                "repository": "home-assistant/core",
                "externalUrlPrefix": "https://www.home-assistant.io/blog/",
            }
        }
        item = {"availableTag": "2026.9.0"}
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps(
            {
                "body": (
                    "See https://www.home-assistant.io/blog/2026/09/02/"
                    "release-20269/ for details."
                )
            }
        ).encode()
        with mock.patch.object(reporter, "urlopen", return_value=response):
            self.assertEqual(
                reporter.external_release_notes_url(service, item),
                "https://www.home-assistant.io/blog/2026/09/02/release-20269/",
            )

        response.__enter__.return_value.read.return_value = b'{"body": "No post"}'
        with mock.patch.object(reporter, "urlopen", return_value=response):
            self.assertIsNone(reporter.external_release_notes_url(service, item))

    def test_release_note_tags_are_mapped(self):
        self.assertEqual(
            reporter.release_notes_url(
                {"releaseNotes": {"repository": "home-assistant/core"}},
                {"availableTag": "2026.9.0"},
            ),
            "https://github.com/home-assistant/core/releases/tag/2026.9.0",
        )
        self.assertEqual(
            reporter.release_notes_url(
                {
                    "releaseNotes": {
                        "repository": "blakeblackshear/frigate",
                        "tagPrefix": "v",
                        "stripSuffix": "-tensorrt",
                    }
                },
                {"availableTag": "0.17.2-tensorrt"},
            ),
            "https://github.com/blakeblackshear/frigate/releases/tag/v0.17.2",
        )

    def test_nix_changes_are_version_only(self):
        value = "\x1b[31;1mage: 1.0 → 1.1, 9.9 KiB\x1b[0m\nsource: 46.7 KiB"
        self.assertEqual(reporter.version_change_text(value), "age: 1.0 → 1.1")
        self.assertEqual(
            server.version_change_text("age: 1.0 → 1.1, -2.0 MiB\nsource: 2 KiB"),
            "age: 1.0 → 1.1",
        )

    def test_major_action_channel_selects_latest_major(self):
        refs = "\n".join(
            [
                "abc refs/tags/v4",
                "def refs/tags/v4.2.0",
                "ghi refs/tags/v5",
                "jkl refs/tags/v5.1.0",
            ]
        )
        with mock.patch.object(reporter, "run", return_value=refs):
            self.assertEqual(
                reporter.newest_action_ref("git", "owner/action", "v4"), "v5"
            )

    def test_container_pr_replaces_exact_image_and_digest(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            checkout = root / "checkout"
            state = root / "state"
            checkout.mkdir()
            state.mkdir()
            inventory = {
                "services": [
                    {
                        "name": "app",
                        "repository": "ghcr.io/example/app",
                        "currentTag": "1.0.0",
                        "currentDigest": "sha256:old",
                    }
                ]
            }
            inventory_path = root / "inventory.json"
            inventory_path.write_text(json.dumps(inventory))
            (state / "releases.json").write_text(
                json.dumps(
                    {
                        "items": [
                            {
                                "name": "app",
                                "status": "update",
                                "availableTag": "1.1.0",
                                "releaseNotesUrl": "https://example.invalid/release",
                            }
                        ]
                    }
                )
            )
            (state / "digests.json").write_text(json.dumps({"items": []}))
            module = checkout / "app.nix"
            module.write_text('image = "ghcr.io/example/app:1.0.0@sha256:old";\n')
            args = argparse.Namespace(
                inventory=str(inventory_path),
                state=str(state),
                skopeo="skopeo",
            )
            with mock.patch.object(
                reporter, "resolve_digest", return_value="sha256:new"
            ):
                title, body, target = reporter.prepare_container_pr(
                    args, checkout, "app"
                )
            self.assertEqual(title, "Update app to 1.1.0")
            self.assertEqual(target, "app")
            self.assertIn("Release notes", body)
            self.assertEqual(
                module.read_text(),
                'image = "ghcr.io/example/app:1.1.0@sha256:new";\n',
            )

    def test_empty_agenix_placeholder_disables_prs(self):
        with tempfile.TemporaryDirectory() as root:
            token = Path(root) / "token"
            token.write_text("")
            handler = object.__new__(server.DashboardHandler)
            handler.server = SimpleNamespace(token_path=token)
            self.assertFalse(handler.token_configured())
            token.write_text("github_pat_example")
            self.assertTrue(handler.token_configured())

    def test_closed_pull_request_state_is_refreshed_only_when_visible(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            state = root / "state"
            results = root / "results"
            state.mkdir()
            results.mkdir()
            token = root / "token"
            token.write_text("github_pat_example")
            inventory = root / "inventory.json"
            inventory.write_text(
                json.dumps(
                    {
                        "services": [
                            {
                                "name": "app",
                                "repository": "example/app",
                                "currentTag": "1.0.0",
                            }
                        ]
                    }
                )
            )
            (state / "releases.json").write_text(
                json.dumps({"items": [{"name": "app", "status": "update"}]})
            )
            result = results / "container--app.json"
            result.write_text(
                json.dumps(
                    {
                        "kind": "container",
                        "target": "app",
                        "status": "complete",
                        "url": "https://github.com/example/repo/pull/7",
                    }
                )
            )
            pull = {
                "html_url": "https://github.com/example/repo/pull/7",
                "number": 7,
                "state": "closed",
                "merged_at": None,
            }
            args = argparse.Namespace(
                token=str(token),
                github_repository="example/repo",
                results=str(results),
                state=str(state),
                inventory=str(inventory),
            )
            with mock.patch.object(reporter, "github_request", return_value=[pull]):
                reporter.pr_status(args)
            self.assertEqual(json.loads(result.read_text())["status"], "closed")

            stale = json.loads(result.read_text())
            stale["status"] = "open"
            result.write_text(json.dumps(stale))
            (state / "releases.json").write_text(
                json.dumps({"items": [{"name": "app", "status": "current"}]})
            )
            with mock.patch.object(reporter, "github_request") as request:
                reporter.pr_status(args)
            request.assert_not_called()

    def test_closed_branch_gets_a_fresh_retry_branch(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            checkout = root / "checkout"
            checkout.mkdir()
            (checkout / "changed.nix").write_text("changed")
            token = root / "token"
            token.write_text("github_pat_example")
            args = argparse.Namespace(
                git="git",
                token=str(token),
                github_repository="example/repo",
            )
            refs = []

            def fake_run(command, capture=False, cwd=None):
                if "diff" in command:
                    return "changed.nix"
                if "rev-parse" in command:
                    return "base-commit"
                return ""

            def fake_github(token_value, repository, path, method="GET", payload=None):
                if path.startswith("/pulls?"):
                    return [
                        {
                            "html_url": "https://github.com/example/repo/pull/7",
                            "number": 7,
                            "state": "closed",
                            "merged_at": None,
                        }
                    ]
                if path == "/git/commits/base-commit":
                    return {"tree": {"sha": "base-tree"}}
                if path == "/git/blobs":
                    return {"sha": "blob"}
                if path == "/git/trees":
                    return {"sha": "tree"}
                if path == "/git/commits":
                    return {"sha": "commit"}
                if path == "/git/refs":
                    refs.append(payload["ref"])
                    return {}
                if path == "/pulls":
                    return {
                        "html_url": "https://github.com/example/repo/pull/8",
                        "number": 8,
                        "state": "open",
                        "merged_at": None,
                    }
                raise AssertionError(path)

            with (
                mock.patch.object(reporter, "run", side_effect=fake_run),
                mock.patch.object(reporter, "github_request", side_effect=fake_github),
            ):
                result = reporter.publish_pull_request(
                    args, checkout, "Update app", "Body", "app"
                )
            self.assertEqual(result["status"], "open")
            self.assertIn("-retry-", refs[0])


if __name__ == "__main__":
    unittest.main()
