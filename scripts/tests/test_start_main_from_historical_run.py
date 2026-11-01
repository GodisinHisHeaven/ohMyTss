"""Exercise the guarded start with local fakes only; never call Apple."""
import copy
from http.client import BadStatusLine, IncompleteRead
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch
from urllib.error import HTTPError, URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import configure_cloud_manual_main as config
import start_main_from_historical_run as start
from test_configure_cloud_manual_main import FakeConfiguration
from test_retry_canceled_cloud_run import SHA, OLD, NEW, PRODUCT, REPO, WORKFLOW, REF, Response, run

HISTORIC = "b" * 40


class FakeStart(FakeConfiguration):
    def __init__(self):
        super().__init__()
        self.old["attributes"]["sourceCommit"]["commitSha"] = HISTORIC
        self.workflow["attributes"]["manualBranchStartCondition"] = copy.deepcopy(config.CONDITION)
        self.product_workflows = [{"type": "ciWorkflows", "id": WORKFLOW}]
        self.product_runs = [self.old]
        self.list_count = 0
        self.on_second_list = None
        self.post_error = None
        self.post_status = 201
        self.post_response = {"data": {"type": "ciBuildRuns", "id": NEW}}

    def all(self, path):
        if path == "/v1/ciProducts/" + PRODUCT + "/workflows?limit=200":
            return copy.deepcopy(self.product_workflows)
        if path == "/v1/ciProducts/" + PRODUCT + "/buildRuns?sort=-number&limit=200":
            self.list_count += 1
            if self.list_count == 2 and self.on_second_list:
                self.on_second_list(self)
            return copy.deepcopy(self.product_runs)
        return super().all(path)

    def open(self, request, timeout):
        self.requests.append(request)
        if self.post_error:
            raise self.post_error
        response = Response(self.post_response)
        response.status = self.post_status
        return response


class TestHistoricalStart(unittest.TestCase):
    def setUp(self):
        self.api = FakeStart()
        self.output = io.StringIO()
        self.dispatches = []

    def do_start(self, *, main=lambda _: SHA, ancestor=lambda *_: True, dispatch=None):
        def check(target, run_id, token):
            self.dispatches.append((target, run_id, token))
        with redirect_stdout(self.output):
            return start.start(self.api, SHA, OLD, "123", "12345", "github-token-sentinel",
                               current_main=main, ancestor_check=ancestor,
                               dispatch_check=dispatch or check, pause=lambda _: None)

    def test_success_posts_once_and_checks_lists_and_dispatch_twice(self):
        self.assertEqual(self.do_start(), NEW)
        self.assertEqual(len(self.api.requests), 1)
        request = self.api.requests[0]
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, "https://api.appstoreconnect.apple.com/v1/ciBuildRuns")
        self.assertEqual(json.loads(request.data), {"data": {"type": "ciBuildRuns", "relationships": {
            "workflow": {"data": {"type": "ciWorkflows", "id": WORKFLOW}},
            "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": REF}}}}})
        self.assertEqual(self.api.list_count, 2)
        self.assertEqual(len(self.dispatches), 2)
        self.assertIn(NEW, self.output.getvalue())
        self.assertNotIn(self.api.token, self.output.getvalue())
        self.assertNotIn("github-token-sentinel", self.output.getvalue())

    def test_bad_history_identity_manual_or_required_actions_never_posts(self):
        changes = [
            lambda c: c.old["attributes"]["sourceCommit"].update(commitSha=SHA),
            lambda c: c.old["attributes"].update(isPullRequestBuild=True),
            lambda c: c.old["attributes"].update(completionStatus="FAILED"),
            lambda c: c.old["attributes"].update(executionProgress="IN_PROGRESS"),
            lambda c: c.old["relationships"]["product"]["data"].update(id=REPO),
            lambda c: c.old["relationships"]["workflow"]["data"].update(id="-" * 36),
            lambda c: c.product_workflows.append({"type": "ciWorkflows", "id": REPO}),
            lambda c: c.product_workflows.clear(),
            lambda c: c.repo["attributes"].update(httpCloneUrl="https://evil.invalid/repo"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/other"),
            lambda c: c.ref["attributes"].update(isDeleted=True),
            lambda c: c.workflow["attributes"].update(isEnabled=False),
            lambda c: c.workflow["attributes"].update(manualBranchStartCondition=None),
            lambda c: c.workflow["attributes"].update(manualBranchStartCondition={"source": {"isAllMatch": True}}),
            lambda c: c.workflow["attributes"]["actions"][1].update(isRequiredToPass=False),
            lambda c: c.workflow["attributes"]["actions"][1]["testConfiguration"].update(testDestinations=[None]),
            lambda c: c.workflow["attributes"]["actions"].pop(),
        ]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeStart()
                change(self.api)
                with self.assertRaises(start.Unknown): self.do_start()
                self.assertEqual(self.api.requests, [])
        self.api = FakeStart()
        with self.assertRaises(start.Unknown): self.do_start(ancestor=lambda *_: False)
        self.assertEqual(self.api.requests, [])

    def test_current_or_ambiguous_apple_runs_never_post(self):
        current = run(NEW, 2, "CANCELED")
        missing_sha = run(NEW, 2, None)
        missing_sha["attributes"]["sourceCommit"] = None
        malformed_sha = run(NEW, 2, None)
        malformed_sha["attributes"]["sourceCommit"] = {"commitSha": "secret\n::warning::"}
        bad_id = run("-" * 36, 2, "CANCELED")
        bad_id["attributes"]["sourceCommit"]["commitSha"] = HISTORIC
        cases = [[], [self.api.old, current], [self.api.old, missing_sha], [self.api.old, malformed_sha],
                 [self.api.old, self.api.old], [self.api.old, bad_id], [None]]
        for items in cases:
            with self.subTest(count=len(items)):
                self.api = FakeStart()
                self.api.product_runs = items
                with self.assertRaises(start.Unknown) as error: self.do_start()
                self.assertEqual(self.api.requests, [])
                self.assertNotIn("::warning::", str(error.exception))

    def test_second_apple_list_or_workflow_change_aborts_before_post(self):
        self.api.on_second_list = lambda c: c.product_runs.append(run(NEW, 2, None))
        with self.assertRaises(start.Unknown): self.do_start()
        self.assertEqual(self.api.requests, [])
        self.api = FakeStart()
        self.api.mutate_pre_patch = lambda w: w["attributes"].update(lastModifiedDate="changed")
        with self.assertRaises(start.Unknown): self.do_start()
        self.assertEqual(self.api.requests, [])

    def test_dispatch_or_main_change_before_post_aborts(self):
        calls = []
        def dispatch(*_):
            calls.append(1)
            if len(calls) == 2: raise start.Unknown("another run")
        with self.assertRaises(start.Unknown): self.do_start(dispatch=dispatch)
        self.assertEqual(self.api.requests, [])
        self.api = FakeStart()
        sequence = iter([SHA, "c" * 40])
        with self.assertRaises(start.Unknown): self.do_start(main=lambda _: next(sequence))
        self.assertEqual(self.api.requests, [])

    def test_post_errors_are_ambiguous_and_never_retried(self):
        for code in (400, 401, 403, 404, 409, 422):
            with self.subTest(code=code):
                self.api = FakeStart()
                self.api.post_error = HTTPError("https://example.invalid", code, "secret", {}, None)
                with self.assertRaises(start.Unknown) as error: self.do_start()
                self.assertEqual(len(self.api.requests), 1)
                self.assertIn("POST rejected (HTTP %d)" % code, str(error.exception))
                self.assertIn("no automatic retry", str(error.exception))
                self.assertNotIn("secret", str(error.exception))
                self.api = FakeStart()
                self.api.post_status = code
                with self.assertRaises(start.Unknown) as returned_error: self.do_start()
                self.assertEqual(len(self.api.requests), 1)
                self.assertIn("POST rejected (HTTP %d)" % code, str(returned_error.exception))
        for failure in (HTTPError("https://example.invalid", 429, "secret", {}, None),
                        HTTPError("https://example.invalid", 500, "secret", {}, None),
                        URLError("secret"), IncompleteRead(b"secret", 20), BadStatusLine("secret")):
            with self.subTest(kind=type(failure).__name__):
                self.api = FakeStart()
                self.api.post_error = failure
                with self.assertRaises(start.Unknown) as error: self.do_start()
                self.assertEqual(len(self.api.requests), 1)
                self.assertIn("may have created", str(error.exception))
                self.assertIn("do not dispatch again", str(error.exception))
                self.assertNotIn("secret", str(error.exception))
        for response in (None, [], {"data": []}, {"data": {"type": "ciBuildRuns", "id": "bad"}}):
            with self.subTest(response=type(response).__name__):
                self.api = FakeStart()
                self.api.post_response = response
                with self.assertRaises(start.Unknown) as error: self.do_start()
                self.assertEqual(len(self.api.requests), 1)
                self.assertIn("may have created", str(error.exception))

    def test_post_read_failure_preserves_known_id_and_never_reposts(self):
        original = self.api.get
        def failed_read(path):
            if path.startswith("/v1/ciBuildRuns/" + NEW):
                raise BadStatusLine("secret")
            return original(path)
        self.api.get = failed_read
        with self.assertRaises(start.Unknown) as error: self.do_start()
        self.assertIn(NEW, str(error.exception))
        self.assertIn("do not dispatch again", str(error.exception))
        self.assertNotIn("secret", str(error.exception))
        self.assertEqual(len(self.api.requests), 1)

    def test_http_error_after_response_is_always_ambiguous(self):
        for phase in ("read", "exit"):
            with self.subTest(phase=phase):
                self.api = FakeStart()
                error = HTTPError("https://example.invalid", 403, "secret", {}, None)

                class BrokenResponse(Response):
                    status = 201
                    def read(self, *args):
                        if phase == "read":
                            raise error
                        return super().read(*args)
                    def __exit__(self, *args):
                        if phase == "exit":
                            raise error
                        return super().__exit__(*args)

                def opened(request, timeout):
                    self.api.requests.append(request)
                    return BrokenResponse({"data": {"type": "ciBuildRuns", "id": NEW}})

                self.api.opener.open = opened
                with self.assertRaises(start.Unknown) as failure:
                    self.do_start()
                self.assertIn("may have created", str(failure.exception))
                self.assertIn("do not dispatch again", str(failure.exception))
                self.assertNotIn("secret", str(failure.exception))
                self.assertEqual(len(self.api.requests), 1)

    def test_delayed_post_source_is_polled_without_reposting(self):
        self.api.new["attributes"]["sourceCommit"] = None
        original = self.api.get
        reads = []
        def delayed_read(path):
            if path.startswith("/v1/ciBuildRuns/" + NEW):
                reads.append(1)
                if len(reads) == 2:
                    self.api.new["attributes"]["sourceCommit"] = {"commitSha": SHA}
            return original(path)
        self.api.get = delayed_read
        self.assertEqual(self.do_start(), NEW)
        self.assertEqual(len(reads), 2)
        self.assertEqual(len(self.api.requests), 1)

    def test_post_mismatch_or_main_move_retains_id_and_stops(self):
        self.api.new["attributes"]["sourceCommit"]["commitSha"] = "c" * 40
        with self.assertRaises(start.Unknown) as error: self.do_start()
        self.assertIn(NEW, str(error.exception))
        self.assertEqual(len(self.api.requests), 1)
        self.api = FakeStart()
        sequence = iter([SHA, SHA, "c" * 40])
        with self.assertRaises(start.Unknown) as error: self.do_start(main=lambda _: next(sequence))
        self.assertIn(NEW, str(error.exception))
        self.assertEqual(len(self.api.requests), 1)

    def test_unique_dispatch_requires_only_current_first_attempt(self):
        class Opener:
            def __init__(self, body=None, error=None): self.body, self.error, self.requests = body, error, []
            def open(self, request, timeout):
                self.requests.append(request)
                if self.error: raise self.error
                return Response(self.body)
        good = {"total_count": 1, "workflow_runs": [{"id": 12345, "head_sha": SHA,
                "event": "workflow_dispatch", "run_attempt": 1}]}
        opener = Opener(good)
        start.require_unique_dispatch(SHA, "12345", "secret-token", opener=opener)
        self.assertEqual(len(opener.requests), 1)
        self.assertTrue(opener.requests[0].full_url.startswith("https://api.github.com/repos/" + start.REPOSITORY + "/"))
        for response in ({"total_count": 0, "workflow_runs": []},
                         {"total_count": 2, "workflow_runs": good["workflow_runs"]},
                         {"total_count": 1, "workflow_runs": [{**good["workflow_runs"][0], "id": 8}]},
                         {"total_count": 1, "workflow_runs": [{**good["workflow_runs"][0], "run_attempt": 2}]},
                         {"total_count": True, "workflow_runs": good["workflow_runs"]},
                         {"total_count": 1, "workflow_runs": [None]}):
            with self.subTest(response=response):
                with self.assertRaises(start.Unknown):
                    start.require_unique_dispatch(SHA, "12345", "secret-token", opener=Opener(response))
        with self.assertRaises(start.Unknown) as error:
            start.require_unique_dispatch(SHA, "12345", "secret-token", opener=Opener(error=BadStatusLine("secret-token")))
        self.assertNotIn("secret-token", str(error.exception))

    def test_entrypoint_guards_and_output(self):
        base = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                "GITHUB_REPOSITORY": start.REPOSITORY, "GITHUB_RUN_ATTEMPT": "1", "GITHUB_RUN_ID": "12345",
                "GITHUB_SHA": SHA, "TARGET_SHA": SHA, "CONFIRM_START": "true", "HISTORICAL_RUN_ID": OLD,
                "ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key", "ASC_PRIVATE_KEY": "private",
                "GH_READ_TOKEN": "token", "ASC_APP_ID": "123", "GITHUB_OUTPUT": "/not-used"}
        for override in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_REF": "refs/heads/other"},
                         {"GITHUB_RUN_ATTEMPT": "2"}, {"CONFIRM_START": "false"}, {"TARGET_SHA": HISTORIC}):
            with self.subTest(override=override), patch.dict(os.environ, {**base, **override}, clear=True):
                with patch.object(start, "Client") as client:
                    with self.assertRaises(start.Unknown): start.main()
                    client.assert_not_called()
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "output")
            with patch.dict(os.environ, {**base, "GITHUB_OUTPUT": path}, clear=True):
                with patch.object(start, "Client"), patch.object(start, "start", return_value=NEW): start.main()
            self.assertEqual(Path(path).read_text(), "run_id=" + NEW + "\n")
        with patch.dict(os.environ, base, clear=True):
            with patch.object(start, "Client"), patch.object(start, "start", return_value=NEW), \
                    patch("builtins.open", side_effect=OSError("secret")):
                with self.assertRaises(start.Unknown) as error: start.main()
                self.assertIn(NEW, str(error.exception))
                self.assertNotIn("secret", str(error.exception))
        with patch.dict(os.environ, base, clear=True):
            with patch.object(start, "Client"), patch.object(start, "start", side_effect=BadStatusLine("secret")):
                with self.assertRaises(start.Unknown) as error: start.main()
                self.assertIn("may exist", str(error.exception))
                self.assertIn("do not dispatch again", str(error.exception))
                self.assertNotIn("secret", str(error.exception))

    def test_workflow_is_explicit_main_only_and_uses_existing_verifier(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/start-main-from-history.yml").read_text()
        self.assertIn("  workflow_dispatch:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertNotIn("  pull_request:", workflow)
        self.assertIn("default: false", workflow)
        self.assertIn("group: testflight-cloud-recovery", workflow)
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("--expected-run-id", workflow)
        self.assertIn("scripts/verify_testflight.py", workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("secrets.", workflow.split("      - name: Start one current-main Cloud build", 1)[0])


if __name__ == "__main__":
    unittest.main()
