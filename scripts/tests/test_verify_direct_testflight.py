import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_direct_testflight as direct


def item(identifier, **values):
    return {"id": identifier, "attributes": values}


class FakeClient:
    def __init__(self):
        self.group = item("group", name="close door", isInternalGroup=True, hasAccessToAllBuilds=True)
        self.build = item("build", version="44", processingState="VALID", expired=False,
                          buildAudienceType="INTERNAL_ONLY")
        self.groups = [self.group]
        self.builds = [self.build]
        self.linked = [self.build]
        self.release = {"version": "0.0.6", "platform": "IOS"}
        self.beta_state = "IN_BETA_TESTING"

    def all(self, path):
        if path == "/v1/apps/123/betaGroups?limit=200":
            return self.groups
        if path == "/v1/apps/123/builds?limit=200":
            return self.builds
        if path == "/v1/betaGroups/group/builds?limit=200":
            return self.linked
        raise AssertionError(path)

    def get(self, path):
        if path == "/v1/builds/build/preReleaseVersion":
            return {"data": {"attributes": self.release}}
        if path == "/v1/builds/build":
            return {"data": self.build}
        if path == "/v1/builds/build/buildBetaDetail":
            return {"data": item("detail", internalBuildState=self.beta_state)}
        raise AssertionError(path)


class DirectTestFlightTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()

    def state(self):
        return direct.internal_build_state(self.client, "123", "close door", "0.0.6", "44")

    def test_only_valid_linked_internal_build_is_verified(self):
        self.assertTrue(self.state())
        self.client.linked = []
        with self.assertRaises(direct.Retry):
            self.state()
        self.client.linked = [self.client.build]
        self.client.beta_state = "READY_FOR_BETA_TESTING"
        with self.assertRaises(direct.Retry):
            self.state()

    def test_missing_and_wrong_version_remain_pending(self):
        self.client.builds = []
        with self.assertRaises(direct.Retry):
            self.state()
        self.client.builds = [self.client.build]
        self.client.release["version"] = "0.0.7"
        with self.assertRaises(direct.Retry):
            self.state()
        self.client.release = {"version": "0.0.6", "platform": "MAC_OS"}
        with self.assertRaises(direct.Retry):
            self.state()

    def test_ambiguous_or_external_group_is_rejected(self):
        self.client.groups = [self.client.group, self.client.group]
        with self.assertRaises(direct.Unknown):
            self.state()
        self.client.groups = [self.client.group]
        self.client.group["attributes"]["isInternalGroup"] = False
        with self.assertRaises(direct.Unknown):
            self.state()

    def test_missing_manual_group_assignment_fails_without_waiting(self):
        self.client.group["attributes"]["hasAccessToAllBuilds"] = False
        self.client.linked = []
        with self.assertRaises(direct.Unknown):
            self.state()
        self.client.linked = [self.client.build]
        self.assertTrue(self.state())

    def test_processing_is_pending_and_invalid_builds_fail(self):
        self.client.build["attributes"]["processingState"] = "PROCESSING"
        with self.assertRaises(direct.Retry):
            self.state()
        self.client.build["attributes"]["processingState"] = "FAILED"
        with self.assertRaises(direct.Unknown):
            self.state()
        self.client.build["attributes"].update(processingState="VALID", expired=True)
        with self.assertRaises(direct.Unknown):
            self.state()

    def test_noninternal_audience_and_unknown_beta_state_fail(self):
        self.client.build["attributes"]["buildAudienceType"] = "APP_STORE_ELIGIBLE"
        with self.assertRaises(direct.Unknown):
            self.state()
        self.client.build["attributes"]["buildAudienceType"] = "INTERNAL_ONLY"
        self.client.beta_state = "UNRECOGNIZED"
        with self.assertRaises(direct.Unknown):
            self.state()

    def test_ambiguous_builds_and_mismatched_detail_fail(self):
        self.client.builds = [self.client.build, self.client.build]
        with self.assertRaises(direct.Unknown):
            self.state()
        self.client.builds = [self.client.build]
        original = self.client.get
        def mismatched(path):
            return {"data": item("different", version="44")} if path == "/v1/builds/build" else original(path)
        self.client.get = mismatched
        with self.assertRaises(direct.Unknown):
            self.state()

    def test_cli_requires_credentials_and_rejects_unsafe_arguments(self):
        with patch.dict(os.environ, {"ASC_ISSUER_ID": "", "ASC_KEY_ID": "", "ASC_PRIVATE_KEY": ""}):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(direct.main(["--version", "0.0.6", "--build", "44"]), 2)
                with self.assertRaises(SystemExit):
                    direct.main(["--version", "0.0.6", "--build", "44;exit"])

    def test_cli_verifies_without_claiming_commit_provenance(self):
        env = {"ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key", "ASC_PRIVATE_KEY": "private"}
        output = io.StringIO()
        with patch.dict(os.environ, env), patch.object(direct, "Client", return_value=self.client):
            with contextlib.redirect_stdout(output):
                self.assertEqual(direct.main(["--version", "0.0.6", "--build", "44", "--app-id", "123"]), 0)
        self.assertIn("VERIFIED: iOS 0.0.6 (44)", output.getvalue())
        self.assertIn("provenance must be verified separately", output.getvalue())
        self.assertNotIn("private", output.getvalue())

    def test_waiting_for_processing_times_out_without_false_success(self):
        self.client.builds = []
        elapsed = [0.0]
        def sleep(seconds):
            elapsed[0] += seconds
        env = {"ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key", "ASC_PRIVATE_KEY": "private"}
        with patch.dict(os.environ, env), patch.object(direct, "Client", return_value=self.client), \
                patch.object(direct.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(direct.time, "sleep", side_effect=sleep), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(direct.main(["--version", "0.0.6", "--build", "44", "--app-id", "123",
                                          "--timeout-seconds", "2", "--poll-seconds", "1"]), 3)

    def test_workflow_only_dispatches_trusted_main_before_secrets(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/direct-testflight.yml").read_text()
        triggers = workflow.split("permissions:", 1)[0]
        self.assertIn("workflow_dispatch:", triggers)
        self.assertNotIn("pull_request", triggers)
        before_verify, _ = workflow.split("      - name: Check the selected build in TestFlight", 1)
        self.assertNotIn("secrets.", before_verify)
        body = before_verify.split("        run: |\n", 1)[1].split("      - uses:", 1)[0]
        guard = textwrap.dedent(body)
        for ref, expected in (("refs/heads/main", 0), ("refs/heads/untrusted", 1)):
            result = subprocess.run(["bash", "-c", guard], env=dict(os.environ, GITHUB_REF=ref),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()
