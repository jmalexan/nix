import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "deployment_plan", Path(__file__).with_name("deployment-plan.py")
)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)

BASE, HEAD = "a" * 40, "b" * 40
BASE_TREE, HEAD_TREE = "c" * 40, "d" * 40
CONTEXT = {"schema": 1, "planner": "code", "nix": "nix 1", "platform": "Linux-x86_64"}


def paths(nasa="a", htpc="b"):
    return {
        "nasa": f"/nix/store/{nasa * 32}-nasa.drv",
        "htpc": f"/nix/store/{htpc * 32}-htpc.drv",
    }


def record(tree, values=None, context=None):
    return {
        "tree": tree,
        "context": context or CONTEXT,
        "derivations": values or paths(),
    }


class DeploymentCacheTests(unittest.TestCase):
    def test_warm_plan_compares_correct_trees_without_evaluation(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, verified = Path(temp) / "cache.json", Path(temp) / "verified.json"
            cache.write_text(json.dumps(record(BASE_TREE)))
            expected = record(HEAD_TREE, paths(nasa="c"))
            verified.write_text(json.dumps(expected))
            with (
                patch.object(plan, "evaluation_context", return_value=CONTEXT),
                patch.object(plan, "source_tree", side_effect=[BASE_TREE, HEAD_TREE]),
                patch.object(plan, "derivations") as evaluate,
            ):
                self.assertEqual(
                    plan.plan(
                        Path(temp), BASE, HEAD, cache=cache, verified_head=verified
                    ),
                    ["nasa"],
                )
                evaluate.assert_not_called()
            self.assertEqual(json.loads(cache.read_text()), expected)

    def test_invalid_head_record_evaluates_instead_of_skipping_host(self):
        invalid = [
            "malformed json",
            json.dumps([]),
            json.dumps(record(BASE_TREE)),
            json.dumps(record(HEAD_TREE, context={**CONTEXT, "schema": 2})),
            json.dumps(record(HEAD_TREE, context={**CONTEXT, "nix": "different"})),
            json.dumps(record(HEAD_TREE, context={**CONTEXT, "planner": "different"})),
            json.dumps(record(HEAD_TREE, context={**CONTEXT, "platform": "different"})),
            json.dumps(record(HEAD_TREE, {"nasa": paths()["nasa"]})),
            json.dumps(record(HEAD_TREE, {**paths(), "other": paths()["nasa"]})),
            json.dumps(record(HEAD_TREE, {**paths(), "nasa": "/tmp/untrusted.drv"})),
            json.dumps(record(HEAD_TREE, {**paths(), "nasa": 1})),
        ]
        for value in invalid:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temp:
                cache, verified = (
                    Path(temp) / "cache.json",
                    Path(temp) / "verified.json",
                )
                cache.write_text(json.dumps(record(BASE_TREE)))
                verified.write_text(value)
                with (
                    patch.object(plan, "evaluation_context", return_value=CONTEXT),
                    patch.object(
                        plan, "source_tree", side_effect=[BASE_TREE, HEAD_TREE]
                    ),
                    patch.object(
                        plan, "derivations", return_value=paths(nasa="c")
                    ) as evaluate,
                ):
                    self.assertEqual(
                        plan.plan(
                            Path(temp), BASE, HEAD, cache=cache, verified_head=verified
                        ),
                        ["nasa"],
                    )
                    evaluate.assert_called_once()

    def test_cold_plan_evaluates_each_revision_once(self):
        with (
            patch.object(plan, "evaluation_context", return_value=CONTEXT),
            patch.object(plan, "source_tree", side_effect=[BASE_TREE, HEAD_TREE]),
            patch.object(
                plan, "derivations", side_effect=[paths(), paths(htpc="c")]
            ) as evaluate,
        ):
            self.assertEqual(plan.plan(Path.cwd(), BASE, HEAD), ["htpc"])
            self.assertEqual(
                [call.args[1] for call in evaluate.call_args_list], [BASE, HEAD]
            )

    def test_same_source_tree_is_evaluated_once_even_for_different_commits(self):
        with (
            patch.object(plan, "evaluation_context", return_value=CONTEXT),
            patch.object(plan, "source_tree", return_value=HEAD_TREE),
            patch.object(plan, "derivations", return_value=paths()) as evaluate,
        ):
            self.assertEqual(plan.plan(Path.cwd(), BASE, HEAD), [])
            evaluate.assert_called_once()

    def test_initial_and_forced_plans_only_evaluate_head(self):
        for base, force, hosts in [
            ("0" * 40, None, ["nasa", "htpc"]),
            (BASE, "nasa", ["nasa"]),
            (BASE, "all", ["nasa", "htpc"]),
        ]:
            with (
                self.subTest(force=force),
                patch.object(plan, "evaluation_context", return_value=CONTEXT),
                patch.object(plan, "source_tree", return_value=HEAD_TREE),
                patch.object(plan, "derivations", return_value=paths()) as evaluate,
            ):
                self.assertEqual(plan.plan(Path.cwd(), base, HEAD, force=force), hosts)
                self.assertEqual(evaluate.call_args.args[1], HEAD)
                evaluate.assert_called_once()

    def test_full_validation_ignores_both_valid_records(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, verified = Path(temp) / "cache.json", Path(temp) / "verified.json"
            cache.write_text(json.dumps(record(BASE_TREE)))
            verified.write_text(json.dumps(record(HEAD_TREE)))
            with (
                patch.object(plan, "evaluation_context", return_value=CONTEXT),
                patch.object(plan, "source_tree", side_effect=[BASE_TREE, HEAD_TREE]),
                patch.object(
                    plan, "derivations", side_effect=[paths(), paths(nasa="c")]
                ) as evaluate,
            ):
                self.assertEqual(
                    plan.plan(
                        Path(temp),
                        BASE,
                        HEAD,
                        cache=cache,
                        verified_head=verified,
                        fresh=True,
                    ),
                    ["nasa"],
                )
                self.assertEqual(evaluate.call_count, 2)

    def test_evaluation_failure_does_not_publish_new_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / "cache.json"
            original = json.dumps(record(BASE_TREE))
            cache.write_text(original)
            with (
                patch.object(plan, "evaluation_context", return_value=CONTEXT),
                patch.object(plan, "source_tree", side_effect=[BASE_TREE, HEAD_TREE]),
                patch.object(
                    plan, "derivations", side_effect=RuntimeError("evaluation failed")
                ),
                self.assertRaises(RuntimeError),
            ):
                plan.plan(Path(temp), BASE, HEAD, cache=cache)
            self.assertEqual(cache.read_text(), original)

    def test_cache_keys_include_tree_and_entire_context(self):
        key = plan.cache_key(BASE_TREE, CONTEXT)
        self.assertNotEqual(key, plan.cache_key(HEAD_TREE, CONTEXT))
        for name in CONTEXT:
            self.assertNotEqual(
                key, plan.cache_key(BASE_TREE, {**CONTEXT, name: "changed"})
            )

    def test_missing_and_oversized_records_are_misses(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "missing.json"
            self.assertIsNone(plan.read_record(path))
            path.write_text("x" * 4097)
            self.assertIsNone(plan.read_record(path))

    def test_evaluation_batches_both_hosts_into_one_nix_process(self):
        with (
            patch.object(plan.subprocess, "run") as run,
            patch.object(
                plan.subprocess, "check_output", return_value=json.dumps(paths())
            ) as evaluate,
        ):
            run.return_value.stdout = b"archive"
            self.assertEqual(
                plan.derivations(Path("/repo"), HEAD, Path("/source")), paths()
            )
            evaluate.assert_called_once()
            command = evaluate.call_args.args[0]
            self.assertIn("--json", command)
            self.assertIn("--no-write-lock-file", command)
            self.assertIn("path:/source#nixosConfigurations", command)
            self.assertIn(
                "configs.nasa.config.system.build.toplevel.drvPath", command[-1]
            )
            self.assertIn(
                "configs.htpc.config.system.build.toplevel.drvPath", command[-1]
            )


if __name__ == "__main__":
    unittest.main()
