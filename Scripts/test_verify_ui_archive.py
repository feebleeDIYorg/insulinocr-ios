import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch
from verify_ui_archive import simulator_container


class ArchiveSimulatorReadinessTests(unittest.TestCase):
    target = "00000000-0000-4000-8000-000000000001"
    sibling = "00000000-0000-4000-8000-000000000002"

    def inventory(self, state="Shutdown", available=True):
        return json.dumps({"devices": {"synthetic-runtime": [
            {"udid": self.target, "state": state, "isAvailable": available},
            {"udid": self.sibling, "state": "Booted", "isAvailable": True}]}})

    def test_shutdown_target_is_resumed_without_touching_sibling_or_test_data(self):
        with patch("verify_ui_archive.subprocess.check_output", side_effect=[self.inventory(), "/synthetic/container\n"]), \
             patch("verify_ui_archive.subprocess.run") as run:
            self.assertEqual(simulator_container(self.target), Path("/synthetic/container"))
            self.assertEqual([call.args[0] for call in run.call_args_list], [
                ["xcrun", "simctl", "boot", self.target],
                ["xcrun", "simctl", "bootstatus", self.target, "-b"]])
            self.assertTrue(all(call.kwargs["check"] and call.kwargs["timeout"] <= 180 for call in run.call_args_list))

    def test_booted_or_booting_device_waits_without_second_boot(self):
        for state in ("Booted", "Booting"):
            with self.subTest(state=state), \
                 patch("verify_ui_archive.subprocess.check_output", side_effect=[self.inventory(state), "/synthetic/container"]), \
                 patch("verify_ui_archive.subprocess.run") as run:
                simulator_container(self.target)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0], ["xcrun", "simctl", "bootstatus", self.target, "-b"])

    def test_missing_or_unavailable_target_never_selects_booted_sibling(self):
        for inventory in (json.dumps({"devices": {"synthetic": []}}), self.inventory(available=False)):
            with self.subTest(inventory=inventory), \
                 patch("verify_ui_archive.subprocess.check_output", return_value=inventory), \
                 patch("verify_ui_archive.subprocess.run") as run, self.assertRaises(ValueError):
                simulator_container(self.target)
            run.assert_not_called()

    def test_boot_timeout_does_not_read_or_claim_valid_archive(self):
        with patch("verify_ui_archive.subprocess.check_output", return_value=self.inventory()) as output, \
             patch("verify_ui_archive.subprocess.run", side_effect=subprocess.TimeoutExpired("boot", 60)), \
             self.assertRaises(subprocess.TimeoutExpired):
            simulator_container(self.target)
        self.assertEqual(output.call_count, 1)
