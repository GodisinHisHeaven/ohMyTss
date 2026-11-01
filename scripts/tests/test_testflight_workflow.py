"""Exercise the workflow's main-only, exact-commit selection guards."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/testflight-verification.yml").read_text()


def step_script(name):
    step = WORKFLOW.split("      - name: " + name + "\n", 1)[1]
    body = step.split("        run: |\n", 1)[1]
    lines = []
    for line in body.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line)
    return textwrap.dedent("\n".join(lines))


class TestTestFlightWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.repo = Path(cls.temp.name)
        def git(*args):
            return subprocess.run(["git", *args], cwd=cls.repo, check=True,
                                  text=True, capture_output=True).stdout.strip()
        git("init", "-q")
        git("config", "user.email", "workflow-test@example.invalid")
        git("config", "user.name", "Workflow Test")
        git("commit", "--allow-empty", "-qm", "previous")
        cls.previous_sha = git("rev-parse", "HEAD")
        git("commit", "--allow-empty", "-qm", "main")
        cls.main_sha = git("rev-parse", "HEAD")
        git("checkout", "-qb", "other")
        git("commit", "--allow-empty", "-qm", "not on main")
        cls.other_sha = git("rev-parse", "HEAD")
        git("checkout", "-q", cls.main_sha)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def execute(self, name, **overrides):
        output = self.repo / "github_output"
        output.write_text("")
        env = dict(os.environ, GITHUB_REF="refs/heads/main",
                   GITHUB_SHA=self.main_sha, REQUESTED_SHA="",
                   GITHUB_OUTPUT=str(output))
        env.update(overrides)
        result = subprocess.run(["bash", "-c", step_script(name)], cwd=self.repo,
                                env=env, capture_output=True, text=True)
        return result, output.read_text()

    def test_only_main_push_and_dispatch_have_secrets(self):
        triggers = WORKFLOW.split("permissions:", 1)[0]
        self.assertIn("  push:\n    branches: [main]", triggers)
        self.assertIn("  workflow_dispatch:", triggers)
        self.assertNotIn("pull_request", triggers)
        before_retry = WORKFLOW.split("      - name: Retry canceled Xcode Cloud run", 1)[0]
        self.assertNotIn("secrets.", before_retry)
        retry_step = WORKFLOW.split("      - name: Retry canceled Xcode Cloud run", 1)[1].split("      - name: Verify Xcode Cloud and TestFlight", 1)[0]
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.retry_canceled_cloud_run == true", retry_step)
        self.assertIn("default: false", triggers)
        self.assertIn("scripts/retry_canceled_cloud_run.py", retry_step)
        self.assertIn("cancel-in-progress: false", WORKFLOW)
        self.assertIn("id: cloud_retry", retry_step)
        self.assertIn("steps.cloud_retry.outputs.run_id", WORKFLOW)
        self.assertIn('args+=(--expected-run-id "$EXPECTED_RUN_ID")', WORKFLOW)
        self.assertNotIn("cancel-in-progress: true", WORKFLOW)
        self.assertIn("persist-credentials: false", WORKFLOW)
        self.assertNotIn("continue-on-error", WORKFLOW)
        for name in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY"):
            self.assertIn("secrets." + name, WORKFLOW)
        self.assertIn('--commit "$TARGET_SHA"', WORKFLOW)

    def test_main_ref_required(self):
        name = "Require the protected main branch"
        self.assertEqual(self.execute(name)[0].returncode, 0)
        self.assertNotEqual(self.execute(name, GITHUB_REF="refs/heads/other")[0].returncode, 0)

    def test_push_uses_exact_run_commit(self):
        result, output = self.execute("Select the commit to verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "sha=" + self.main_sha + "\n")

    def test_manual_retry_accepts_reachable_commit(self):
        result, output = self.execute("Select the commit to verify", REQUESTED_SHA=self.previous_sha)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "sha=" + self.previous_sha + "\n")

    def test_rejects_invalid_or_unreachable_requested_commit(self):
        for requested in ("abc", self.other_sha, "f" * 40):
            with self.subTest(requested=requested):
                result, _ = self.execute("Select the commit to verify", REQUESTED_SHA=requested)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_checkout_that_does_not_match_run(self):
        result, _ = self.execute("Select the commit to verify", GITHUB_SHA=self.other_sha)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
