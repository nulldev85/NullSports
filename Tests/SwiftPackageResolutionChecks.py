"""Exercise dependency retries without downloading packages or running Xcode."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock


spec = importlib.util.spec_from_file_location(
    "package_resolution", Path(__file__).parents[1] / "Tools/resolve-swift-packages.py")
resolution = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolution)

URL = "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavutil.xcframework.zip"


def download_error(status=500):
    return (f"failed downloading '{URL}' which is required by binary target 'Libavutil': "
            f"badResponseStatusCode({status})")


def failure(errors, code=74):
    output = f"Resolve Package Graph\n{resolution.RESOLUTION_ERROR}\n  {errors}\n  fatalError\n"
    return subprocess.CompletedProcess([], code, output)


class SwiftPackageResolutionTests(unittest.TestCase):
    def resolve(self, results):
        run = Mock(side_effect=results)
        sleep = Mock()
        arguments = ["-project", "Lineup.xcodeproj", "-scheme", "LineupiOS",
                     "-derivedDataPath", "build tests with spaces"]
        with contextlib.redirect_stdout(io.StringIO()):
            code = resolution.resolve_packages(arguments, run=run, sleep=sleep)
        return code, run, sleep, ["xcodebuild", "-resolvePackageDependencies", *arguments]

    def testReported500ThenSuccessRetriesOnlyResolutionWithIdenticalArguments(self):
        # Includes Xcode's duplicate, concatenated final diagnostic from the run.
        error = failure(download_error())
        error.stdout += download_error() + "fatalError\n"
        code, run, sleep, command = self.resolve([
            error, subprocess.CompletedProcess([], 0, "Resolved source packages")])
        self.assertEqual(code, 0)
        self.assertEqual([call.args[0] for call in run.call_args_list], [command, command])
        sleep.assert_called_once_with(10)

    def testPersistentServerFailureStopsAfterThreeAttemptsAndPreservesFailure(self):
        code, run, sleep, _ = self.resolve([failure(download_error())] * 3)
        self.assertEqual(code, 74)
        self.assertEqual(run.call_count, 3)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [10, 20])

    def testSuccessfulResolutionDoesNotRetry(self):
        code, run, sleep, _ = self.resolve([subprocess.CompletedProcess([], 0, "Resolved")])
        self.assertEqual(code, 0)
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()

    def testPermanentFailuresNeverRetry(self):
        for error in [download_error(401), download_error(404), download_error(501),
                      "checksum of downloaded artifact does not match checksum specified by manifest",
                      "Dependencies could not be resolved because no versions match the requirement",
                      "invalid manifest: expected expression"]:
            with self.subTest(error=error):
                code, run, sleep, _ = self.resolve([failure(error, code=65)])
                self.assertEqual(code, 65)
                self.assertEqual(run.call_count, 1)
                sleep.assert_not_called()

    def testMixedTransientAndPermanentErrorsNeverRetry(self):
        code, run, sleep, _ = self.resolve([
            failure(download_error() + "\n  " + download_error(404))])
        self.assertEqual(code, 74)
        self.assertEqual(run.call_count, 1)
        sleep.assert_not_called()

    def testOnlyStructuredResolutionErrorsQualify(self):
        for text in [download_error(), "test fixture badResponseStatusCode(500)",
                     resolution.RESOLUTION_ERROR + "\n fatalError"]:
            with self.subTest(text=text):
                self.assertFalse(resolution.only_transient_download_errors(text))
        for status in [500, 502, 503, 504]:
            with self.subTest(status=status):
                self.assertTrue(resolution.only_transient_download_errors(
                    failure(download_error(status)).stdout))

    def testCommandStreamsBothOutputChannelsAndPreservesExitStatus(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = resolution.run_logged([sys.executable, "-c",
                "import sys; print('package output', flush=True); "
                "print('package error', file=sys.stderr, flush=True); sys.exit(74)"])
        self.assertEqual(result.returncode, 74)
        self.assertEqual(result.stdout, output.getvalue())
        self.assertIn("package output", result.stdout)
        self.assertIn("package error", result.stdout)


if __name__ == "__main__":
    unittest.main()
