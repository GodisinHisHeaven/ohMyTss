#!/usr/bin/env python3
"""Inspect or add a main-only Xcode Cloud manual condition; never start a build."""
import json
from http.client import HTTPException
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request

from retry_canceled_cloud_run import (REPOSITORY, UUID, check_branch, github_branch,
                                      link, request_data, require, source_sha)
from verify_testflight import Client, Retry, Unknown, attributes

FIELDS = ("name,description,branchStartCondition,tagStartCondition,pullRequestStartCondition,"
          "scheduledStartCondition,manualBranchStartCondition,manualTagStartCondition,"
          "manualPullRequestStartCondition,actions,isEnabled,isLockedForEditing,clean,"
          "containerFilePath,lastModifiedDate,product,repository,xcodeVersion,macOsVersion")
CONDITION = {"source": {"isAllMatch": False, "patterns": [{"pattern": "main", "isPrefix": False}]}}
REQUIRED_FIELDS = ("name", "branchStartCondition", "tagStartCondition", "pullRequestStartCondition",
                   "scheduledStartCondition", "manualTagStartCondition", "manualPullRequestStartCondition",
                   "clean", "containerFilePath", "actions", "isEnabled", "isLockedForEditing", "lastModifiedDate")
REQUIRED_RELATIONSHIPS = ("product", "repository", "xcodeVersion", "macOsVersion")


def valid_destination(destination):
    # Apple documents CiTestDestination kinds MAC and SIMULATOR. Simulators
    # must identify both device type and runtime for this conservative preflight.
    if not isinstance(destination, dict) or destination.get("kind") not in ("SIMULATOR", "MAC"):
        return False
    fields = ("deviceTypeIdentifier", "deviceTypeName", "runtimeIdentifier", "runtimeName")
    for field in fields:
        if field in destination and destination[field] is not None:
            if not isinstance(destination[field], str) or not destination[field].strip():
                return False
    if destination["kind"] == "SIMULATOR":
        return all(isinstance(destination.get(field), str) and destination[field].strip()
                   for field in ("deviceTypeIdentifier", "runtimeIdentifier"))
    return True


def workflow_path(workflow_id):
    return ("/v1/ciWorkflows/" + workflow_id + "?include=repository,product,xcodeVersion,macOsVersion"
            "&fields%5BciWorkflows%5D=" + FIELDS
            + "&fields%5BscmRepositories%5D=ownerName,repositoryName,httpCloneUrl"
            + "&fields%5BciProducts%5D=name,productType,bundleId"
            + "&fields%5BciXcodeVersions%5D=name,version"
            + "&fields%5BciMacOsVersions%5D=name,version")


def report_availability(workflow):
    a = workflow.get("attributes")
    if not isinstance(a, dict):
        print("Workflow attribute data: missing")
        return
    manual = ("missing" if "manualBranchStartCondition" not in a else
              "null" if a["manualBranchStartCondition"] is None else "non-null")
    print("manualBranchStartCondition:", manual)
    missing = [key for key in REQUIRED_FIELDS if key not in a]
    print("Missing workflow attributes:", ", ".join(missing) if missing else "none")
    relationships = workflow.get("relationships")
    relationships = relationships if isinstance(relationships, dict) else {}
    missing = [key for key in REQUIRED_RELATIONSHIPS
               if not isinstance(relationships.get(key), dict) or "data" not in relationships[key]]
    print("Missing workflow relationship data:", ", ".join(missing) if missing else "none")
    actions = a.get("actions")
    if not isinstance(actions, list):
        print("Action details: unavailable")
        return
    selected = [x for x in actions if isinstance(x, dict) and x.get("actionType") in ("BUILD", "TEST", "ARCHIVE")]
    missing_kinds = [kind for kind in ("BUILD", "TEST", "ARCHIVE")
                     if not any(x.get("actionType") == kind for x in selected)]
    print("Missing action types:", ", ".join(missing_kinds) if missing_kinds else "none")
    missing_details = [key for key in ("name", "platform", "scheme")
                       if any(not isinstance(x.get(key), str) or not x[key].strip() for x in selected)]
    print("Missing action details:", ", ".join(missing_details) if missing_details else "none")
    ios_tests = [x for x in selected if x.get("actionType") == "TEST" and x.get("name") == "Test - iOS"]
    if len(ios_tests) != 1:
        print("Required iOS test details: unavailable or ambiguous")
        return
    ios = ios_tests[0]
    missing_test = [key for key in ("isRequiredToPass", "platform", "testConfiguration") if key not in ios]
    test = ios.get("testConfiguration")
    if isinstance(test, dict):
        missing_test.extend("testConfiguration." + key for key in ("kind", "testDestinations") if key not in test)
        if test.get("kind") == "SPECIFIC_TEST_PLANS" and "testPlanName" not in test:
            missing_test.append("testConfiguration.testPlanName")
    print("Missing required iOS test fields:", ", ".join(missing_test) if missing_test else "none")
    destinations = test.get("testDestinations") if isinstance(test, dict) else None
    valid = isinstance(destinations, list) and bool(destinations) and all(valid_destination(x) for x in destinations)
    print("Required iOS test destination structure:", "available" if valid else "unavailable or invalid")


def read_workflow(client, workflow_id, report=False):
    response = client.get(workflow_path(workflow_id))
    item = response.get("data")
    require(isinstance(item, dict) and item.get("type") == "ciWorkflows" and item.get("id") == workflow_id,
            "Unexpected workflow resource")
    if report:
        report_availability(item)
    included = response.get("included")
    require(isinstance(included, list), "Included workflow resources unavailable")
    comparable = []
    seen = set()
    for resource in included:
        require(isinstance(resource, dict) and isinstance(resource.get("type"), str)
                and isinstance(resource.get("id"), str), "Included workflow resource invalid")
        identity = (resource["type"], resource["id"])
        require(identity not in seen, "Duplicate included workflow resource")
        seen.add(identity)
        attrs = resource.get("attributes")
        require(isinstance(attrs, dict), "Included resource attributes unavailable")
        rel = resource.get("relationships", {})
        require(isinstance(rel, dict), "Included resource relationships invalid")
        comparable.append((identity, attrs, {k: v.get("data") for k, v in rel.items()
                                             if isinstance(v, dict) and "data" in v}))
    require(("ciProducts", link(item, "product", "ciProducts")) in seen
            and ("scmRepositories", link(item, "repository", "scmRepositories")) in seen,
            "Included workflow product or repository unavailable")
    return item, sorted(comparable, key=lambda value: value[0])


def checked_configuration(workflow, expected_product, expected_repo):
    a = attributes(workflow)
    require(all(key in a for key in REQUIRED_FIELDS), "Workflow key configuration fields are missing")
    require(a.get("isEnabled") is True and a.get("isLockedForEditing") is False,
            "Workflow must be enabled and not locked for editing")
    require(link(workflow, "product", "ciProducts") == expected_product, "Workflow product changed")
    require(link(workflow, "repository", "scmRepositories") == expected_repo, "Workflow repository changed")
    actions = a.get("actions")
    require(isinstance(actions, list) and all(isinstance(x, dict) for x in actions),
            "Workflow actions unavailable")
    require(all(any(x.get("actionType") == kind for x in actions) for kind in ("BUILD", "TEST", "ARCHIVE")),
            "Workflow must contain Build, Test and Archive actions")
    selected = [x for x in actions if x.get("actionType") in ("BUILD", "TEST", "ARCHIVE")]
    require(all(isinstance(x.get("name"), str) and x["name"].strip()
                and isinstance(x.get("scheme"), str) and x["scheme"].strip()
                and isinstance(x.get("platform"), str) and x["platform"].strip() for x in selected),
            "Build, Test or Archive action details unavailable")
    ios_tests = [x for x in selected if x.get("actionType") == "TEST" and x.get("name") == "Test - iOS"]
    require(len(ios_tests) == 1 and ios_tests[0].get("isRequiredToPass") is True
            and ios_tests[0].get("platform") == "IOS", "Test - iOS must uniquely be a required iOS test")
    test_config = ios_tests[0].get("testConfiguration")
    require(isinstance(test_config, dict) and test_config.get("kind") in ("USE_SCHEME_SETTINGS", "SPECIFIC_TEST_PLANS")
            and isinstance(test_config.get("testDestinations"), list) and bool(test_config["testDestinations"]),
            "Required iOS test configuration unavailable")
    require(all(valid_destination(destination) for destination in test_config["testDestinations"]),
            "Required iOS test destination structure invalid")
    if test_config["kind"] == "SPECIFIC_TEST_PLANS":
        require(isinstance(test_config.get("testPlanName"), str) and test_config["testPlanName"].strip(),
                "Required iOS test plan name unavailable")
    # Include every returned attribute and relationship. The timestamp must change
    # after an edit; links may be regenerated, so compare relationship data only.
    baseline = {k: v for k, v in a.items() if k not in {"manualBranchStartCondition", "lastModifiedDate"}}
    relationships = workflow.get("relationships")
    require(isinstance(relationships, dict), "Workflow relationships unavailable")
    relations = {k: v.get("data") for k, v in relationships.items() if isinstance(v, dict) and "data" in v}
    require(all(key in relations for key in REQUIRED_RELATIONSHIPS),
            "Workflow relationship data unavailable")
    return baseline, relations


def configure(client, target, run_id, app, apply_change, current_main=github_branch):
    require(re.fullmatch(r"[0-9a-f]{40}", target) is not None, "Invalid target SHA")
    require(UUID.fullmatch(run_id) is not None, "Invalid canceled run ID")
    require(re.fullmatch(r"[0-9]+", app) is not None, "Invalid app ID")
    require(current_main("main") == target, "GitHub main moved from dispatch SHA")
    run = request_data(client, "/v1/ciBuildRuns/" + run_id + "?include=workflow,product,sourceBranchOrTag",
                       "ciBuildRuns", run_id)
    a = attributes(run)
    require(source_sha(run) == target and a.get("isPullRequestBuild") is False,
            "Run does not match current main SHA")
    require(a.get("executionProgress") == "COMPLETE" and a.get("completionStatus") == "CANCELED",
            "Run is not completed and canceled")
    workflow_id = link(run, "workflow", "ciWorkflows")
    product_id = link(run, "product", "ciProducts")
    ref_id = link(run, "sourceBranchOrTag", "scmGitReferences")
    app_product = request_data(client, "/v1/apps/" + app + "/ciProduct", "ciProducts")
    require(app_product.get("id") == product_id, "Run belongs to a different app")
    check_branch(client, ref_id)
    before, before_included = read_workflow(client, workflow_id, report=True)
    repo_id = link(before, "repository", "scmRepositories")
    repo = request_data(client, "/v1/scmRepositories/" + repo_id, "scmRepositories", repo_id)
    repo_attrs = attributes(repo)
    require(repo_attrs.get("ownerName") == "GodisinHisHeaven" and repo_attrs.get("repositoryName") == "ohMyTss"
            and repo_attrs.get("httpCloneUrl") in {"https://github.com/GodisinHisHeaven/ohMyTss",
                                                  "https://github.com/GodisinHisHeaven/ohMyTss.git"},
            "Cloud repository identity differs")
    refs = client.all("/v1/scmRepositories/" + repo_id + "/gitReferences?limit=200")
    require(sum(isinstance(x, dict) and x.get("id") == ref_id for x in refs) == 1,
            "Cloud main ref does not belong to workflow repository")
    snapshot = checked_configuration(before, product_id, repo_id)
    before_attrs = attributes(before)
    require(isinstance(before_attrs.get("lastModifiedDate"), str) and before_attrs["lastModifiedDate"],
            "Workflow modification timestamp unavailable")
    require("manualBranchStartCondition" in before_attrs and before_attrs["manualBranchStartCondition"] is None,
            "Existing manual branch condition is non-null or could not be read")
    print("Preflight passed; TestFlight post-action settings are not exposed by this API.")
    print("Apple does not document an atomic conditional PATCH; concurrent edits may race.")
    if not apply_change:
        print("Read-only mode; no workflow updated or build started.")
        return
    require(current_main("main") == target, "GitHub main changed before PATCH")
    # Refresh immediately before the write; never overwrite a newly set condition
    # or any configuration that changed after the original preflight.
    latest, latest_included = read_workflow(client, workflow_id)
    require(latest_included == before_included and checked_configuration(latest, product_id, repo_id) == snapshot,
            "Workflow configuration changed before PATCH")
    latest_attrs = attributes(latest)
    require(latest_attrs.get("lastModifiedDate") == before_attrs["lastModifiedDate"],
            "Workflow modification timestamp changed before PATCH")
    require("manualBranchStartCondition" in latest_attrs and latest_attrs["manualBranchStartCondition"] is None,
            "Manual branch condition changed before PATCH")
    body = {"data": {"type": "ciWorkflows", "id": workflow_id,
                     "attributes": {"manualBranchStartCondition": CONDITION}}}
    request = Request("https://api.appstoreconnect.apple.com/v1/ciWorkflows/" + workflow_id,
                      data=json.dumps(body).encode(), method="PATCH",
                      headers={"Authorization": "Bearer " + client.token,
                               "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with client.opener.open(request, timeout=15) as response:
            if response.status != 200:
                raise Unknown("PATCH outcome unknown; inspect configuration before any retry")
            payload = json.load(response)
    except HTTPError as exc:
        if exc.code in (400, 401, 403, 404, 409, 422):
            raise Unknown("PATCH rejected (HTTP %d); no automatic retry" % exc.code) from None
        raise Unknown("PATCH outcome unknown; inspect configuration before any retry") from None
    except (URLError, OSError, ValueError, HTTPException):
        raise Unknown("PATCH outcome unknown; inspect configuration before any retry") from None
    if not isinstance(payload, dict) or not isinstance(payload.get("data"), dict):
        raise Unknown("PATCH may have applied; inspect configuration before any retry")
    try:
        after, after_included = read_workflow(client, workflow_id)
        require(after_included == before_included, "Included workflow configuration changed")
        require(attributes(after).get("manualBranchStartCondition") == CONDITION,
                "Manual condition readback differs")
        require(checked_configuration(after, product_id, repo_id) == snapshot,
                "Other visible workflow configuration changed")
        require(current_main("main") == target, "GitHub main changed during update")
    except (Unknown, Retry, OSError, ValueError, TypeError, AttributeError, HTTPException):
        raise Unknown("PATCH may have applied but readback failed; inspect before retrying or starting a build") from None
    print("Manual main condition confirmed; all other API-visible workflow fields are unchanged.")
    print("No build started; a real build and TestFlight verification remain required.")


def main():
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Wrong event")
    require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Wrong dispatch branch")
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Wrong repository")
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Workflow rerun is forbidden")
    credentials = [os.environ.get(k) for k in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY")]
    require(all(credentials), "ASC credentials missing")
    apply = os.environ.get("APPLY_CHANGE")
    require(apply in ("true", "false"), "Explicit apply choice required")
    client = Client(*credentials, deadline=time.monotonic() + 180)
    configure(client, os.environ.get("GITHUB_SHA", ""), os.environ.get("CANCELED_RUN_ID", ""),
              os.environ.get("ASC_APP_ID", ""), apply == "true")


if __name__ == "__main__":
    try:
        main()
    except (Unknown, Retry, KeyError) as exc:
        print("Configuration stopped:", str(exc) if not isinstance(exc, KeyError) else "Required environment missing",
              file=sys.stderr)
        sys.exit(1)
