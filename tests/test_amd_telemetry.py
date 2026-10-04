"""AMD discovery must have a matching telemetry path, including iGPUs."""
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from test_local_scripts import ROOT, load_script


class AmdTelemetryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.status = load_script(ROOT / "bin/burnbar-local-status", "amd_status")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.device = self.root / "card1/device"
        self.device.mkdir(parents=True)
        (self.device / "vendor").write_text("0x1002\n")
        self.hw = self.device / "hwmon/hwmon2"
        self.hw.mkdir(parents=True)
        (self.hw / "name").write_text("amdgpu\n")

    def probe(self):
        with mock.patch.object(self.status, "local_ollama_cpu", return_value=2.5):
            return self.status.amd_telemetry(self.root)

    def test_available_counters_are_scaled_without_fake_vram(self):
        (self.device / "gpu_busy_percent").write_text("36\n")
        (self.hw / "temp1_input").write_text("51000\n")
        (self.hw / "freq1_input").write_text("1900000000\n")
        (self.hw / "power1_average").write_text("7500000\n")
        (self.device / "mem_info_vram_total").write_text("1073741824\n")
        fields, error = self.probe()
        self.assertEqual(error, "")
        self.assertEqual(fields["gpu"], 36)
        self.assertEqual(fields["cpu"], 2.5)
        self.assertEqual(fields["tempC"], 51)
        self.assertEqual(fields["clockMhz"], 1900)
        self.assertEqual(fields["powerW"], 7.5)
        self.assertNotIn("vramTotalMb", fields)
        self.assertNotIn("powerLimitW", fields)

    def test_missing_or_invalid_load_is_withheld_with_specific_reason(self):
        for raw in [None, "NaN", "-1", "unavailable"]:
            path = self.device / "gpu_busy_percent"
            if raw is not None:
                path.write_text(raw)
            fields, error = self.probe()
            self.assertNotIn("gpu", fields)
            self.assertEqual(error, "AMD GPU load counter unavailable")

    def test_load_is_bounded_and_nonfinite_optional_sensors_are_omitted(self):
        (self.device / "gpu_busy_percent").write_text("150")
        (self.hw / "temp1_input").write_text("inf")
        (self.hw / "power1_average").write_text("-1")
        fields, error = self.probe()
        self.assertEqual(error, "")
        self.assertEqual(fields["gpu"], 100)
        self.assertNotIn("tempC", fields)
        self.assertNotIn("powerW", fields)

    def test_amd_dispatch_never_uses_ssh_or_nvidia(self):
        with mock.patch.object(self.status, "is_local_host", return_value=True), \
             mock.patch.object(self.status, "amd_telemetry", return_value=({"gpu": 42}, "")) as amd, \
             mock.patch.object(self.status, "telemetry_ssh") as ssh, \
             mock.patch.object(self.status, "nvidia_telemetry") as nvidia:
            self.assertEqual(self.status.telemetry("localhost", {"backend": "amd"}), ({"gpu": 42}, ""))
            amd.assert_called_once()
            ssh.assert_not_called()
            nvidia.assert_not_called()

    def test_non_amd_hardware_is_not_claimed(self):
        (self.device / "vendor").write_text("0x8086\n")
        self.assertEqual(self.probe(), ({}, "AMD DRM device not found"))


if __name__ == "__main__":
    unittest.main()
