import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "deployment_plan", Path(__file__).with_name("deployment-plan.py")
)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class DeploymentPlanTests(unittest.TestCase):
    def test_nasa_change_does_not_wake_htpc(self):
        self.assertEqual(
            plan.select_hosts(
                {"nasa": "old", "htpc": "same"}, {"nasa": "new", "htpc": "same"}
            ),
            ["nasa"],
        )

    def test_no_changes_and_shared_changes(self):
        old = {"nasa": "a", "htpc": "b"}
        self.assertEqual(plan.select_hosts(old, old), [])
        self.assertEqual(
            plan.select_hosts(old, {"nasa": "c", "htpc": "d"}), ["nasa", "htpc"]
        )

    def test_manual_retry_can_target_unchanged_host(self):
        same = {"nasa": "a", "htpc": "b"}
        self.assertEqual(plan.select_hosts(same, same, "nasa"), ["nasa"])
        self.assertEqual(plan.select_hosts(same, same, "all"), ["nasa", "htpc"])
        with self.assertRaises(ValueError):
            plan.select_hosts(same, same, "other")

    def test_initial_deployment_includes_both_hosts(self):
        self.assertEqual(
            plan.select_hosts({}, {"nasa": "a", "htpc": "b"}), ["nasa", "htpc"]
        )


if __name__ == "__main__":
    unittest.main()
