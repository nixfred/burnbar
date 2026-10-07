"""The 5-hour window's "is it hot" decision and its strip chip wording.

The logic lives in BarWidget.qml as plain JavaScript, so the cases themselves
are in test_session_heat.cjs and run under node, the way test_guidance.cjs
does. This wrapper is here so `python3 -m unittest discover -s tests` runs them
too instead of quietly leaving them to tests/test.sh.
"""
import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class SessionHeatTests(unittest.TestCase):
    def test_session_heat_cases_pass_under_node(self):
        run = subprocess.run(["node", "--test", "tests/test_session_heat.cjs"],
                             cwd=REPO, capture_output=True, text=True, timeout=120)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
