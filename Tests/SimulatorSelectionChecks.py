"""Pure selection checks; no Xcode installation or simulator required."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "simulator_selection", Path(__file__).parents[1] / "Tools/select-ios-simulator.py")
selection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(selection)


class SimulatorSelectionTests(unittest.TestCase):
    def catalog(self):
        return {
            "runtimes": [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0", "version": "27.0", "isAvailable": True},
            ],
            "devicetypes": [{"name": "iPhone 18 Pro", "identifier": "phone-type"}],
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 18 Pro", "udid": "old-device", "isAvailable": True}],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {"name": "iPad", "isAvailable": True},
                    {"name": "iPhone 18 Pro", "udid": "saved-device", "isAvailable": True}],
            },
        }

    def testNewestAvailableIOSConfigurationDoesNotReturnSavedDeviceID(self):
        self.assertEqual(selection.select_configuration(self.catalog()),
                         ("phone-type", "com.apple.CoreSimulator.SimRuntime.iOS-27-0"))

    def testUnavailableRuntimeAndDevicesAreExcluded(self):
        catalog = self.catalog()
        catalog["runtimes"][1]["isAvailable"] = False
        self.assertEqual(selection.select_configuration(catalog)[1],
                         "com.apple.CoreSimulator.SimRuntime.iOS-26-0")
        catalog["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-0"][0]["isAvailable"] = False
        with self.assertRaises(ValueError):
            selection.select_configuration(catalog)

    def testDeviceTypeIdentifierWorksWithARenamedDevice(self):
        catalog = self.catalog()
        phone = catalog["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][1]
        phone.update(name="iPhone custom CI name", deviceTypeIdentifier="explicit-type")
        self.assertEqual(selection.select_configuration(catalog)[0], "explicit-type")


if __name__ == "__main__":
    unittest.main()
