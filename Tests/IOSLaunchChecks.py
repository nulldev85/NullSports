"""Validate the launch check's exit detection without an Apple SDK."""
import importlib.util
from pathlib import Path
import re
import unittest

spec = importlib.util.spec_from_file_location("ios_launch", Path(__file__).parents[1] / "Tools/check-ios-launch.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


class IOSLaunchChecks(unittest.TestCase):
    def testAcceptsTheExactLaunchedProcess(self):
        self.assertTrue(launch.is_running("PID Status Label\n123 0 UIKitApplication:com.example.Lineup[abcd]", "com.example.Lineup", 123))

    def testRegisteredButExitedAppDoesNotPass(self):
        self.assertFalse(launch.is_running("- 9 UIKitApplication:com.example.Lineup[abcd]", "com.example.Lineup", 123))

    def testAnotherProcessOrAutomaticRestartDoesNotPass(self):
        self.assertFalse(launch.is_running("123 0 com.example.Other\n456 0 UIKitApplication:com.example.Lineup[abcd]", "com.example.Lineup", 123))

    def workflow_jobs(self):
        workflow = (Path(__file__).parents[1] / ".github/workflows/build-ios.yml").read_text(encoding="utf-8")
        return dict(re.findall(r"(?ms)^  ([a-z][\w-]*):\s*\n(.*?)(?=^  [a-z][\w-]*:|\Z)", workflow.split("jobs:\n", 1)[1]))

    def testReleaseLaunchHasItsOwnJobAndUsesTheActiveSimulatorArchitecture(self):
        jobs = self.workflow_jobs()
        self.assertNotIn("-configuration Release", jobs["test"])
        self.assertNotIn("Tools/check-ios-launch.py", jobs["test"])
        self.assertIn("-configuration Release", jobs["startup"])
        self.assertIn("ONLY_ACTIVE_ARCH=YES", jobs["startup"])
        self.assertIn("Tools/check-ios-launch.py", jobs["startup"])

    def testPublishingStillRequiresTestsStartupAndPackaging(self):
        needs = re.search(r"^    needs: \[([^\]]+)\]", self.workflow_jobs()["publish"], re.M)
        self.assertIsNotNone(needs)
        self.assertEqual({name.strip() for name in needs[1].split(",")}, {"test", "startup", "package"})


if __name__ == "__main__":
    unittest.main()
