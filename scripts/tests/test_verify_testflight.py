import importlib.util
import io
import json
import os
import stat
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "verify_testflight.py"
SPEC = importlib.util.spec_from_file_location("verify_testflight", PATH)
verify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify)
SHA = "a" * 40


def item(identifier, **attrs):
    return {"id": identifier, "attributes": attrs}


def branch_response(identifier, name="refs/heads/main", kind="BRANCH"):
    return {"data": {"id": identifier, "relationships": {"sourceBranchOrTag": {
                "data": {"type": "scmGitReferences", "id": "ref"}}}},
            "included": [{"type": "scmGitReferences", "id": "ref",
                          "attributes": {"kind": kind, "canonicalName": name}}]}


class FakeClient:
    def __init__(self):
        self.singles = {
            "/v1/apps/app/ciProduct": {"data": item("product")},
            "/v1/ciBuildRuns/run?include=sourceBranchOrTag": branch_response("run"),
            "/v1/builds/build": {"data": item("build", processingState="VALID", expired=False, version="37")},
            "/v1/builds/build/buildBetaDetail": {"data": item("detail", internalBuildState="IN_BETA_TESTING")},
        }
        self.lists = {
            "/v1/apps/app/betaGroups?limit=200": [item("group", name="close door", isInternalGroup=True)],
            "/v1/ciProducts/product/buildRuns?sort=-number&limit=200": [
                item("run", number=37, sourceCommit={"commitSha": SHA}, isPullRequestBuild=False,
                     executionProgress="COMPLETE", completionStatus="SUCCEEDED")],
            "/v1/ciBuildRuns/run/actions?limit=200": [item(x, name="Test - iOS" if x == "TEST" else x, actionType=x, completionStatus="SUCCEEDED", executionProgress="COMPLETE", isRequiredToPass=True)
                                                        for x in ("BUILD", "TEST", "ARCHIVE")] + [
                item("post", name="TestFlight Internal Testing - iOS", actionType="TEST",
                     completionStatus="SUCCEEDED", executionProgress="COMPLETE", isRequiredToPass=True)],
            "/v1/ciBuildRuns/run/builds?limit=200": [item("build")],
            "/v1/betaGroups/group/builds?limit=200": [item("build")],
        }

    def get(self, path):
        return self.singles[path]

    def all(self, path):
        return self.lists[path]


class TestVerification(unittest.TestCase):
    def setUp(self):
        self.api = FakeClient()

    def check(self):
        return verify.verify_once(self.api, "app", "close door", SHA)

    def test_exact_success(self):
        self.assertEqual(self.check(), {"runNumber": 37, "buildVersion": "37", "commit": SHA})

    def test_older_commit_and_pr_runs_never_pass(self):
        run = self.api.lists["/v1/ciProducts/product/buildRuns?sort=-number&limit=200"][0]
        for attrs in ({"sourceCommit": {"commitSha": "b" * 40}}, {"isPullRequestBuild": True}, {"isPullRequestBuild": None}):
            with self.subTest(attrs=attrs):
                old = run["attributes"].copy()
                run["attributes"].update(attrs)
                with self.assertRaises(verify.Retry):
                    self.check()
                run["attributes"] = old

    def test_newer_failed_retry_does_not_hide_behind_older_success(self):
        runs = self.api.lists["/v1/ciProducts/product/buildRuns?sort=-number&limit=200"]
        runs.append(item("new", number=38, sourceCommit={"commitSha": SHA}, isPullRequestBuild=False,
                         executionProgress="COMPLETE", completionStatus="FAILED"))
        self.api.singles["/v1/ciBuildRuns/new?include=sourceBranchOrTag"] = branch_response("new")
        with self.assertRaises(verify.Failed):
            self.check()

    def test_run_must_be_linked_to_main_branch(self):
        key = "/v1/ciBuildRuns/run?include=sourceBranchOrTag"
        self.api.singles[key] = branch_response("run", "refs/heads/feature")
        with self.assertRaises(verify.Retry): self.check()
        self.api.singles[key] = branch_response("run", "refs/heads/main", "TAG")
        with self.assertRaises(verify.Retry): self.check()
        self.api.singles[key] = {"data": {"id": "run"}, "included": []}
        with self.assertRaises(verify.Unknown): self.check()
        self.api.singles[key] = branch_response("run")
        self.api.singles[key]["included"][0]["id"] = "different"
        with self.assertRaises(verify.Unknown): self.check()

    def test_newer_other_branch_run_cannot_replace_main_run(self):
        runs = self.api.lists["/v1/ciProducts/product/buildRuns?sort=-number&limit=200"]
        runs.append(item("new", number=38, sourceCommit={"commitSha": SHA}, isPullRequestBuild=False,
                         executionProgress="COMPLETE", completionStatus="FAILED"))
        self.api.singles["/v1/ciBuildRuns/new?include=sourceBranchOrTag"] = branch_response("new", "refs/heads/feature")
        self.assertEqual(self.check()["runNumber"], 37)

    def test_missing_skipped_or_nonrequired_test_never_pass(self):
        actions = self.api.lists["/v1/ciBuildRuns/run/actions?limit=200"]
        actions[1]["attributes"]["completionStatus"] = "SKIPPED"
        with self.assertRaises(verify.Failed): self.check()
        actions[1]["attributes"]["completionStatus"] = "SUCCEEDED"
        actions[1]["attributes"]["executionProgress"] = "RUNNING"
        with self.assertRaises(verify.Retry): self.check()
        actions[1]["attributes"]["executionProgress"] = "COMPLETE"
        actions[1]["attributes"]["isRequiredToPass"] = False
        with self.assertRaises(verify.Unknown): self.check()
        actions.pop(1)
        with self.assertRaises(verify.Unknown): self.check()

    def test_another_required_test_does_not_substitute_for_ios_action(self):
        actions = self.api.lists["/v1/ciBuildRuns/run/actions?limit=200"]
        actions.append(item("watch", name="Test - watchOS", actionType="TEST", completionStatus="SUCCEEDED",
                            executionProgress="COMPLETE", isRequiredToPass=True))
        actions[1]["attributes"]["isRequiredToPass"] = False
        with self.assertRaises(verify.Unknown): self.check()
        actions[1]["attributes"]["isRequiredToPass"] = True
        self.assertEqual(self.check()["runNumber"], 37)
        actions[1]["attributes"]["name"] = "different name"
        with self.assertRaises(verify.Unknown): self.check()
        actions[1]["attributes"]["name"] = "Test - iOS"
        actions.append(item("duplicate", name="Test - iOS", actionType="TEST", completionStatus="SUCCEEDED",
                            executionProgress="COMPLETE", isRequiredToPass=True))
        with self.assertRaises(verify.Unknown): self.check()

    def test_post_action_must_exist_uniquely_with_expected_type(self):
        actions = self.api.lists["/v1/ciBuildRuns/run/actions?limit=200"]
        post = actions.pop()
        with self.assertRaises(verify.Unknown): self.check()
        actions.append(post)
        post["attributes"]["actionType"] = "ARCHIVE"
        with self.assertRaises(verify.Unknown): self.check()
        post["attributes"]["actionType"] = "TEST"
        actions.append(item("duplicate", name="TestFlight Internal Testing - iOS", actionType="TEST",
                            completionStatus="SUCCEEDED", executionProgress="COMPLETE"))
        with self.assertRaises(verify.Unknown): self.check()

    def test_post_action_requires_completed_success(self):
        attrs = self.api.lists["/v1/ciBuildRuns/run/actions?limit=200"][-1]["attributes"]
        for progress, status in (("PENDING", None), ("RUNNING", None), ("RUNNING", "SUCCEEDED")):
            with self.subTest(progress=progress, status=status):
                attrs.update(executionProgress=progress, completionStatus=status)
                with self.assertRaises(verify.Retry): self.check()
        for status in ("FAILED", "ERRORED", "CANCELED", "SKIPPED"):
            with self.subTest(status=status):
                attrs.update(executionProgress="COMPLETE", completionStatus=status)
                with self.assertRaises(verify.Failed): self.check()
        attrs.update(executionProgress="COMPLETE", completionStatus="SUCCEEDED")
        self.assertEqual(self.check()["runNumber"], 37)

    def test_processing_group_and_internal_state_all_required(self):
        attrs = self.api.singles["/v1/builds/build"]["data"]["attributes"]
        attrs["processingState"] = "PROCESSING"
        with self.assertRaises(verify.Retry): self.check()
        attrs["processingState"] = "VALID"
        attrs["expired"] = True
        with self.assertRaises(verify.Failed): self.check()
        attrs["expired"] = False
        self.api.lists["/v1/betaGroups/group/builds?limit=200"] = []
        with self.assertRaises(verify.Retry): self.check()
        self.api.lists["/v1/betaGroups/group/builds?limit=200"] = [item("build")]
        self.api.singles["/v1/builds/build/buildBetaDetail"]["data"]["attributes"]["internalBuildState"] = "READY_FOR_BETA_TESTING"
        with self.assertRaises(verify.Retry): self.check()

    def test_group_must_be_unique_internal_and_for_app(self):
        groups = self.api.lists["/v1/apps/app/betaGroups?limit=200"]
        groups[0]["attributes"]["isInternalGroup"] = False
        with self.assertRaises(verify.Unknown): self.check()
        groups[0]["attributes"]["isInternalGroup"] = True
        groups.append(item("duplicate", name="close door", isInternalGroup=True))
        with self.assertRaises(verify.Unknown): self.check()

    def test_missing_credentials_short_sha_and_timeout_exit_nonzero(self):
        out = io.StringIO()
        with patch.dict(os.environ, {}, clear=True), redirect_stderr(out):
            self.assertEqual(verify.main(["--commit", SHA]), 2)
        env = {"ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key", "ASC_PRIVATE_KEY": "private", "ASC_APP_ID": "app", "ASC_BETA_GROUP": "group"}
        with patch.dict(os.environ, env, clear=True), redirect_stderr(out):
            self.assertEqual(verify.main(["--commit", "abc"]), 2)
            with patch.object(verify, "verify_once", side_effect=verify.Retry("pending")), \
                 patch.object(verify.time, "monotonic", side_effect=[0, 0, 2, 2]):
                self.assertEqual(verify.main(["--commit", SHA, "--timeout-seconds", "1"]), 3)
        self.assertNotIn("private", out.getvalue())

    def test_pagination_and_untrusted_url(self):
        client = verify.Client("issuer", "kid", "key", 1e30)
        pages = [{"data": [{"id": "one"}], "links": {"next": "/v1/page2"}}, {"data": [{"id": "two"}], "links": {}}]
        with patch.object(client, "get", side_effect=pages):
            self.assertEqual([x["id"] for x in client.all("/v1/page1")], ["one", "two"])
        with self.assertRaises(verify.Unknown):
            client.get("https://attacker.invalid/steal")

    def test_http_auth_failure_is_unknown_and_transient_errors_retry(self):
        client = verify.Client("issuer", "kid", "sensitive-private-key", 1e30)
        client.token = "sensitive-token"
        client.token_time = verify.time.monotonic()
        for code, category in ((401, verify.Unknown), (403, verify.Unknown), (429, verify.Retry), (503, verify.Retry)):
            error = verify.HTTPError("https://api.appstoreconnect.apple.com/v1/apps", code,
                                     "sensitive-token", {}, None)
            with self.subTest(code=code), patch.object(client.opener, "open", side_effect=error):
                with self.assertRaises(category) as raised:
                    client.get("/v1/apps")
                self.assertNotIn("sensitive", str(raised.exception))

    def test_real_es256_signature_and_no_key_file_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            key_path = Path(directory) / "key.pem"
            pub_path = Path(directory) / "pub.pem"
            subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key_path)], check=True, capture_output=True)
            subprocess.run(["openssl", "ec", "-in", str(key_path), "-pubout", "-out", str(pub_path)], check=True, capture_output=True)
            with patch.object(verify.tempfile, "tempdir", directory):
                token = verify.create_token("issuer", "key", key_path.read_text())
            header, payload, sig = token.split(".")
            decoded = verify.base64.urlsafe_b64decode(sig + "==")
            self.assertEqual(len(decoded), 64)
            def integer(raw):
                raw = raw.lstrip(b"\0") or b"\0"
                if raw[0] & 128: raw = b"\0" + raw
                return b"\x02" + bytes([len(raw)]) + raw
            body = integer(decoded[:32]) + integer(decoded[32:])
            signature_path = Path(directory) / "signature"
            signature_path.write_bytes(b"\x30" + bytes([len(body)]) + body)
            result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(pub_path), "-signature", str(signature_path)],
                                    input=(header + "." + payload).encode(), capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(list(Path(directory).glob("asc-key-*")))

    def test_signing_failure_cleans_private_file_and_uses_restricted_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            def fail_sign(args, **kwargs):
                self.assertEqual(stat.S_IMODE(os.stat(args[-1]).st_mode), 0o600)
                self.assertNotIn("ASC_PRIVATE_KEY", kwargs["env"])
                raise subprocess.CalledProcessError(1, args)
            with patch.object(verify.tempfile, "tempdir", directory), \
                 patch.dict(os.environ, {"ASC_PRIVATE_KEY": "private"}), \
                 patch.object(verify.subprocess, "run", side_effect=fail_sign):
                with self.assertRaises(verify.Unknown):
                    verify.create_token("issuer", "key", "private")
            self.assertFalse(list(Path(directory).glob("asc-key-*")))


if __name__ == "__main__":
    unittest.main()
