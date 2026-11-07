import importlib.util
import json
import os
import shutil
import subprocess
import sys
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
CONTEXT = {"schema": 2, "planner": "code", "nix": "nix 1", "platform": "Linux-x86_64"}


def paths(nasa="a", htpc="b"):
    return {
        "nasa": f"/nix/store/{nasa * 32}-nasa.drv",
        "htpc": f"/nix/store/{htpc * 32}-htpc.drv",
    }


def check_paths(**changes):
    return {
        name: changes.get(name, f"/nix/store/{'d' * 32}-{name}.drv")
        for name in plan.VM_CHECKS
    }


def evaluation(nasa="a", htpc="b", checks=None):
    return {"hosts": paths(nasa, htpc), "checks": checks or check_paths()}


def record(tree, values=None, context=None):
    return {
        "tree": tree,
        "context": context or CONTEXT,
        "derivations": values or paths(),
        "checks": check_paths(),
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
            json.dumps(record(HEAD_TREE, context={**CONTEXT, "schema": 3})),
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
                        plan, "derivations", return_value=evaluation(nasa="c")
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
                plan, "derivations", side_effect=[evaluation(), evaluation(htpc="c")]
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
            patch.object(plan, "derivations", return_value=evaluation()) as evaluate,
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
                patch.object(
                    plan, "derivations", return_value=evaluation()
                ) as evaluate,
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
                    plan,
                    "derivations",
                    side_effect=[evaluation(), evaluation(nasa="c")],
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

    def test_evaluation_batches_hosts_and_check_paths_into_one_nix_process(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "head"
            source.mkdir()
            with (
                patch.object(plan.subprocess, "run") as run,
                patch.object(
                    plan.subprocess,
                    "check_output",
                    return_value=json.dumps(evaluation()),
                ) as evaluate,
            ):
                run.return_value.stdout = b"archive"
                self.assertEqual(
                    plan.derivations(Path("/repo"), HEAD, source), evaluation()
                )
                evaluate.assert_called_once()
                self.assertIn(
                    f"path:{source.parent}/head-validation#lib.ciDerivations",
                    evaluate.call_args.args[0],
                )
            wrapper = (source.parent / "head-validation" / "flake.nix").read_text()
            self.assertIn("configs.nasa.config.system.build.toplevel.drvPath", wrapper)
            self.assertIn("configs.htpc.config.system.build.toplevel.drvPath", wrapper)
            self.assertIn("flake.checks.x86_64-linux", wrapper)

    def test_validation_cannot_be_skipped_by_cached_head_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            cache, verified = Path(temp) / "cache.json", Path(temp) / "verified.json"
            cache.write_text(json.dumps(record(BASE_TREE)))
            verified.write_text(json.dumps(record(HEAD_TREE)))
            with (
                patch.object(plan, "evaluation_context", return_value=CONTEXT),
                patch.object(plan, "source_tree", side_effect=[HEAD_TREE, BASE_TREE]),
                patch.object(
                    plan, "derivations", return_value=evaluation(nasa="c")
                ) as evaluate,
            ):
                self.assertEqual(
                    plan.plan(
                        Path(temp),
                        BASE,
                        HEAD,
                        cache=cache,
                        verified_head=verified,
                        validate=True,
                    ),
                    ["nasa"],
                )
                evaluate.assert_called_once()
                self.assertEqual(evaluate.call_args.args[1], HEAD)
                self.assertEqual(evaluate.call_args.kwargs, {"validate": True})

    def test_identical_trees_are_validated_once(self):
        with (
            patch.object(plan, "evaluation_context", return_value=CONTEXT),
            patch.object(plan, "source_tree", return_value=HEAD_TREE),
            patch.object(plan, "derivations", return_value=evaluation()) as evaluate,
        ):
            self.assertEqual(plan.plan(Path.cwd(), BASE, HEAD, validate=True), [])
            evaluate.assert_called_once()

    def test_flake_validation_failure_cannot_publish_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "head"
            source.mkdir()
            with (
                patch.object(plan.subprocess, "run") as run,
                patch.object(plan.subprocess, "check_output") as evaluate,
            ):
                run.return_value.stdout = b"archive"
                run.side_effect = [
                    run.return_value,
                    run.return_value,
                    RuntimeError("invalid flake"),
                ]
                with self.assertRaisesRegex(RuntimeError, "invalid flake"):
                    plan.derivations(Path("/repo"), HEAD, source, validate=True)
                evaluate.assert_not_called()
            wrapper = (Path(temp) / "head-validation" / "flake.nix").read_text()
            self.assertIn(
                'builtins.removeAttrs repo.outputs [ "nixosConfigurations" ]', wrapper
            )
            self.assertIn(f"path:{source}", wrapper)


class VMSelectionTests(unittest.TestCase):
    def select(
        self,
        cached=True,
        changes=None,
        fresh=False,
        enabled=True,
        force=None,
        invalid=None,
    ):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / "record.json"
            if cached:
                cache.write_text(
                    json.dumps(invalid if invalid is not None else record(BASE_TREE))
                )
            selected = []
            with (
                patch.object(plan, "evaluation_context", return_value=CONTEXT),
                patch.object(
                    plan,
                    "source_tree",
                    side_effect=[BASE_TREE, HEAD_TREE] if not force else [HEAD_TREE],
                ),
                patch.object(
                    plan,
                    "derivations",
                    side_effect=(
                        [evaluation(checks=check_paths(**(changes or {})))]
                        if cached and invalid is None and not fresh or force
                        else [
                            evaluation(),
                            evaluation(checks=check_paths(**(changes or {}))),
                        ]
                    ),
                ),
            ):
                plan.plan(
                    Path(temp),
                    BASE,
                    HEAD,
                    cache=cache,
                    fresh=fresh,
                    force=force,
                    select_vm=enabled,
                    vm_selection=selected,
                )
            return selected

    def test_base_predating_new_vm_check_runs_all(self):
        older_checks = check_paths()
        del older_checks[plan.VM_CHECKS[-1]]
        for cached in (False, True):
            with self.subTest(cached=cached), tempfile.TemporaryDirectory() as temp:
                cache = Path(temp) / "record.json"
                if cached:
                    cache.write_text(
                        json.dumps({**record(BASE_TREE), "checks": older_checks})
                    )
                selected = []
                with (
                    patch.object(plan, "evaluation_context", return_value=CONTEXT),
                    patch.object(
                        plan, "source_tree", side_effect=[HEAD_TREE, BASE_TREE]
                    ),
                    patch.object(
                        plan,
                        "derivations",
                        side_effect=[evaluation(), evaluation(checks=older_checks)],
                    ),
                ):
                    plan.plan(
                        Path(temp),
                        BASE,
                        HEAD,
                        cache=cache,
                        validate=True,
                        select_vm=True,
                        vm_selection=selected,
                    )
                self.assertEqual(selected, list(plan.VM_CHECKS))

    def test_head_must_define_every_required_vm_check(self):
        incomplete = check_paths()
        del incomplete[plan.VM_CHECKS[-1]]
        with (
            tempfile.TemporaryDirectory() as temp,
            patch.object(plan, "evaluation_context", return_value=CONTEXT),
            patch.object(plan, "source_tree", return_value=HEAD_TREE),
            patch.object(
                plan, "derivations", return_value=evaluation(checks=incomplete)
            ),
            self.assertRaisesRegex(ValueError, "invalid host/check derivations"),
        ):
            plan.plan(Path(temp), BASE, HEAD, validate=True)

    def test_unchanged_vms_skip_with_successful_base_record(self):
        self.assertEqual(self.select(), [])

    def test_only_changed_fixture_runs(self):
        for name in plan.VM_CHECKS:
            with self.subTest(name=name):
                self.assertEqual(
                    self.select(changes={name: f"/nix/store/{'f' * 32}-changed.drv"}),
                    [name],
                )

    def test_cold_base_runs_all_even_when_fresh_evaluation_matches(self):
        self.assertEqual(self.select(cached=False), list(plan.VM_CHECKS))

    def test_invalid_or_incompatible_base_runs_all(self):
        for value in [
            {},
            record(HEAD_TREE),
            record(BASE_TREE, context={**CONTEXT, "schema": 1}),
            {**record(BASE_TREE), "checks": {}},
            {
                **record(BASE_TREE),
                "checks": {**check_paths(), "agent-guest": "/tmp/bad.drv"},
            },
        ]:
            with self.subTest(record=value):
                self.assertEqual(self.select(invalid=value), list(plan.VM_CHECKS))

    def test_full_validation_and_non_pr_runs_all(self):
        self.assertEqual(self.select(fresh=True), list(plan.VM_CHECKS))
        self.assertEqual(self.select(enabled=False), list(plan.VM_CHECKS))
        self.assertEqual(self.select(force="nasa"), list(plan.VM_CHECKS))


class CheckRunnerTests(unittest.TestCase):
    def run_checks(self, selection=None):
        with tempfile.TemporaryDirectory() as temp:
            fake_nix = Path(temp) / "nix"
            fake_nix.write_text(
                f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n"
            )
            fake_nix.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{temp}:{Path(sys.executable).parent}:{os.environ.get('PATH', '')}",
            }
            env.pop("CI_VM_CHECKS", None)
            if selection is not None:
                env["CI_VM_CHECKS"] = selection
            return subprocess.run(
                ["bash", str(Path(plan.__file__).with_name("ci-checks.sh"))],
                env=env,
                text=True,
                capture_output=True,
            )

    def test_local_default_runs_all_checks(self):
        result = self.run_checks()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout.splitlines()[-1])
        for name in plan.VM_CHECKS:
            self.assertIn(f".#checks.x86_64-linux.{name}", args)

    def test_empty_vm_selection_still_runs_all_light_checks(self):
        result = self.run_checks("[]")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout.splitlines()[-1]),
            ["build", "--no-link"]
            + [
                f".#checks.x86_64-linux.{name}"
                for name in [
                    "lint",
                    "microapps",
                    "microapps-web",
                    "notifications",
                    "git-broker",
                    "backups",
                ]
            ],
        )

    def test_selects_one_vm_without_losing_light_checks(self):
        result = self.run_checks('["agent-guest"]')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(len(args), 9)
        self.assertIn(".#checks.x86_64-linux.agent-guest", args)
        self.assertNotIn(".#checks.x86_64-linux.agent-network", args)

    def test_invalid_selection_fails_before_nix_runs(self):
        for value in [
            "bad json",
            "null",
            "1",
            '"agent-guest"',
            '["other"]',
            '["agent-guest", "agent-guest"]',
        ]:
            with self.subTest(value=value):
                result = self.run_checks(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


@unittest.skipUnless(shutil.which("nix"), "requires the Nix CLI")
class DeploymentValidationTests(unittest.TestCase):
    def validate_fixture(self, hosts, checks='mk "check"'):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            (repo / "flake.nix").write_text(
                "{ outputs = { self }: let mk = name: builtins.derivation { "
                'inherit name; system = "x86_64-linux"; builder = "/bin/sh"; }; '
                "in { nixosConfigurations = { " + hosts + " }; "
                "checks.x86_64-linux = { example = "
                + checks
                + "; "
                + " ".join(f'{name} = mk "{name}";' for name in plan.VM_CHECKS)
                + " }; }; }"
            )
            subprocess.run(["git", "init", "-q", temp], check=True)
            subprocess.run(["git", "-C", temp, "add", "."], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    temp,
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                check=True,
            )
            head = subprocess.check_output(
                ["git", "-C", temp, "rev-parse", "HEAD"], text=True
            ).strip()
            cache = repo / "result.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(plan.__file__).resolve()),
                    "--base",
                    "0" * 40,
                    "--head",
                    head,
                    "--validate",
                    "--cache",
                    str(cache),
                ],
                cwd=repo,
                env={
                    key: value
                    for key, value in os.environ.items()
                    if key not in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY")
                },
                capture_output=True,
                text=True,
            )
            return result, cache.exists()

    def test_real_flake_validates_both_hosts(self):
        result, recorded = self.validate_fixture(
            'nasa.config.system.build.toplevel = mk "nasa"; '
            'htpc.config.system.build.toplevel = mk "htpc";'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ["nasa", "htpc"])
        self.assertTrue(recorded)

    def test_invalid_non_host_output_fails_without_record(self):
        result, recorded = self.validate_fixture(
            'nasa.config.system.build.toplevel = mk "nasa"; '
            'htpc.config.system.build.toplevel = mk "htpc";',
            checks="1",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)

    def test_unexpected_host_cannot_escape_validation(self):
        result, recorded = self.validate_fixture(
            'nasa.config.system.build.toplevel = mk "nasa"; '
            'htpc.config.system.build.toplevel = mk "htpc"; extra = {};'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)

    def test_missing_host_fails_without_record(self):
        result, recorded = self.validate_fixture(
            'nasa.config.system.build.toplevel = mk "nasa";'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)

    def test_drv_path_without_derivation_type_is_rejected(self):
        result, recorded = self.validate_fixture(
            'nasa.config.system.build.toplevel = { type = "invalid"; '
            f'drvPath = "{paths()["nasa"]}"; }}; '
            'htpc.config.system.build.toplevel = mk "htpc";'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)

    def test_host_validation_does_not_allow_import_from_derivation(self):
        result, recorded = self.validate_fixture(
            "nasa.config.system.build.toplevel = "
            'builtins.seq (builtins.readFile (mk "ifd")) (mk "nasa"); '
            'htpc.config.system.build.toplevel = mk "htpc";'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("allow-import-from-derivation", result.stderr)
        self.assertFalse(recorded)


if __name__ == "__main__":
    unittest.main()
