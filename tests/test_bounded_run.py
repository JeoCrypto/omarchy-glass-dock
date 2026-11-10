"""BoundedRun.qml: every run is reported exactly once and leaves nothing behind.

The cases live in tests/bounded-run/shell.qml and run inside a throwaway
Quickshell instance, so this needs Quickshell and a Wayland session. Without
them the test is skipped.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = ['success', 'exit-code-and-errors', 'output-cap', 'input', 'time-limit',
            'failed-start', 'runs-again-after-failed-start', 'deadline-stops-stragglers',
            'normal-end-leaves-nothing', 'cancel', 'stops-a-stuck-supervisor',
            'refuses-overlap']


class BoundedRunTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('quickshell') and os.environ.get('WAYLAND_DISPLAY'),
                         'needs Quickshell and a Wayland session')
    def test_every_run_is_reported_once_and_cleaned_up(self):
        with tempfile.TemporaryDirectory() as d:
            shutil.copy(ROOT / 'BoundedRun.qml', d)
            shutil.copy(ROOT / 'tests/bounded-run/shell.qml', d)
            done = subprocess.run(['quickshell', '--no-color', '-p', d], capture_output=True,
                                  text=True, timeout=120)
        log = done.stdout + done.stderr
        results = dict(re.findall(r'CASE (\S+) (PASS|FAIL)', log))
        for name in EXPECTED:
            with self.subTest(case=name):
                line = next((l for l in log.splitlines() if f'CASE {name} ' in l), 'no result')
                self.assertEqual(results.get(name), 'PASS', line)
        self.assertNotIn('FAIL', results.values(), log)


if __name__ == '__main__':
    unittest.main()
