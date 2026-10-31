import unittest
from prepare_ui_test_host import select_device

class SimulatorSelectionTests(unittest.TestCase):
    def test_unrelated_device_specific_runtime_does_not_break_ios18_selection(self):
        device = {"udid": "old-test-device", "name": "Test Phone", "state": "Shutdown", "isAvailable": True}
        devices = {"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4": [],
                   "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [device]}
        self.assertEqual(select_device(devices, "Test Phone", (18, 5)), device)

    def test_hardware_suffix_is_not_an_os_version_component(self):
        device = {"udid": "new-test-device", "name": "Test Phone", "state": "Shutdown", "isAvailable": True}
        devices = {"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4": [device]}
        self.assertEqual(select_device(devices, "Test Phone", (27, 2)), device)

if __name__ == "__main__":
    unittest.main()
