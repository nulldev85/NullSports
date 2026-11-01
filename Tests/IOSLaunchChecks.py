"""Validate the launch check's exit detection without an Apple SDK."""
import importlib.util
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
