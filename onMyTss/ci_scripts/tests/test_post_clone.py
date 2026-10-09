import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ci_post_clone.sh"


class PostCloneTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="onmytss ci ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "onMyTss/Config/Secrets.xcconfig"
        self.env = {
            "PATH": os.environ["PATH"],
            "CI_PRIMARY_REPOSITORY_PATH": str(self.root),
            "STRAVA_CLIENT_ID": "123456",
            "STRAVA_CLIENT_SECRET": "test-secret_123",
        }

    def run_script(self):
        return subprocess.run([str(SCRIPT)], env=self.env, cwd="/",
                              capture_output=True, text=True)

    def test_clean_checkout_receives_private_build_settings(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(),
                         "STRAVA_CLIENT_ID = 123456\nSTRAVA_CLIENT_SECRET = test-secret_123\n")
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        for key in ("STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET"):
            self.assertNotIn(self.env[key], result.stdout + result.stderr)

    def test_missing_credentials_fail_before_writing(self):
        for key in ("STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET"):
            with self.subTest(key=key):
                value = self.env.pop(key)
                result = self.run_script()
                self.env[key] = value
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)
                self.assertFalse(self.config.exists())

    def test_invalid_values_cannot_inject_xcconfig_settings(self):
        for key, value in [
            ("STRAVA_CLIENT_ID", "$(STRAVA_CLIENT_ID)"),
            ("STRAVA_CLIENT_SECRET", "<SET_ME>"),
            ("STRAVA_CLIENT_SECRET", "secret\nOTHER_SETTING = YES"),
            ("STRAVA_CLIENT_SECRET", "secret//comment"),
        ]:
            with self.subTest(key=key, value=value):
                previous = self.env[key]
                self.env[key] = value
                result = self.run_script()
                self.env[key] = previous
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(value, result.stdout + result.stderr)
                self.assertFalse(self.config.exists())

    def test_failure_preserves_existing_local_configuration(self):
        self.config.parent.mkdir(parents=True)
        self.config.write_text("existing local configuration\n")
        self.env.pop("STRAVA_CLIENT_SECRET")
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.config.read_text(), "existing local configuration\n")


if __name__ == "__main__":
    unittest.main()
