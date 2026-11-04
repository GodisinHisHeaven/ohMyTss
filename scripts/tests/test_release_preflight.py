import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("release_preflight", Path(__file__).resolve().parents[1] / "release_preflight.py")
preflight = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preflight)


def check(name, identifier, run="123", status="completed", conclusion="success"):
    return {"id": identifier, "name": name, "status": status, "conclusion": conclusion,
            "app": {"slug": "github-actions"},
            "details_url": f"https://github.com/GodisinHisHeaven/ohMyTss/actions/runs/{run}/job/{identifier}"}


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.checks = [check("Quick checks", 1), check("iOS unit and UI tests", 2)]
        self.sha = "a" * 40
        self.run = {"head_sha": self.sha, "head_branch": "main", "event": "workflow_dispatch",
                    "path": ".github/workflows/pr-tests.yml", "status": "completed", "conclusion": "success"}

    def test_successful_checks_must_share_a_verified_main_run(self):
        self.assertEqual(preflight.latest_required_run([{"check_runs": self.checks}]), "123")
        preflight.verify_run(self.run, self.sha)
        self.checks[1]["details_url"] = self.checks[1]["details_url"].replace("/123/", "/456/")
        with self.assertRaises(ValueError):
            preflight.latest_required_run([{"check_runs": self.checks}])

    def test_later_pending_failed_or_skipped_check_cannot_reuse_old_success(self):
        for status, conclusion in (("queued", None), ("completed", "failure"), ("completed", "skipped")):
            with self.subTest(status=status, conclusion=conclusion):
                checks = self.checks + [check("Quick checks", 3, status=status, conclusion=conclusion)]
                with self.assertRaises(ValueError):
                    preflight.latest_required_run([{"check_runs": checks}])

    def test_missing_foreign_and_malformed_checks_are_rejected(self):
        for checks in ([], self.checks[:1], self.checks + [{"name": "Quick checks", "id": None,
                                                             "app": {"slug": "github-actions"}}]):
            with self.subTest(checks=checks), self.assertRaises(ValueError):
                preflight.latest_required_run([{"check_runs": checks}])
        self.checks[0]["details_url"] = "https://example.invalid/actions/runs/123/job/1"
        with self.assertRaises(ValueError):
            preflight.latest_required_run([{"check_runs": self.checks}])

    def test_wrong_sha_branch_workflow_or_unsuccessful_run_is_rejected(self):
        for field, value in (("head_sha", "b" * 40), ("head_branch", "feature"),
                             ("event", "pull_request"), ("path", ".github/workflows/other.yml"),
                             ("status", "in_progress"), ("conclusion", "failure")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                preflight.verify_run(dict(self.run, **{field: value}), self.sha)

    def test_credentials_validate_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Secrets.xcconfig"
            with self.assertRaises(ValueError):
                preflight.check_strava_config(path, {})
            path.write_text("STRAVA_CLIENT_ID = 123456\nSTRAVA_CLIENT_SECRET = valid-secret_123\n")
            preflight.check_strava_config(path, {})
            with self.assertRaises(ValueError):
                preflight.check_strava_config(path, {"STRAVA_CLIENT_SECRET": "SET_ME"})
            path.write_text("STRAVA_CLIENT_ID = SET_ME\nSTRAVA_CLIENT_SECRET = SET_ME\n")
            preflight.check_strava_config(path, {"STRAVA_CLIENT_ID": "123456", "STRAVA_CLIENT_SECRET": "override"})


if __name__ == "__main__":
    unittest.main()
