"""Validate the launch check's exit detection without an Apple SDK."""
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ios_launch", Path(__file__).parents[1] / "Tools/check-ios-launch.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)


class IOSLaunchChecks(unittest.TestCase):
    def testAcceptsTheExactLaunchedProcess(self):
        self.assertTrue(launch.is_running("123 S /tmp/Application/Lineup.app/Lineup", "/tmp/Application/Lineup.app/Lineup", 123))

    def testRegisteredButExitedAppDoesNotPass(self):
        self.assertFalse(launch.is_running("- 9 UIKitApplication:com.example.Lineup[abcd]", "/tmp/Application/Lineup.app/Lineup", 123))

    def testAnotherProcessOrAutomaticRestartDoesNotPass(self):
        record = "123 S /tmp/Other.app/Lineup\n456 S /tmp/Application/Lineup.app/Lineup"
        self.assertFalse(launch.is_running(record, "/tmp/Application/Lineup.app/Lineup", 123))

    def testStoppedOrZombieProcessDoesNotPass(self):
        for state in ["Z", "T", "X"]:
            self.assertFalse(launch.is_running(f"123 {state} /tmp/Lineup.app/Lineup", "/tmp/Lineup.app/Lineup", 123))

    def testExecutablePathsWithSpacesArePreserved(self):
        path = "/tmp/Simulator Data/Lineup.app/Lineup"
        self.assertTrue(launch.is_running("123 S " + path, path, 123))

    def testMissingProcessFailsWhileProbeErrorsRemainErrors(self):
        with patch.object(launch.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "ps", output="")):
            self.assertEqual(launch.process_record(123), "")
        with patch.object(launch.subprocess, "check_output", side_effect=subprocess.TimeoutExpired("ps", 15)):
            with self.assertRaises(subprocess.TimeoutExpired):
                launch.process_record(123)

    def testAnAliveProcessWithoutTheSportsScreenStillFails(self):
        with tempfile.TemporaryDirectory(prefix="lineup-launch-test-") as directory:
            with patch.object(launch, "simctl", return_value="com.example.Lineup: 123"), \
                 patch.object(launch, "process_record", return_value="123 S /tmp/Lineup.app/Lineup"), \
                 patch.object(launch.time, "sleep"), \
                 patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, stdout="Home screen")):
                with self.assertRaisesRegex(RuntimeError, "Sports screen was not visible"):
                    launch.check_launch("simulator", "com.example.Lineup", Path("/tmp/Lineup.app/Lineup"),
                                        Path("screen-checker"), Path(directory), "cached")
                self.assertEqual((Path(directory) / "cached-screen.txt").read_text(), "Home screen")

    def testAnExitedProcessCannotReachTheScreenPass(self):
        with tempfile.TemporaryDirectory(prefix="lineup-launch-test-") as directory:
            with patch.object(launch, "simctl", return_value="com.example.Lineup: 123"), \
                 patch.object(launch, "process_record", return_value=""), patch.object(launch.time, "sleep"), \
                 patch.object(launch.subprocess, "run") as screen:
                with self.assertRaisesRegex(RuntimeError, "exited after launch"):
                    launch.check_launch("simulator", "com.example.Lineup", Path("/tmp/Lineup.app/Lineup"),
                                        Path("screen-checker"), Path(directory), "cached")
                screen.assert_not_called()

    def testScreenshotFailureCannotHideAnExitedProcess(self):
        error = subprocess.CalledProcessError(22, "screenshot", output="No framebuffer")
        with tempfile.TemporaryDirectory(prefix="lineup-launch-test-") as directory:
            with patch.object(launch, "simctl", side_effect=["com.example.Lineup: 123", error]), \
                 patch.object(launch, "process_record", return_value=""), patch.object(launch.time, "sleep"):
                with self.assertRaisesRegex(RuntimeError, "exited after launch"):
                    launch.check_launch("simulator", "com.example.Lineup", Path("/tmp/Lineup.app/Lineup"),
                                        Path("screen-checker"), Path(directory), "cached")
                self.assertIn("No framebuffer", (Path(directory) / "cached-screenshot-error.txt").read_text())

    def testLiveProcessWithoutAScreenshotStillCannotPass(self):
        error = subprocess.CalledProcessError(22, "screenshot", output="No framebuffer")
        with tempfile.TemporaryDirectory(prefix="lineup-launch-test-") as directory:
            with patch.object(launch, "simctl", side_effect=["com.example.Lineup: 123", error]), \
                 patch.object(launch, "process_record", return_value="123 S /tmp/Lineup.app/Lineup"), \
                 patch.object(launch.time, "sleep"):
                with self.assertRaisesRegex(RuntimeError, "could not capture the Sports screen"):
                    launch.check_launch("simulator", "com.example.Lineup", Path("/tmp/Lineup.app/Lineup"),
                                        Path("screen-checker"), Path(directory), "cached")

    def testDebuggerReplayIsBoundedAndPreservesItsOutputOnTimeout(self):
        with tempfile.TemporaryDirectory(prefix="lineup-launch-test-") as directory:
            with patch.object(launch, "simctl", return_value="com.example.Lineup: 123"), \
                 patch.object(launch.subprocess, "run", side_effect=subprocess.TimeoutExpired("lldb", 35)) as debugger:
                launch.capture_abort_backtrace("simulator", "com.example.Lineup", Path(directory))
                self.assertEqual(debugger.call_args.kwargs["timeout"], 35)
                self.assertIn("__cxa_pure_virtual", " ".join(debugger.call_args.args[0]))
                self.assertIn("did not finish", (Path(directory) / "abort-backtrace.txt").read_text())

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
        self.assertIn("--screen-checker /tmp/lineup-launch-screen-check", jobs["startup"])
        self.assertIn("xcrun swiftc Tools/check-ios-launch-screen.swift", jobs["startup"])

    def testPublishingStillRequiresTestsStartupAndPackaging(self):
        needs = re.search(r"^    needs: \[([^\]]+)\]", self.workflow_jobs()["publish"], re.M)
        self.assertIsNotNone(needs)
        self.assertEqual({name.strip() for name in needs[1].split(",")}, {"test", "startup", "package"})


if __name__ == "__main__":
    unittest.main()
