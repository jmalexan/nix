import copy
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
import zipfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "ci_reuse", Path(__file__).with_name("ci-reuse.py")
)
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)

MAIN, HEAD, MERGE, TREE = (character * 40 for character in "abcd")
REPO = "jmalexan/nix"


def zipped(proof, name="validation.json"):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr(name, json.dumps(proof))
    return data.getvalue()


class FakeGitHub:
    repo = REPO

    def __init__(self):
        self.pull = {
            "merged_at": "2026-11-06T00:00:00Z",
            "head": {"sha": HEAD, "repo": {"full_name": REPO}},
            "base": {"ref": "main", "repo": {"full_name": REPO}},
        }
        self.run = {
            "id": 123,
            "run_attempt": 2,
            "head_sha": HEAD,
            "head_repository": {"full_name": REPO},
            "event": "pull_request",
            "status": "completed",
            "conclusion": "success",
            "path": ".github/workflows/check.yml",
            "html_url": "https://github.com/jmalexan/nix/actions/runs/123",
        }
        self.artifact = {"id": 456, "name": "validated-tree-2", "expired": False}
        self.artifacts = [self.artifact]
        self.proof = {"commit": MERGE, "tree": TREE, "run_id": 123, "attempt": 2}
        self.head = {"tree": {"sha": TREE}}
        self.tested = {
            "tree": {"sha": TREE},
            "parents": [{"sha": MAIN}, {"sha": HEAD}],
        }

    def get(self, path, binary=False):
        return {
            f"commits/{MAIN}/pulls?per_page=100": [self.pull],
            "actions/workflows/check.yml/runs?event=pull_request&status=success&per_page=50": {
                "workflow_runs": [self.run]
            },
            f"git/commits/{HEAD}": self.head,
            "actions/runs/123/artifacts?per_page=100": {"artifacts": self.artifacts},
            "actions/artifacts/456/zip": zipped(self.proof),
            f"git/commits/{MERGE}": self.tested,
        }[path]


class ReuseTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()

    def lookup(self, api=None):
        return reuse.find_run(api or self.api, "check.yml", MAIN, TREE)

    def test_reuses_different_commit_with_identical_tested_tree(self):
        self.assertNotEqual(MAIN, MERGE)
        self.assertEqual(self.lookup(), self.api.run["html_url"])

    def test_rejects_unmerged_foreign_or_unrelated_pull(self):
        for field, value in [
            ("merged_at", None),
            ("head", {"sha": HEAD, "repo": {"full_name": "other/repo"}}),
            ("head", {"sha": HEAD, "repo": None}),
            ("base", {"ref": "other", "repo": {"full_name": REPO}}),
        ]:
            with self.subTest(field=field, value=value):
                api = copy.deepcopy(self.api)
                api.pull[field] = value
                self.assertIsNone(self.lookup(api))

    def test_rejects_wrong_workflow_event_status_head_or_repository(self):
        for field, value in [
            ("head_sha", "f" * 40),
            ("head_repository", {"full_name": "other/repo"}),
            ("event", "push"),
            ("status", "in_progress"),
            ("conclusion", "failure"),
            ("path", ".github/workflows/other.yml"),
        ]:
            with self.subTest(field=field):
                api = copy.deepcopy(self.api)
                api.run[field] = value
                self.assertIsNone(self.lookup(api))

    def test_rejects_changed_head_or_tested_tree(self):
        for field in ("head", "tested"):
            with self.subTest(field=field):
                api = copy.deepcopy(self.api)
                getattr(api, field)["tree"]["sha"] = "e" * 40
                self.assertIsNone(self.lookup(api))

    def test_rejects_missing_expired_or_previous_attempt_artifact(self):
        for field, value in [("name", "validated-tree-1"), ("expired", True)]:
            with self.subTest(field=field):
                api = copy.deepcopy(self.api)
                api.artifact[field] = value
                self.assertIsNone(self.lookup(api))

    def test_rejects_inconsistent_proof(self):
        for field, value in [
            ("run_id", 999),
            ("attempt", 1),
            ("tree", "e" * 40),
            ("commit", "not-a-sha"),
        ]:
            with self.subTest(field=field):
                api = copy.deepcopy(self.api)
                api.proof[field] = value
                self.assertIsNone(self.lookup(api))

    def test_requires_pr_head_as_tested_merge_parent(self):
        self.api.tested["parents"][1]["sha"] = "e" * 40
        self.assertIsNone(self.lookup())

    def test_requires_exactly_one_artifact(self):
        for artifacts in ([], [self.api.artifact, self.api.artifact]):
            with self.subTest(artifacts=artifacts):
                self.api.artifacts = artifacts
                self.assertIsNone(self.lookup())

    def test_artifact_is_read_without_extracting_paths(self):
        for name, proof in [
            ("../validation.json", {}),
            ("validation.json", {"oversized": "x" * 4096}),
        ]:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    reuse.manifest(zipped(proof, name))

    def test_missing_artifact_and_api_failure_fall_back(self):
        for error in (KeyError("missing artifact"), TimeoutError("offline")):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                summary = Path(directory) / "summary"
                with (
                    patch.dict(
                        os.environ,
                        {
                            "GITHUB_REF": "refs/heads/main",
                            "GITHUB_EVENT_NAME": "push",
                            "GITHUB_SHA": MAIN,
                            "GITHUB_REPOSITORY": REPO,
                            "GITHUB_OUTPUT": str(output),
                            "GITHUB_STEP_SUMMARY": str(summary),
                        },
                    ),
                    patch("sys.argv", ["ci-reuse.py", "--workflow", "check.yml"]),
                    patch.object(reuse, "git", return_value=MAIN),
                    patch.object(reuse, "find_run", side_effect=error),
                ):
                    reuse.main()
                self.assertEqual(output.read_text(), "reused=false\n")

    def test_pr_and_branch_dispatch_cannot_reuse(self):
        for ref, event in [
            ("refs/pull/1/merge", "pull_request"),
            ("refs/heads/topic", "workflow_dispatch"),
        ]:
            with self.subTest(event=event), tempfile.TemporaryDirectory() as directory:
                with (
                    patch.dict(
                        os.environ,
                        {
                            "GITHUB_REF": ref,
                            "GITHUB_EVENT_NAME": event,
                            "GITHUB_OUTPUT": f"{directory}/output",
                            "GITHUB_STEP_SUMMARY": f"{directory}/summary",
                        },
                    ),
                    patch("sys.argv", ["ci-reuse.py", "--workflow", "check.yml"]),
                    patch.object(reuse, "find_run") as lookup,
                ):
                    reuse.main()
                    lookup.assert_not_called()

    def test_record_rejects_wrong_checkout(self):
        with (
            patch.dict(os.environ, {"GITHUB_SHA": MAIN}),
            patch.object(reuse, "git", return_value=HEAD),
            self.assertRaises(ValueError),
        ):
            reuse.record("unused.json")

    def test_record_captures_actual_checkout_and_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "validation.json"
            with (
                patch.dict(
                    os.environ,
                    {
                        "GITHUB_SHA": MERGE,
                        "GITHUB_RUN_ID": "123",
                        "GITHUB_RUN_ATTEMPT": "2",
                    },
                ),
                patch.object(reuse, "git", side_effect=[MERGE, TREE]),
            ):
                reuse.record(path)
            self.assertEqual(json.loads(path.read_text()), self.api.proof)

    def test_manual_full_validation_disables_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            with (
                patch.dict(
                    os.environ,
                    {
                        "GITHUB_REF": "refs/heads/main",
                        "GITHUB_EVENT_NAME": "workflow_dispatch",
                        "CI_FORCE_VALIDATION": "true",
                        "GITHUB_OUTPUT": f"{directory}/output",
                        "GITHUB_STEP_SUMMARY": f"{directory}/summary",
                    },
                ),
                patch("sys.argv", ["ci-reuse.py", "--workflow", "check.yml"]),
                patch.object(reuse, "find_run") as lookup,
            ):
                reuse.main()
                lookup.assert_not_called()
            self.assertEqual(Path(f"{directory}/output").read_text(), "reused=false\n")

    def test_main_push_and_dispatch_publish_verified_result(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as directory:
                with (
                    patch.dict(
                        os.environ,
                        {
                            "GITHUB_REF": "refs/heads/main",
                            "GITHUB_EVENT_NAME": event,
                            "CI_FORCE_VALIDATION": "false",
                            "GITHUB_SHA": MAIN,
                            "GITHUB_OUTPUT": f"{directory}/output",
                            "GITHUB_STEP_SUMMARY": f"{directory}/summary",
                        },
                    ),
                    patch("sys.argv", ["ci-reuse.py", "--workflow", "check.yml"]),
                    patch.object(reuse, "git", side_effect=[MAIN, TREE]),
                    patch.object(reuse, "GitHub", return_value=self.api),
                ):
                    reuse.main()
                self.assertEqual(
                    Path(f"{directory}/output").read_text(), "reused=true\n"
                )
                self.assertIn(
                    self.api.run["html_url"], Path(f"{directory}/summary").read_text()
                )

    def test_artifact_redirect_does_not_forward_token(self):
        redirect = urllib.error.HTTPError(
            "https://api.github.com/artifact",
            302,
            "redirect",
            {"Location": "https://storage.example/archive"},
            None,
        )
        with (
            patch.dict(
                os.environ, {"GITHUB_REPOSITORY": REPO, "GH_TOKEN": "test-only"}
            ),
            patch.object(reuse.urllib.request, "build_opener") as opener,
            patch.object(reuse.urllib.request, "urlopen") as download,
        ):
            opener.return_value.open.side_effect = redirect
            download.return_value.__enter__.return_value.read.return_value = b"archive"
            self.assertEqual(reuse.GitHub().get("artifact", binary=True), b"archive")
            download.assert_called_once_with(
                "https://storage.example/archive", timeout=15
            )


if __name__ == "__main__":
    unittest.main()
