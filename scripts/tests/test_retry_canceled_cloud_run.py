"""No network: exercise the guarded Xcode Cloud recovery decision."""
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retry_canceled_cloud_run as retry

SHA = "a" * 40
OLD = "11111111-1111-4111-8111-111111111111"
NEW = "22222222-2222-4222-8222-222222222222"
WORKFLOW = "33333333-3333-4333-8333-333333333333"
PRODUCT = "44444444-4444-4444-8444-444444444444"
REPO = "55555555-5555-4555-8555-555555555555"
REF = "66666666-6666-4666-8666-666666666666"


def relation(kind, ident):
    return {"data": {"type": kind, "id": ident}}


def resource(kind, ident, attrs=None, relations=None):
    return {"type": kind, "id": ident, "attributes": attrs or {}, "relationships": relations or {}}


def run(ident, number, status):
    return resource("ciBuildRuns", ident,
        {"number": number, "completionStatus": status, "executionProgress": "COMPLETE", "cancelReason": "USER_REQUESTED",
         "sourceCommit": {"commitSha": SHA}, "isPullRequestBuild": False},
        {"workflow": relation("ciWorkflows", WORKFLOW), "product": relation("ciProducts", PRODUCT),
         "sourceBranchOrTag": relation("scmGitReferences", REF)})


class Response(io.StringIO):
    status = 201
    def __init__(self, value): super().__init__(json.dumps(value))


class FakeClient:
    def __init__(self):
        self.token = "private-token-sentinel"
        self.opener = self
        self.requests = []
        self.error = False
        self.old = run(OLD, 1, "CANCELED")
        self.new = run(NEW, 2, None)
        self.workflow = resource("ciWorkflows", WORKFLOW, {"isEnabled": True,
            "manualBranchStartCondition": {"source": {"isAllMatch": True}}},
            {"repository": relation("scmRepositories", REPO), "product": relation("ciProducts", PRODUCT)})
        self.repo = resource("scmRepositories", REPO, {"ownerName": "GodisinHisHeaven", "repositoryName": "ohMyTss",
            "httpCloneUrl": "https://github.com/GodisinHisHeaven/ohMyTss.git"})
        self.ref = resource("scmGitReferences", REF, {"kind": "BRANCH", "canonicalName": "refs/heads/main", "isDeleted": False})
        self.runs = [self.old]

    def get(self, path):
        values = {
            "/v1/ciBuildRuns/" + OLD + "?include=workflow,product,sourceBranchOrTag": self.old,
            "/v1/ciBuildRuns/" + NEW + "?include=workflow,product,sourceBranchOrTag": self.new,
            "/v1/ciWorkflows/" + WORKFLOW + "?include=repository,product": self.workflow,
            "/v1/apps/123/ciProduct": resource("ciProducts", PRODUCT),
            "/v1/scmRepositories/" + REPO: self.repo,
            "/v1/scmGitReferences/" + REF: self.ref,
        }
        return {"data": values[path]}

    def all(self, path):
        values = {"/v1/scmRepositories/" + REPO + "/gitReferences?limit=200": [self.ref],
                  "/v1/ciWorkflows/" + WORKFLOW + "/buildRuns?sort=-number&limit=200": self.runs}
        return values[path]

    def open(self, request, timeout):
        self.requests.append(request)
        if self.error:
            raise URLError("ambiguous network failure")
        return Response({"data": self.new})


class TestRecovery(unittest.TestCase):
    def setUp(self):
        self.api = FakeClient()
        self.output = io.StringIO()

    def recover(self, main=lambda _: SHA):
        with redirect_stdout(self.output):
            return retry.recover(self.api, SHA, OLD, "123", current_main=main)

    def test_success_posts_once_to_fixed_apple_endpoint_with_exact_relationships(self):
        self.recover()
        self.assertEqual(len(self.api.requests), 1)
        request = self.api.requests[0]
        self.assertEqual(request.full_url, "https://api.appstoreconnect.apple.com/v1/ciBuildRuns")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(json.loads(request.data), {"data": {"type": "ciBuildRuns", "relationships": {
            "workflow": relation("ciWorkflows", WORKFLOW),
            "sourceBranchOrTag": relation("scmGitReferences", REF)}}})
        self.assertNotIn(self.api.token, self.output.getvalue())

    def test_bad_old_run_app_workflow_or_ref_never_posts(self):
        cases = [
            lambda c: c.old["attributes"].update(sourceCommit={"commitSha": "b" * 40}),
            lambda c: c.old["attributes"].update(isPullRequestBuild=True),
            lambda c: c.old["attributes"].update(completionStatus="FAILED"),
            lambda c: c.old["attributes"].update(executionProgress="RUNNING"),
            lambda c: c.old["attributes"].update(cancelReason=None),
            lambda c: c.old["attributes"].update(cancelReason=""),
            lambda c: c.old["attributes"].update(cancelReason="   "),
            lambda c: c.old["attributes"].update(cancelReason="x" * 257),
            lambda c: c.old["attributes"].update(cancelReason="cancelled\n::warning::injected"),
            lambda c: c.old["attributes"].update(cancelReason="cancelled\x1b[31m"),
            lambda c: c.old["attributes"].update(cancelReason={"message": "cancelled"}),
            lambda c: c.old["relationships"].update(product=relation("ciProducts", REPO)),
            lambda c: c.workflow["attributes"].update(isEnabled=False),
            lambda c: c.workflow["attributes"].update(manualBranchStartCondition=None),
            lambda c: c.workflow["attributes"].update(manualBranchStartCondition={"source": {"isAllMatch": False, "patterns": [{"pattern": "release", "isPrefix": False}]}}),
            lambda c: c.repo["attributes"].update(repositoryName="other"),
            lambda c: c.repo["attributes"].update(httpCloneUrl="https://example.invalid/GodisinHisHeaven/ohMyTss.git"),
            lambda c: c.repo["attributes"].update(httpCloneUrl="https://github.com.example.invalid/GodisinHisHeaven/ohMyTss.git"),
            lambda c: c.repo["attributes"].update(httpCloneUrl="https://github.com/GodisinHisHeaven/ohMyTss.git?x=1"),
            lambda c: c.repo["attributes"].update(httpCloneUrl=None),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/other"),
            lambda c: c.ref["attributes"].update(isDeleted=True),
            lambda c: c.runs.append(run(NEW, 2, "RUNNING")),
            lambda c: c.runs.append(resource("ciBuildRuns", NEW, {"number": 2})),
        ]
        for mutate in cases:
            with self.subTest(case=mutate):
                self.api = FakeClient()
                mutate(self.api)
                with self.assertRaises(retry.Unknown): self.recover()
                self.assertEqual(self.api.requests, [])

    def test_natural_language_cancellation_is_valid_but_not_logged(self):
        for reason in ("Canceled by a newer build.", "Build cancelled by user", "取消于新构建"):
            with self.subTest(reason=reason):
                self.api = FakeClient()
                self.output = io.StringIO()
                self.api.old["attributes"]["cancelReason"] = reason
                self.recover()
                self.assertEqual(len(self.api.requests), 1)
                self.assertIn("cancelReason: unavailable", self.output.getvalue())
                self.assertNotIn(reason, self.output.getvalue())

    def test_invalid_reasons_are_not_logged_or_retried(self):
        for reason in ("", "   ", "x" * 257, "cancelled\n::warning::injected", "cancelled\x1b[31m", None):
            with self.subTest(reason=reason):
                self.api = FakeClient()
                self.output = io.StringIO()
                self.api.old["attributes"]["cancelReason"] = reason
                with self.assertRaises(retry.Unknown) as error:
                    self.recover()
                self.assertEqual(self.api.requests, [])
                self.assertEqual(self.output.getvalue(), "cancelReason: unavailable\n")
                self.assertNotIn("::warning::", str(error.exception) + self.output.getvalue())
                self.assertNotIn("\x1b", str(error.exception) + self.output.getvalue())

    def test_manual_condition_allows_only_all_or_exact_main(self):
        for source, expected in [({"isAllMatch": True}, True),
                                 ({"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]}, True),
                                 ({"isAllMatch": False, "patterns": [{"pattern": "ma", "isPrefix": True}]}, False),
                                 ({}, False)]:
            self.api.workflow["attributes"]["manualBranchStartCondition"]["source"] = source
            self.assertEqual(retry.main_allowed(self.api.workflow), expected)

    def test_main_move_before_post_prevents_post(self):
        sequence = iter([SHA, "b" * 40])
        with self.assertRaises(retry.Unknown): self.recover(lambda _: next(sequence))
        self.assertEqual(self.api.requests, [])

    def test_ambiguous_post_error_is_never_retried(self):
        self.api.error = True
        with self.assertRaises(retry.Unknown): self.recover()
        self.assertEqual(len(self.api.requests), 1)
        self.assertNotIn(self.api.token, self.output.getvalue())

    def test_non_object_post_response_reports_ambiguous_creation(self):
        with patch.object(self.api, "open", side_effect=lambda request, timeout: Response([])) as post:
            with self.assertRaises(retry.Unknown) as error:
                self.recover()
        post.assert_called_once()
        self.assertIn("may have created a run", str(error.exception))
        self.assertIn("do not dispatch again", str(error.exception))

    def test_post_creation_get_error_reports_known_id_and_no_retry(self):
        original_get = self.api.get
        def failing_get(path):
            if path.startswith("/v1/ciBuildRuns/" + NEW):
                raise retry.Retry("temporary ASC error")
            return original_get(path)
        self.api.get = failing_get
        with self.assertRaises(retry.Unknown) as error:
            self.recover()
        self.assertIn(NEW, str(error.exception))
        self.assertIn("do not dispatch again", str(error.exception))
        self.assertEqual(len(self.api.requests), 1)
        self.assertNotIn(self.api.token, str(error.exception))

    def test_new_run_must_match_sha_ref_and_workflow(self):
        for mutation in [lambda n: n["attributes"].update(sourceCommit={"commitSha": "b" * 40}),
                         lambda n: n["relationships"].update(sourceBranchOrTag=relation("scmGitReferences", REPO)),
                         lambda n: n["relationships"].update(workflow=relation("ciWorkflows", REPO))]:
            self.api = FakeClient()
            mutation(self.api.new)
            with self.assertRaises(retry.Unknown): self.recover()
            self.assertEqual(len(self.api.requests), 1)

    def test_delayed_new_commit_is_polled_without_reposting(self):
        original_get = self.api.get
        reads = []
        def delayed(path):
            if path.startswith("/v1/ciBuildRuns/" + NEW):
                reads.append(path)
                if len(reads) == 1:
                    value = copy.deepcopy(original_get(path))
                    value["data"]["attributes"]["sourceCommit"] = None
                    return value
            return original_get(path)
        self.api.get = delayed
        with patch.object(retry.time, "sleep") as sleep:
            self.recover()
        self.assertEqual(len(reads), 2)
        sleep.assert_called_once_with(3)
        self.assertEqual(len(self.api.requests), 1)

    def test_rejects_main_move_after_post(self):
        sequence = iter([SHA, SHA, "b" * 40])
        with self.assertRaises(retry.Unknown): self.recover(lambda _: next(sequence))
        self.assertEqual(len(self.api.requests), 1)

    def test_successful_entrypoint_exposes_new_id_to_workflow(self):
        env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
               "GITHUB_REPOSITORY": retry.REPOSITORY, "GITHUB_RUN_ATTEMPT": "1",
               "GITHUB_SHA": SHA, "TARGET_SHA": SHA, "CANCELED_RUN_ID": OLD,
               "ASC_APP_ID": "123", "ASC_ISSUER_ID": "issuer", "ASC_KEY_ID": "key",
               "ASC_PRIVATE_KEY": "private"}
        with tempfile.NamedTemporaryFile(mode="r+") as output:
            env["GITHUB_OUTPUT"] = output.name
            with patch.dict("os.environ", env, clear=True), patch.object(retry, "Client", return_value=self.api), \
                 patch.object(retry, "recover", return_value=NEW) as recover:
                retry.main()
            recover.assert_called_once_with(self.api, SHA, OLD, "123")
            self.assertEqual(output.read(), "run_id=" + NEW + "\n")

    def test_entrypoint_rejects_non_main_or_automatic_before_credentials(self):
        valid = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                 "GITHUB_REPOSITORY": retry.REPOSITORY, "GITHUB_RUN_ATTEMPT": "1",
                 "GITHUB_SHA": SHA, "TARGET_SHA": SHA}
        for override in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_REF": "refs/heads/topic"},
                         {"GITHUB_RUN_ATTEMPT": "2"}, {"TARGET_SHA": "b" * 40}):
            with patch.dict("os.environ", {**valid, **override}, clear=True):
                with patch.object(retry, "Client") as client:
                    with self.assertRaises(retry.Unknown): retry.main()
                    client.assert_not_called()


if __name__ == "__main__":
    unittest.main()
