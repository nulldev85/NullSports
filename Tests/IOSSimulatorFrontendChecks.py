"""Cover the Xcode 27 layout that broke CI's standalone launch prerequisite."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ios_frontend", Path(__file__).parents[1] / "Tools/open-ios-simulator.py")
frontend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frontend)


class IOSSimulatorFrontendChecks(unittest.TestCase):
    def testXcode27WithoutSimulatorUsesDeviceHubAndTheExactDeviceURL(self):
        with tempfile.TemporaryDirectory(prefix="Xcode selected ") as directory:
            developer = Path(directory) / "Xcode 27.app/Contents/Developer"
            hub = developer.parent / "Applications/DeviceHub.app"
            hub.mkdir(parents=True)
            self.assertEqual(frontend.frontend_command(developer, "device-uuid"),
                             ["open", "-a", str(hub.resolve()), "devices://device/open?id=device-uuid"])

    def testOlderXcodeUsesItsOwnSimulatorAndOriginalDeviceArgument(self):
        with tempfile.TemporaryDirectory() as directory:
            developer = Path(directory) / "Xcode.app/Contents/Developer"
            simulator = developer / "Applications/Simulator.app"
            simulator.mkdir(parents=True)
            self.assertEqual(frontend.frontend_command(developer, "device-uuid"),
                             ["open", "-a", str(simulator.resolve()), "--args", "-CurrentDeviceUDID", "device-uuid"])

    def testAFrontendFromAnotherXcodeCannotSatisfyTheSelectedToolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Other Xcode.app/Contents/Applications/DeviceHub.app").mkdir(parents=True)
            with self.assertRaisesRegex(RuntimeError, "Selected Xcode has neither"):
                frontend.frontend_command(root / "Selected Xcode.app/Contents/Developer", "device-uuid")


if __name__ == "__main__":
    unittest.main()
