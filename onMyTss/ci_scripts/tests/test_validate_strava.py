import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "validate_strava_credentials.sh"


class ValidateStravaTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            "PATH": os.environ["PATH"],
            "CONFIGURATION": "Release",
            "STRAVA_CLIENT_ID": "123456",
            "STRAVA_CLIENT_SECRET": "test-secret_123",
        }

    def run_script(self):
        return subprocess.run(["/bin/sh", str(SCRIPT)], env=self.env, cwd="/",
                              capture_output=True, text=True)

    def test_valid_credentials_are_silent_in_both_configurations(self):
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                self.env["CONFIGURATION"] = configuration
                result = self.run_script()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout + result.stderr, "")

    def test_release_rejects_each_missing_credential(self):
        for key in ("STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET"):
            with self.subTest(key=key):
                value = self.env.pop(key)
                result = self.run_script()
                self.env[key] = value
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"error: {key}", result.stderr)
                self.assertNotIn(value, result.stdout + result.stderr)

    def test_debug_warns_for_both_missing_credentials(self):
        self.env["CONFIGURATION"] = "Debug"
        self.env.pop("STRAVA_CLIENT_ID")
        self.env.pop("STRAVA_CLIENT_SECRET")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: STRAVA_CLIENT_ID", result.stderr)
        self.assertIn("warning: STRAVA_CLIENT_SECRET", result.stderr)
        self.assertNotIn("error:", result.stderr)

    def test_release_rejects_placeholders_and_invalid_values_without_logging_them(self):
        for key, value in [
            ("STRAVA_CLIENT_ID", "<SET_ME>"),
            ("STRAVA_CLIENT_ID", "$(STRAVA_CLIENT_ID)"),
            ("STRAVA_CLIENT_ID", "not-numeric"),
            ("STRAVA_CLIENT_SECRET", "<SET_ME>"),
            ("STRAVA_CLIENT_SECRET", "SET_ME"),
            ("STRAVA_CLIENT_SECRET", "YOUR_STRAVA_CLIENT_SECRET"),
            ("STRAVA_CLIENT_SECRET", "$(STRAVA_CLIENT_SECRET)"),
            ("STRAVA_CLIENT_SECRET", "secret\nOTHER_SETTING = YES"),
            ("STRAVA_CLIENT_SECRET", "secret//comment"),
        ]:
            with self.subTest(key=key, value=value):
                previous = self.env[key]
                self.env[key] = value
                result = self.run_script()
                self.env[key] = previous
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"error: {key}", result.stderr)
                self.assertNotIn(value, result.stdout + result.stderr)

    def test_placeholder_checks_never_execute_commands(self):
        with tempfile.TemporaryDirectory(prefix="ohmytss validation ") as folder:
            root = Path(folder)
            marker = root / "executed"
            for name in ("STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET"):
                command = root / name
                command.write_text(f'#!/bin/sh\ntouch "{marker}"\n')
                command.chmod(0o700)
            self.env["PATH"] = str(root) + os.pathsep + self.env["PATH"]
            self.env["STRAVA_CLIENT_SECRET"] = "$(STRAVA_CLIENT_SECRET)"
            result = self.run_script()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertNotIn("not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
