#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile
import unittest

CHECK = pathlib.Path(__file__).with_name("check-test-preferences.py")


class TestPreferencesBoundary(unittest.TestCase):
    def check_source(self, source):
        with tempfile.TemporaryDirectory() as directory:
            pathlib.Path(directory, "Fixture.swift").write_text(source)
            return subprocess.run(
                ["python3", str(CHECK), directory], capture_output=True, text=True
            )

    def test_orion_uuid_suite_escape_is_rejected(self):
        result = self.check_source('let defaults = UserDefaults(suiteName: "feed-\\(UUID())")')
        self.assertEqual(result.returncode, 1)
        self.assertIn("TestPreferences()", result.stderr)

    def test_standard_defaults_escape_is_rejected(self):
        self.assertEqual(self.check_source("let defaults = UserDefaults.standard").returncode, 1)

    def test_documentation_does_not_access_preferences(self):
        self.assertEqual(self.check_source('// UserDefaults\nlet message = "UserDefaults"').returncode, 0)

    def test_memory_preferences_are_allowed(self):
        self.assertEqual(self.check_source("let defaults = TestPreferences()").returncode, 0)


if __name__ == "__main__":
    unittest.main()
