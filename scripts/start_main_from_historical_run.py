#!/usr/bin/env python3
"""Start at most one current-main Cloud run using a historical run as context."""
import json
import os
import re
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, build_opener

from configure_cloud_manual_main import (checked_configuration, is_checked_out_ancestor,
                                         manual_main_coverage, read_workflow)
from retry_canceled_cloud_run import (REPOSITORY, check_branch, github_branch, link,
                                      request_data, require, source_sha)
from verify_testflight import Client, NoRedirect, Retry, Unknown, attributes

WORKFLOW_FILE = "start-main-from-history.yml"
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
DEFINITE_REJECTIONS = {400, 401, 403, 404, 409, 422}


class ExplicitPostRejection(Exception):
    pass


def require_unique_dispatch(target, run_id, token, opener=None):
    """Fail closed if another dispatch exists or this one isn't yet visible."""
    require(re.fullmatch(r"[0-9a-f]{40}", target) is not None, "Invalid target SHA")
    require(isinstance(run_id, str) and re.fullmatch(r"[1-9][0-9]*", run_id) is not None,
            "Invalid GitHub run ID")
    require(isinstance(token, str) and bool(token), "GitHub read token unavailable")
    query = urlencode({"event": "workflow_dispatch", "head_sha": target, "per_page": 100})
    url = ("https://api.github.com/repos/" + REPOSITORY + "/actions/workflows/" + WORKFLOW_FILE
           + "/runs?" + query)
    request = Request(url, headers={"Authorization": "Bearer " + token,
                                    "Accept": "application/vnd.github+json"})
    try:
        with (opener or build_opener(NoRedirect())).open(request, timeout=15) as response:
            payload = json.load(response)
    except Exception:
        raise Unknown("GitHub dispatch history unavailable; do not start a build") from None
    runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
    total = payload.get("total_count") if isinstance(payload, dict) else None
    require(type(total) is int and total == 1 and isinstance(runs, list) and len(runs) == 1,
            "Dispatch history is ambiguous or contains another run for this SHA")
    item = runs[0]
    require(isinstance(item, dict) and type(item.get("id")) is int and str(item["id"]) == run_id
            and item.get("head_sha") == target and item.get("event") == "workflow_dispatch"
            and item.get("run_attempt") == 1,
            "This first-attempt dispatch cannot be uniquely verified")


def require_no_current_run(client, product_id, target, old_id, old_sha):
    """Require a complete, unambiguous Apple list containing the known old run."""
    runs = client.all("/v1/ciProducts/" + product_id + "/buildRuns?sort=-number&limit=200")
    require(isinstance(runs, list), "Cloud build list unavailable")
    seen = set()
    for run in runs:
        require(isinstance(run, dict) and run.get("type") == "ciBuildRuns", "Cloud build list malformed")
        run_id = run.get("id")
        require(isinstance(run_id, str) and UUID.fullmatch(run_id) and run_id not in seen,
                "Cloud build list has an invalid or duplicate ID")
        seen.add(run_id)
        sha = source_sha(run)
        require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha),
                "Cloud build has an unknown source SHA; inspect before starting")
        require(sha != target, "A Cloud build already exists for current main; inspect before starting")
        if run_id == old_id:
            require(sha == old_sha, "Historical build list source differs")
    require(old_id in seen, "Historical build is not visible in the complete Cloud list")


def start(client, target, old_id, app, run_id, token, *, current_main=github_branch,
          ancestor_check=is_checked_out_ancestor, dispatch_check=require_unique_dispatch,
          pause=time.sleep):
    require(re.fullmatch(r"[0-9a-f]{40}", target) is not None, "Invalid target SHA")
    require(isinstance(old_id, str) and UUID.fullmatch(old_id), "Invalid historical run ID")
    require(re.fullmatch(r"[0-9]+", app) is not None, "Invalid app ID")
    require(current_main("main") == target, "GitHub main moved from target")
    dispatch_check(target, run_id, token)
    old = request_data(client, "/v1/ciBuildRuns/" + old_id + "?include=workflow,product,sourceBranchOrTag",
                       "ciBuildRuns", old_id)
    a = attributes(old)
    old_sha = source_sha(old)
    require(isinstance(old_sha, str) and re.fullmatch(r"[0-9a-f]{40}", old_sha)
            and old_sha != target and a.get("isPullRequestBuild") is False,
            "Historical run source is invalid or not historical main")
    require(a.get("executionProgress") == "COMPLETE" and a.get("completionStatus") == "CANCELED",
            "Historical run is not completed and canceled")
    require(ancestor_check(old_sha, target), "Historical run is not a verified current-main ancestor")
    workflow_id = link(old, "workflow", "ciWorkflows")
    product_id = link(old, "product", "ciProducts")
    ref_id = link(old, "sourceBranchOrTag", "scmGitReferences")
    require(all(UUID.fullmatch(value) for value in (workflow_id, product_id, ref_id)),
            "Historical run relationship ID is invalid")
    app_product = request_data(client, "/v1/apps/" + app + "/ciProduct", "ciProducts")
    require(app_product.get("id") == product_id, "Historical run belongs to a different app")
    workflows = client.all("/v1/ciProducts/" + product_id + "/workflows?limit=200")
    require(isinstance(workflows, list) and len(workflows) == 1 and isinstance(workflows[0], dict)
            and workflows[0].get("type") == "ciWorkflows" and workflows[0].get("id") == workflow_id,
            "Historical run workflow is not the app's sole current workflow")
    check_branch(client, ref_id)
    before, before_included = read_workflow(client, workflow_id)
    repository_id = link(before, "repository", "scmRepositories")
    require(UUID.fullmatch(repository_id) is not None, "Workflow repository ID is invalid")
    repo = request_data(client, "/v1/scmRepositories/" + repository_id, "scmRepositories", repository_id)
    repo_attrs = attributes(repo)
    require(repo_attrs.get("ownerName") == "GodisinHisHeaven" and repo_attrs.get("repositoryName") == "ohMyTss"
            and repo_attrs.get("httpCloneUrl") in {"https://github.com/GodisinHisHeaven/ohMyTss",
                                                  "https://github.com/GodisinHisHeaven/ohMyTss.git"},
            "Cloud repository identity differs")
    refs = client.all("/v1/scmRepositories/" + repository_id + "/gitReferences?limit=200")
    require(sum(isinstance(ref, dict) and ref.get("id") == ref_id for ref in refs) == 1,
            "Cloud main ref does not belong to workflow repository")
    snapshot = checked_configuration(before, product_id, repository_id)
    before_attrs = attributes(before)
    require(manual_main_coverage(before_attrs.get("manualBranchStartCondition")) == "exact main",
            "Manual branch condition is not exactly main")
    modified = before_attrs.get("lastModifiedDate")
    require(isinstance(modified, str) and bool(modified), "Workflow modification timestamp unavailable")
    require_no_current_run(client, product_id, target, old_id, old_sha)

    # Re-read without changing the workflow. No check is atomic with the POST.
    latest, latest_included = read_workflow(client, workflow_id)
    require(latest_included == before_included and checked_configuration(latest, product_id, repository_id) == snapshot
            and attributes(latest).get("lastModifiedDate") == modified
            and manual_main_coverage(attributes(latest).get("manualBranchStartCondition")) == "exact main",
            "Cloud workflow changed during preflight")
    check_branch(client, ref_id)
    require_no_current_run(client, product_id, target, old_id, old_sha)
    dispatch_check(target, run_id, token)
    require(current_main("main") == target, "GitHub main changed before POST")

    body = {"data": {"type": "ciBuildRuns", "relationships": {
        "workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}},
        "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref_id}}}}}
    request = Request("https://api.appstoreconnect.apple.com/v1/ciBuildRuns",
                      data=json.dumps(body).encode(), method="POST",
                      headers={"Authorization": "Bearer " + client.token,
                               "Content-Type": "application/json", "Accept": "application/json"})
    # This is the only POST; never retry on a lost or malformed response.
    # Only an HTTPError from opening the request is an explicit rejection.
    try:
        response = client.opener.open(request, timeout=15)
    except HTTPError as error:
        if type(error.code) is int and error.code in DEFINITE_REJECTIONS:
            raise Unknown("POST rejected (HTTP %d); no automatic retry; inspect before any new dispatch"
                          % error.code) from None
        raise Unknown("POST may have created a run; inspect ASC and do not dispatch again") from None
    except Exception:
        raise Unknown("POST may have created a run; inspect ASC and do not dispatch again") from None
    try:
        with response:
            if response.status in DEFINITE_REJECTIONS:
                raise ExplicitPostRejection(response.status)
            require(response.status == 201, "Unexpected POST status")
            payload = json.load(response)
        created = payload.get("data") if isinstance(payload, dict) else None
        require(isinstance(created, dict) and created.get("type") == "ciBuildRuns", "Malformed POST response")
        new_id = created.get("id")
        require(isinstance(new_id, str) and UUID.fullmatch(new_id), "Cloud run ID unavailable")
    except ExplicitPostRejection as error:
        raise Unknown("POST rejected (HTTP %d); no automatic retry; inspect before any new dispatch"
                      % error.args[0]) from None
    except Exception:
        raise Unknown("POST may have created a run; inspect ASC and do not dispatch again") from None
    try:
        print("Created Cloud run:", new_id, flush=True)
        for attempt in range(10):
            new = request_data(client, "/v1/ciBuildRuns/" + new_id + "?include=workflow,product,sourceBranchOrTag",
                               "ciBuildRuns", new_id)
            if source_sha(new) is not None:
                break
            if attempt < 9:
                pause(3)
        require(source_sha(new) == target and attributes(new).get("isPullRequestBuild") is False,
                "New run SHA or type differs")
        require(link(new, "workflow", "ciWorkflows") == workflow_id
                and link(new, "product", "ciProducts") == product_id
                and link(new, "sourceBranchOrTag", "scmGitReferences") == ref_id, "New run identity differs")
        require(current_main("main") == target, "GitHub main changed after POST")
        print("New Cloud run has the expected main SHA:", target)
    except Exception:
        raise Unknown("Cloud run %s may exist; inspect ASC and do not dispatch again" % new_id) from None
    return new_id


def main():
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Wrong event")
    require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Wrong dispatch branch")
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Wrong repository")
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Workflow rerun is forbidden")
    require(os.environ.get("CONFIRM_START") == "true", "Explicit start confirmation is required")
    target = os.environ.get("GITHUB_SHA", "")
    require(os.environ.get("TARGET_SHA") == target, "Target must equal current dispatch SHA")
    credentials = [os.environ.get(key) for key in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY")]
    require(all(credentials), "ASC credentials missing")
    output_path = os.environ.get("GITHUB_OUTPUT")
    require(bool(output_path), "GitHub Actions output is unavailable")
    client = Client(*credentials, deadline=time.monotonic() + 180)
    try:
        new_id = start(client, target, os.environ.get("HISTORICAL_RUN_ID", ""), os.environ.get("ASC_APP_ID", ""),
                       os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("GH_READ_TOKEN", ""))
    except (Unknown, Retry):
        raise
    except Exception:
        raise Unknown("Unexpected failure; a run may exist; inspect ASC and do not dispatch again") from None
    try:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write("run_id=" + new_id + "\n")
    except Exception:
        raise Unknown("Cloud run %s may exist; inspect ASC and do not dispatch again" % new_id) from None


if __name__ == "__main__":
    try:
        main()
    except (Unknown, Retry, KeyError) as error:
        print("Start stopped:", str(error) if not isinstance(error, KeyError) else "Required environment missing",
              file=sys.stderr)
        sys.exit(1)
