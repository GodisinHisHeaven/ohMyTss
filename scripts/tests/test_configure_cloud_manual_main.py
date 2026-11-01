"""Guard the sparse Cloud workflow update without calling Apple."""
import copy
from http.client import BadStatusLine, IncompleteRead, LineTooLong
import io
import json
import sys
from pathlib import Path
import unittest
from contextlib import redirect_stdout
from urllib.error import HTTPError, URLError
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import configure_cloud_manual_main as config
from test_retry_canceled_cloud_run import (FakeClient, Response, SHA, OLD, WORKFLOW, PRODUCT, REPO, REF)


class FakeConfiguration(FakeClient):
    def __init__(self):
        super().__init__()
        self.workflow["attributes"].update({
            "name": "Workflow",
            "tagStartCondition": None, "pullRequestStartCondition": None,
            "scheduledStartCondition": None, "manualTagStartCondition": None,
            "manualPullRequestStartCondition": None, "clean": False, "containerFilePath": "app.xcodeproj",
            "isLockedForEditing": False,
            "lastModifiedDate": "2026-01-01T00:00:00Z",
            "manualBranchStartCondition": None,
            "branchStartCondition": {"source": {"isAllMatch": True}, "autoCancel": True},
            "actions": [
                {"name": "Build - iOS", "actionType": "BUILD", "platform": "IOS", "scheme": "App"},
                {"name": "Test - iOS", "actionType": "TEST", "platform": "IOS", "scheme": "App",
                 "isRequiredToPass": True, "testConfiguration": {"kind": "USE_SCHEME_SETTINGS",
                                                                  "testDestinations": [{"kind": "SIMULATOR",
                                    "deviceTypeIdentifier": "simulator-device",
                                    "runtimeIdentifier": "simulator-runtime"}]}},
                {"name": "Archive - iOS", "actionType": "ARCHIVE", "platform": "IOS", "scheme": "App"},
            ],
        })
        self.workflow["relationships"]["xcodeVersion"] = {"data": None}
        self.workflow["relationships"]["macOsVersion"] = {"data": None}
        self.reads = 0
        self.patch_error = None
        self.mutate_pre_patch = None
        self.mutate_after = None
        self.mutate_included_after = None

    def get(self, path):
        if path == config.workflow_path(WORKFLOW):
            self.reads += 1
            if self.reads == 2 and self.mutate_pre_patch:
                self.mutate_pre_patch(self.workflow)
            if self.reads == 3 and self.mutate_after:
                self.mutate_after(self.workflow)
            if self.reads == 3 and self.mutate_included_after:
                self.mutate_included_after(self.repo)
            return {"data": copy.deepcopy(self.workflow),
                    "included": [copy.deepcopy(self.repo),
                                 {"type": "ciProducts", "id": PRODUCT, "attributes": {"name": "App"}}]}
        return super().get(path)

    def open(self, request, timeout):
        self.requests.append(request)
        if self.patch_error:
            raise self.patch_error
        self.workflow["attributes"]["manualBranchStartCondition"] = copy.deepcopy(config.CONDITION)
        self.workflow["attributes"]["lastModifiedDate"] = "2026-01-02T00:00:00Z"
        response = Response({"data": self.workflow})
        response.status = 200
        return response


class TestManualConfiguration(unittest.TestCase):
    def setUp(self):
        self.api = FakeConfiguration()
        self.output = io.StringIO()

    def check(self, apply=True, main=lambda _: SHA):
        with redirect_stdout(self.output):
            config.configure(self.api, SHA, OLD, "123", apply, current_main=main)

    def test_default_read_only_does_not_patch_or_start_build(self):
        self.check(False)
        self.assertEqual(self.api.requests, [])
        self.assertIn("Read-only mode", self.output.getvalue())
        self.assertIn("Manual branch coverage: not configured", self.output.getvalue())

    def test_manual_coverage_classifies_only_documented_shapes(self):
        cases = [
            (None, "not configured"),
            ({"source": {"isAllMatch": True}}, "covers main but broader"),
            ({"source": {"isAllMatch": True, "patterns": None}}, "covers main but broader"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]}}, "exact main"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "ma", "isPrefix": True}]}}, "covers main but broader"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": True}]}}, "covers main but broader"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "Main", "isPrefix": False}]}}, "does not cover main"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "refs/heads/main", "isPrefix": False}]}}, "does not cover main"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main/", "isPrefix": True}]}}, "does not cover main"),
            ({"source": {"isAllMatch": True, "patterns": []}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": []}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False},
                                                            {"pattern": "other", "isPrefix": False}]}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "", "isPrefix": True}]}}, "unknown"),
            ({"source": {"isAllMatch": 1}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": 0}]}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False,
                                                              "future": "sensitive-pattern"}]}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False,
                                                              "future": None}]}}, "unknown"),
            ({"source": {"isAllMatch": True}, "future": None}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": [None]}}, "unknown"),
            ({"source": {"isAllMatch": False, "patterns": "main"}}, "unknown"),
            ({"source": {"patterns": []}}, "unknown"),
            ({"source": {}, "unexpected": "sensitive-pattern"}, "unknown"),
            ({}, "unknown"),
            ("sensitive-pattern", "unknown"),
        ]
        for condition, expected in cases:
            with self.subTest(expected=expected, shape=type(condition).__name__):
                self.assertEqual(config.manual_main_coverage(condition), expected)

    def test_read_only_reports_safe_coverage_without_patch_for_existing_condition(self):
        cases = [
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]}}, "exact main"),
            ({"source": {"isAllMatch": True}}, "covers main but broader"),
            ({"source": {"isAllMatch": False, "patterns": [{"pattern": "sensitive-pattern", "isPrefix": False}]}}, "does not cover main"),
            ({"unexpected": "sensitive-pattern"}, "unknown"),
            ("missing", "unknown"),
        ]
        for condition, expected in cases:
            with self.subTest(expected=expected):
                self.api = FakeConfiguration()
                self.output = io.StringIO()
                if condition == "missing":
                    del self.api.workflow["attributes"]["manualBranchStartCondition"]
                else:
                    self.api.workflow["attributes"]["manualBranchStartCondition"] = condition
                self.check(False)
                self.assertEqual(self.api.requests, [])
                self.assertIn("Manual branch coverage: " + expected, self.output.getvalue())
                self.assertIn("Read-only mode", self.output.getvalue())
                self.assertNotIn("sensitive-pattern", self.output.getvalue())

    def test_read_only_does_not_classify_before_identity_and_action_validation(self):
        for change in (lambda c: c.old["attributes"].update(sourceCommit={"commitSha": "b" * 40}),
                       lambda c: c.repo["attributes"].update(httpCloneUrl="https://evil.invalid/x"),
                       lambda c: c.workflow["attributes"]["actions"][1].update(isRequiredToPass=False)):
            with self.subTest(change=change):
                self.api = FakeConfiguration()
                self.output = io.StringIO()
                self.api.workflow["attributes"]["manualBranchStartCondition"] = copy.deepcopy(config.CONDITION)
                change(self.api)
                with self.assertRaises(config.Unknown): self.check(False)
                self.assertNotIn("Manual branch coverage:", self.output.getvalue())
                self.assertEqual(self.api.requests, [])

    def test_sparse_main_only_patch_and_readback(self):
        self.check()
        self.assertEqual(len(self.api.requests), 1)
        request = self.api.requests[0]
        self.assertEqual(request.get_method(), "PATCH")
        self.assertEqual(request.full_url, "https://api.appstoreconnect.apple.com/v1/ciWorkflows/" + WORKFLOW)
        self.assertEqual(json.loads(request.data), {"data": {"type": "ciWorkflows", "id": WORKFLOW,
                         "attributes": {"manualBranchStartCondition": config.CONDITION}}})
        self.assertEqual(self.api.reads, 3)
        self.assertNotIn(self.api.token, self.output.getvalue())
        self.assertIn("No build started", self.output.getvalue())

    def test_non_null_or_omitted_manual_condition_never_patched(self):
        for condition in ({"source": {"isAllMatch": True}}, {}, "missing"):
            with self.subTest(condition=condition):
                self.api = FakeConfiguration()
                if condition == "missing":
                    del self.api.workflow["attributes"]["manualBranchStartCondition"]
                else:
                    self.api.workflow["attributes"]["manualBranchStartCondition"] = condition
                with self.assertRaises(config.Unknown): self.check()
                self.assertEqual(self.api.requests, [])

    def test_safe_preflight_reports_missing_null_or_non_null_without_values(self):
        for condition, expected in (("missing", "missing"), (None, "null"),
                                    ({"secret": "sensitive-free-text"}, "non-null")):
            with self.subTest(condition=condition):
                self.api = FakeConfiguration()
                self.output = io.StringIO()
                if condition == "missing":
                    del self.api.workflow["attributes"]["manualBranchStartCondition"]
                else:
                    self.api.workflow["attributes"]["manualBranchStartCondition"] = condition
                del self.api.workflow["attributes"]["branchStartCondition"]
                self.api.workflow["attributes"]["actions"][0].pop("scheme")
                with self.assertRaises(config.Unknown): self.check(False)
                text = self.output.getvalue()
                self.assertIn("manualBranchStartCondition: " + expected, text)
                self.assertIn("Missing workflow attributes: branchStartCondition", text)
                self.assertIn("Missing action details: scheme", text)
                self.assertNotIn("sensitive-free-text", text)
                self.assertEqual(self.api.requests, [])

    def test_wrong_identity_state_actions_or_required_test_never_patched(self):
        changes = [
            lambda c: c.old["attributes"].update(completionStatus="FAILED"),
            lambda c: c.old["attributes"].update(sourceCommit={"commitSha": "b" * 40}),
            lambda c: c.old["attributes"].update(isPullRequestBuild=True),
            lambda c: c.old["relationships"]["product"]["data"].update(id=REPO),
            lambda c: c.repo["attributes"].update(httpCloneUrl="https://evil.invalid/GodisinHisHeaven/ohMyTss.git"),
            lambda c: c.ref["attributes"].update(canonicalName="refs/heads/other"),
            lambda c: c.workflow["attributes"].update(isLockedForEditing=True),
            lambda c: c.workflow["attributes"].update(isEnabled=False),
            lambda c: c.workflow["attributes"].update(actions=[]),
            lambda c: c.workflow["attributes"]["actions"][1].update(isRequiredToPass=False),
            lambda c: c.workflow["attributes"]["actions"][1].update(platform="WATCHOS"),
            lambda c: c.workflow["attributes"]["actions"][1].pop("scheme"),
            lambda c: c.workflow["attributes"]["actions"][1].pop("testConfiguration"),
            lambda c: c.workflow["attributes"]["actions"][1]["testConfiguration"].update(testDestinations=[]),
            lambda c: c.workflow["attributes"]["actions"][1]["testConfiguration"].update(kind="SPECIFIC_TEST_PLANS"),
            lambda c: c.workflow["attributes"]["actions"][0].pop("platform"),
            lambda c: c.workflow["attributes"].pop("lastModifiedDate"),
            lambda c: c.workflow["attributes"].pop("branchStartCondition"),
            lambda c: c.workflow["relationships"].pop("macOsVersion"),
        ]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeConfiguration()
                change(self.api)
                with self.assertRaises(config.Unknown): self.check()
                self.assertEqual(self.api.requests, [])

    def test_destination_structure_is_validated_before_patch(self):
        good = {"kind": "SIMULATOR", "deviceTypeIdentifier": "sim-device", "runtimeIdentifier": "sim-runtime"}
        bad = [None, 1, "simulator", [], {}, {"kind": "unknown"}, {"kind": []},
               {"kind": "SIMULATOR"}, {"kind": "SIMULATOR", "deviceTypeIdentifier": "id"},
               {"kind": "SIMULATOR", "deviceTypeIdentifier": "", "runtimeIdentifier": "runtime"},
               {"kind": "SIMULATOR", "deviceTypeIdentifier": "id", "runtimeIdentifier": 4},
               {"kind": "MAC", "runtimeName": []}]
        for destination in bad:
            with self.subTest(destination=destination):
                self.api = FakeConfiguration()
                self.api.workflow["attributes"]["actions"][1]["testConfiguration"]["testDestinations"] = [good, destination]
                with self.assertRaises(config.Unknown): self.check()
                self.assertEqual(self.api.requests, [])
        self.api = FakeConfiguration()
        self.api.workflow["attributes"]["actions"][1]["testConfiguration"]["testDestinations"] = [good, {"kind": "MAC"}]
        self.check(False)
        self.assertEqual(self.api.requests, [])

    def test_http_protocol_errors_during_patch_are_uncertain_and_not_retried(self):
        for failure in (IncompleteRead(b"partial", 100), BadStatusLine("bad status"), LineTooLong("header")):
            with self.subTest(failure=type(failure).__name__):
                self.api = FakeConfiguration()
                self.api.patch_error = failure
                with self.assertRaises(config.Unknown) as error: self.check()
                self.assertIn("outcome unknown", str(error.exception))
                self.assertEqual(len(self.api.requests), 1)
                self.assertNotIn(str(failure), str(error.exception))

    def test_truncated_or_malformed_readback_is_uncertain_and_not_retried(self):
        changes = [lambda w: w["attributes"]["actions"][1].update(actionType=[]),
                   lambda w: w["attributes"]["actions"][1]["testConfiguration"].update(kind={})]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeConfiguration()
                self.api.mutate_after = change
                with self.assertRaises(config.Unknown) as error: self.check()
                self.assertIn("may have applied", str(error.exception))
                self.assertEqual(len(self.api.requests), 1)
        for failure in (IncompleteRead(b"partial", 100), BadStatusLine("bad status"), LineTooLong("header")):
            with self.subTest(failure=type(failure).__name__):
                self.api = FakeConfiguration()
                original = self.api.get
                def failed_readback(path):
                    if path == config.workflow_path(WORKFLOW) and self.api.reads == 2:
                        raise failure
                    return original(path)
                self.api.get = failed_readback
                with self.assertRaises(config.Unknown) as error: self.check()
                self.assertIn("may have applied", str(error.exception))
                self.assertNotIn(str(failure), str(error.exception))
                self.assertEqual(len(self.api.requests), 1)

    def test_concurrent_changes_before_patch_are_blocked(self):
        changes = [lambda w: w["attributes"].update(manualBranchStartCondition={}),
                   lambda w: w["attributes"].update(lastModifiedDate="changed"),
                   lambda w: w["attributes"]["branchStartCondition"].update(autoCancel=False)]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeConfiguration()
                self.api.mutate_pre_patch = change
                with self.assertRaises(config.Unknown): self.check()
                self.assertEqual(self.api.requests, [])

    def test_bad_readback_is_reported_and_never_retried(self):
        changes = [lambda w: w["attributes"].update(manualBranchStartCondition=None),
                   lambda w: w["attributes"]["actions"][1].update(isRequiredToPass=False),
                   lambda w: w["attributes"]["branchStartCondition"].update(autoCancel=False)]
        for change in changes:
            with self.subTest(change=change):
                self.api = FakeConfiguration()
                self.api.mutate_after = change
                with self.assertRaises(config.Unknown) as error: self.check()
                self.assertIn("may have applied", str(error.exception))
                self.assertEqual(len(self.api.requests), 1)

    def test_readback_reports_safe_stage_and_type_without_values(self):
        changes = [
            (lambda w: w["attributes"].update(manualBranchStartCondition={"source": "sensitive-value"}),
             "manual-condition-comparison"),
            (lambda w: w["attributes"]["actions"][1].update(isRequiredToPass=False),
             "other-configuration-validation"),
            (lambda w: w["attributes"]["branchStartCondition"].update(autoCancel=False),
             "other-configuration-comparison"),
        ]
        for change, stage in changes:
            with self.subTest(stage=stage):
                self.api = FakeConfiguration()
                self.api.mutate_after = change
                with self.assertRaises(config.Unknown) as error: self.check()
                self.assertIn("stage: " + stage, str(error.exception))
                self.assertIn("type: validation-error", str(error.exception))
                self.assertIn("may have applied", str(error.exception))
                self.assertNotIn("sensitive-value", str(error.exception))
                self.assertEqual(len(self.api.requests), 1)
        self.api = FakeConfiguration()
        self.api.mutate_included_after = lambda repo: repo["attributes"].update(repositoryName="sensitive-value")
        with self.assertRaises(config.Unknown) as error: self.check()
        self.assertIn("stage: included-resources-comparison", str(error.exception))
        self.assertNotIn("sensitive-value", str(error.exception))
        self.assertEqual(len(self.api.requests), 1)

    def test_readback_transport_and_unexpected_exceptions_never_leak_or_retry(self):
        failures = [(IncompleteRead(b"sensitive-value", 30), "http-protocol-error"),
                    (config.Retry("sensitive-value"), "retryable-read-error"),
                    (config.Unknown("sensitive-value"), "validation-error"),
                    (ValueError("sensitive-value"), "invalid-value"),
                    (KeyError("sensitive-value"), "other")]
        for failure, label in failures:
            with self.subTest(label=label):
                self.api = FakeConfiguration()
                original = self.api.get
                def failed_readback(path):
                    if path == config.workflow_path(WORKFLOW) and self.api.reads == 2:
                        raise failure
                    return original(path)
                self.api.get = failed_readback
                with self.assertRaises(config.Unknown) as error: self.check()
                self.assertIn("stage: workflow-read", str(error.exception))
                self.assertIn("type: " + label, str(error.exception))
                self.assertIn("may have applied", str(error.exception))
                self.assertNotIn("sensitive-value", str(error.exception))
                self.assertEqual(len(self.api.requests), 1)

    def test_main_change_after_patch_reports_stage_without_retry(self):
        sequence = iter([SHA, SHA, "b" * 40])
        with self.assertRaises(config.Unknown) as error: self.check(main=lambda _: next(sequence))
        self.assertIn("stage: main-commit-check", str(error.exception))
        self.assertIn("may have applied", str(error.exception))
        self.assertEqual(len(self.api.requests), 1)

    def test_included_resource_change_fails_after_single_patch(self):
        self.api.mutate_included_after = lambda repo: repo["attributes"].update(repositoryName="changed")
        with self.assertRaises(config.Unknown) as error: self.check()
        self.assertIn("may have applied", str(error.exception))
        self.assertEqual(len(self.api.requests), 1)

    def test_workflow_is_manual_main_only_and_shares_recovery_lock(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/cloud-manual-main.yml").read_text()
        self.assertIn("  workflow_dispatch:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertNotIn("  pull_request:", workflow)
        self.assertIn("default: false", workflow)
        self.assertIn("group: testflight-cloud-recovery", workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("secrets.", workflow.split("      - name: Inspect or configure manual main", 1)[0])

    def test_rejection_and_ambiguous_patch_each_sent_once(self):
        for error, message in ((HTTPError("https://example.invalid", 403, "Forbidden", {}, None), "HTTP 403"),
                               (URLError("connection lost"), "outcome unknown")):
            with self.subTest(error=error):
                self.api = FakeConfiguration()
                self.api.patch_error = error
                with self.assertRaises(config.Unknown) as exc: self.check()
                self.assertIn(message, str(exc.exception))
                self.assertEqual(len(self.api.requests), 1)
                self.assertNotIn(self.api.token, str(exc.exception))

    def test_main_change_before_patch_is_blocked(self):
        sequence = iter([SHA, "b" * 40])
        with self.assertRaises(config.Unknown): self.check(main=lambda _: next(sequence))
        self.assertEqual(self.api.requests, [])

    def test_entrypoint_rejects_non_main_or_automatic_before_credentials(self):
        valid = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
                 "GITHUB_REPOSITORY": config.REPOSITORY, "GITHUB_RUN_ATTEMPT": "1"}
        for override in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_REF": "refs/heads/topic"},
                         {"GITHUB_RUN_ATTEMPT": "2"}):
            with patch.dict("os.environ", {**valid, **override}, clear=True):
                with patch.object(config, "Client") as client:
                    with self.assertRaises(config.Unknown): config.main()
                    client.assert_not_called()


if __name__ == "__main__":
    unittest.main()
