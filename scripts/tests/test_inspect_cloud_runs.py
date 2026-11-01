"""Read-only Cloud inspection tests using local fakes and temporary Git repos."""
import copy
from http.client import BadStatusLine
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import inspect_cloud_runs as inspect
from test_retry_canceled_cloud_run import (SHA, OLD, NEW, PRODUCT, REPO, REF, WORKFLOW,
                                           FakeClient, resource, run)

ACTION_IDS = ["aaaaaaaa-1111-4111-8111-111111111111", "bbbbbbbb-2222-4222-8222-222222222222",
              "cccccccc-3333-4333-8333-333333333333", "dddddddd-4444-4444-8444-444444444444"]


def action(ident, kind, name, progress="COMPLETE", status="SUCCEEDED", required=True):
    return resource("ciBuildActions", ident, {"actionType": kind, "name": name,
                    "executionProgress": progress, "completionStatus": status,
                    "isRequiredToPass": required})


class FakeInspect(FakeClient):
    def __init__(self):
        super().__init__()
        self.old = run(OLD, 1, "CANCELED")
        self.new = run(NEW, 2, "SUCCEEDED")
        self.product_runs = [self.old, self.new]
        self.actions = [action(ACTION_IDS[0], "BUILD", "secret build name"),
                        action(ACTION_IDS[1], "TEST", "Test - iOS"),
                        action(ACTION_IDS[2], "ARCHIVE", "secret archive name"),
                        action(ACTION_IDS[3], "TEST", "TestFlight Internal Testing - iOS")]
        self.calls = []
        self.page_overrides = {}

    def get(self, url):
        self.calls.append(url)
        parts = urlsplit(url)
        path = parts.path + ("?" + parts.query if parts.query else "") if parts.scheme else url
        if path in self.page_overrides:
            value = self.page_overrides[path]
            if isinstance(value, Exception): raise value
            return copy.deepcopy(value)
        if path == "/v1/ciProducts/" + PRODUCT + "/buildRuns?sort=-number&limit=200":
            return {"data": copy.deepcopy(self.product_runs), "links": {}}
        if path == "/v1/scmRepositories/" + REPO + "/gitReferences?limit=200":
            return {"data": [copy.deepcopy(self.ref)], "links": {}}
        if path in ("/v1/ciBuildRuns/" + OLD + "/actions?limit=200",
                    "/v1/ciBuildRuns/" + NEW + "/actions?limit=200"):
            return {"data": copy.deepcopy(self.actions), "links": {}}
        return copy.deepcopy(super().get(path))


class TestCloudInspection(unittest.TestCase):
    def setUp(self):
        self.api = FakeInspect()

    def test_all_matching_main_runs_and_safe_action_labels(self):
        rows, ignored = inspect.inspect(self.api, "123", SHA)
        self.assertEqual([r["id"] for r in rows], [NEW, OLD])
        self.assertEqual(ignored, 0)
        self.assertEqual(rows[0]["completion"], "SUCCEEDED")
        self.assertEqual(rows[1]["completion"], "CANCELED")
        self.assertEqual([a["kind"] for a in rows[0]["actions"]],
                         ["BUILD", "TEST_IOS", "ARCHIVE", "TESTFLIGHT_POST_ACTION"])
        text = str(rows)
        self.assertNotIn("secret", text)
        self.assertNotIn("private-token-sentinel", text)
        self.assertEqual(self.api.requests, [])

    def test_empty_list_is_only_not_visible_and_never_writes(self):
        self.api.product_runs = []
        rows, ignored = inspect.inspect(self.api, "123", SHA)
        self.assertEqual((rows, ignored), ([], 0))
        self.assertEqual(self.api.requests, [])
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
               "GITHUB_REPOSITORY": inspect.REPOSITORY, "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": SHA,
               "REQUESTED_SHA": "", "TARGET_SHA": SHA, "ASC_APP_ID": "123", "GH_READ_TOKEN": "token",
               "ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key", "ASC_PRIVATE_KEY": "secret"}
        output = io.StringIO()
        with patch.dict(os.environ, env, clear=True), patch.object(inspect, "Client", return_value=self.api), \
                patch.object(inspect, "github_branch", return_value=SHA), redirect_stdout(output):
            inspect.lookup()
        self.assertIn("visibility may be delayed", output.getvalue())
        self.assertIn("Never repeat a POST", output.getvalue())
        self.assertNotIn("secret", output.getvalue())
        self.assertEqual(self.api.requests, [])

    def test_running_run_and_pending_action_do_not_appear_successful(self):
        self.api.new["attributes"].update(executionProgress="RUNNING", completionStatus=None)
        self.api.product_runs = [copy.deepcopy(self.api.new)]
        self.api.actions = [action(ACTION_IDS[0], "BUILD", "hidden-name", "PENDING", None)]
        rows, ignored = inspect.inspect(self.api, "123", SHA)
        self.assertEqual(ignored, 0)
        self.assertEqual(rows[0]["progress"], "RUNNING")
        self.assertEqual(rows[0]["completion"], "NOT_FINISHED")
        self.assertEqual(rows[0]["actions"][0]["progress"], "PENDING")
        self.assertEqual(rows[0]["actions"][0]["completion"], "NOT_FINISHED")
        self.assertNotIn("hidden-name", str(rows))
        self.assertEqual(self.api.requests, [])

    def test_target_pr_and_other_branch_are_not_mistaken_for_main(self):
        self.api.old["attributes"]["isPullRequestBuild"] = True
        self.api.product_runs = [self.api.old, self.api.new]
        rows, ignored = inspect.inspect(self.api, "123", SHA)
        self.assertEqual([r["id"] for r in rows], [NEW])
        self.assertEqual(ignored, 1)
        self.api = FakeInspect()
        self.api.ref["attributes"].update(canonicalName="refs/heads/sensitive-branch")
        rows, ignored = inspect.inspect(self.api, "123", SHA)
        self.assertEqual(rows, [])
        self.assertEqual(ignored, 2)
        self.assertEqual(self.api.requests, [])
        refs_path = "/v1/scmRepositories/" + REPO + "/gitReferences?limit=200"
        self.api.page_overrides[refs_path] = {"data": [], "links": {}}
        with self.assertRaises(inspect.Unknown):
            inspect.inspect(self.api, "123", SHA)

    def test_unknown_sha_duplicate_or_malformed_list_fails_closed(self):
        invalid = [None, {"type": "ciBuildRuns", "id": OLD, "attributes": {"sourceCommit": None}},
                   {"type": "wrong", "id": NEW, "attributes": {}},
                   {"type": "ciBuildRuns", "id": "-" * 36, "attributes": {}}]
        for item in invalid:
            with self.subTest(item=type(item).__name__):
                self.api = FakeInspect()
                self.api.product_runs.append(item)
                with self.assertRaises(inspect.Unknown): inspect.inspect(self.api, "123", SHA)
                self.assertEqual(self.api.requests, [])
        self.api = FakeInspect()
        self.api.product_runs.append(copy.deepcopy(self.api.old))
        with self.assertRaises(inspect.Unknown): inspect.inspect(self.api, "123", SHA)

    def test_malformed_relationships_or_status_never_give_conclusion(self):
        changes = [
            lambda c: c.old["attributes"]["sourceCommit"].update(commitSha="c" * 40),
            lambda c: c.old["attributes"].update(isPullRequestBuild=None),
            lambda c: c.old["relationships"]["product"]["data"].update(id=REPO),
            lambda c: c.repo["attributes"].update(httpCloneUrl="https://evil.invalid/secret"),
            lambda c: c.ref["attributes"].update(isDeleted=None),
            lambda c: c.ref["attributes"].update(isDeleted=True),
            lambda c: c.ref["attributes"].update(kind="FUTURE_UNKNOWN_KIND"),
            lambda c: c.ref["attributes"].update(kind="TAG", canonicalName="refs/heads/main"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/tags/main"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/main\n"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/a..b"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/a//b"),
            lambda c: c.old["attributes"].update(number=True),
            lambda c: c.old["attributes"].update(executionProgress="secret\n::warning::"),
            lambda c: c.old["attributes"].update(completionStatus=None),
            lambda c: c.actions[0]["attributes"].update(actionType="secret"),
            lambda c: c.actions[0]["attributes"].update(isRequiredToPass=1),
        ]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeInspect()
                # Keep the list immutable when changing a detail object.
                self.api.product_runs = copy.deepcopy(self.api.product_runs)
                change(self.api)
                with self.assertRaises(inspect.Unknown) as error: inspect.inspect(self.api, "123", SHA)
                self.assertNotIn("secret", str(error.exception))
                self.assertEqual(self.api.requests, [])

    def test_pagination_follows_all_pages_and_rejects_unsafe_next(self):
        path = "/v1/ciProducts/" + PRODUCT + "/buildRuns"
        first = path + "?sort=-number&limit=200"
        second = path + "?sort=-number&limit=200&cursor=next"
        self.api.page_overrides[first] = {"data": [self.api.old], "links": {"next": "?sort=-number&limit=200&cursor=next"}}
        self.api.page_overrides[second] = {"data": [self.api.new], "links": {}}
        rows, ignored = inspect.inspect(self.api, "123", SHA)
        self.assertEqual([r["id"] for r in rows], [NEW, OLD])
        self.assertEqual(ignored, 0)
        for next_url in ("https://evil.invalid/secret", "http://api.appstoreconnect.apple.com" + path,
                         "https://api.appstoreconnect.apple.com/v1/other?cursor=secret",
                         "?cursor=next&filter=secret", "?sort=number&limit=200&cursor=next",
                         "?sort=-number&limit=1&cursor=next", "?sort=-number&limit=200",
                         "?cursor=next&limit=200", first, 1):
            with self.subTest(kind=type(next_url).__name__):
                self.api = FakeInspect()
                self.api.page_overrides[first] = {"data": [], "links": {"next": next_url}}
                with self.assertRaises(inspect.Unknown): inspect.inspect(self.api, "123", SHA)
                self.assertEqual(self.api.requests, [])
        self.api = FakeInspect()
        self.api.page_overrides[first] = {"data": []}
        with self.assertRaises(inspect.Unknown): inspect.inspect(self.api, "123", SHA)

    def test_lookup_main_change_or_transport_error_produces_fixed_unknown(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
               "GITHUB_REPOSITORY": inspect.REPOSITORY, "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": SHA,
               "TARGET_SHA": SHA, "ASC_APP_ID": "123", "GH_READ_TOKEN": "token",
               "ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key", "ASC_PRIVATE_KEY": "secret"}
        for mode in ("main-moved", "transport"):
            with self.subTest(mode=mode), patch.dict(os.environ, env, clear=True):
                self.api = FakeInspect()
                if mode == "transport":
                    self.api.page_overrides["/v1/ciProducts/" + PRODUCT + "/buildRuns?sort=-number&limit=200"] = BadStatusLine("secret")
                sequence = [SHA, "c" * 40] if mode == "main-moved" else [SHA]
                output, error = io.StringIO(), io.StringIO()
                with patch.object(inspect, "Client", return_value=self.api), \
                        patch.object(inspect, "github_branch", side_effect=sequence), \
                        redirect_stdout(output), redirect_stderr(error):
                    self.assertEqual(inspect.main(["lookup"]), 2)
                self.assertNotIn("READ_ONLY_CLOUD_LOOKUP", output.getvalue())
                self.assertNotIn("secret", error.getvalue())
                self.assertIn("do not repeat POST", error.getvalue())
                self.assertEqual(self.api.requests, [])

    def test_preflight_uses_real_git_ancestry_and_never_uses_apple_credentials(self):
        with tempfile.TemporaryDirectory() as root:
            repo = Path(root) / "repo"
            repo.mkdir()
            def git(*args):
                return subprocess.run(["git", *args], cwd=repo, check=True, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
            git("init", "-q")
            git("config", "user.email", "unit@example.invalid")
            git("config", "user.name", "Unit Test")
            (repo / "file").write_text("one")
            git("add", "file")
            git("commit", "-qm", "first")
            ancestor = git("rev-parse", "HEAD")
            (repo / "file").write_text("two")
            git("commit", "-qam", "second")
            current = git("rev-parse", "HEAD")
            git("checkout", "-qb", "side", ancestor)
            (repo / "other").write_text("side")
            git("add", "other")
            git("commit", "-qm", "side")
            side = git("rev-parse", "HEAD")
            git("checkout", "-q", "--detach", current)
            output = Path(root) / "output"
            env = {"PATH": os.environ.get("PATH", ""), "GITHUB_EVENT_NAME": "workflow_dispatch",
                   "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": inspect.REPOSITORY,
                   "GITHUB_RUN_ATTEMPT": "1", "GITHUB_SHA": current, "REQUESTED_SHA": ancestor,
                   "GITHUB_OUTPUT": str(output), "GH_READ_TOKEN": "token"}
            original = os.getcwd()
            try:
                os.chdir(repo)
                with patch.dict(os.environ, env, clear=True), patch.object(inspect, "github_branch", return_value=current), \
                        patch.object(inspect, "Client") as apple:
                    inspect.preflight()
                    apple.assert_not_called()
                self.assertEqual(output.read_text(), "target=" + ancestor + "\n")
                output.unlink()
                with patch.dict(os.environ, {**env, "REQUESTED_SHA": ""}, clear=True), \
                        patch.object(inspect, "github_branch", return_value=current):
                    inspect.preflight()
                self.assertEqual(output.read_text(), "target=" + current + "\n")
                for requested in (side, "not-a-sha"):
                    with patch.dict(os.environ, {**env, "REQUESTED_SHA": requested}, clear=True), \
                            patch.object(inspect, "github_branch", return_value=current):
                        with self.assertRaises(inspect.Unknown): inspect.preflight()
                grafts = repo / ".git" / "info" / "grafts"
                grafts.parent.mkdir(parents=True, exist_ok=True)
                grafts.write_text(current + " " + side + "\n")
                with patch.dict(os.environ, {**env, "REQUESTED_SHA": side}, clear=True), \
                        patch.object(inspect, "github_branch", return_value=current):
                    with self.assertRaises(inspect.Unknown): inspect.preflight()
                grafts.unlink()
                shallow = Path(root) / "shallow"
                git("clone", "-q", "--depth=1", "file://" + str(repo), str(shallow))
                os.chdir(shallow)
                with patch.dict(os.environ, env, clear=True), patch.object(inspect, "github_branch", return_value=current):
                    with self.assertRaises(inspect.Unknown): inspect.preflight()
            finally:
                os.chdir(original)

    def test_workflow_is_explicit_read_only_and_separates_git_from_secrets(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/inspect-cloud-runs.yml").read_text()
        self.assertIn("  workflow_dispatch:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertNotIn("  pull_request:", workflow)
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertNotIn("secrets.", workflow.split("      - name: Inspect Cloud runs with reads only", 1)[0])
        self.assertNotIn("continue-on-error", workflow)
        source = (root / "scripts/inspect_cloud_runs.py").read_text()
        self.assertNotIn('method="POST"', source)
        self.assertNotIn('method="PATCH"', source)


if __name__ == "__main__":
    unittest.main()
