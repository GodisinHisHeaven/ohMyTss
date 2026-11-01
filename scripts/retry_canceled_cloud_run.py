#!/usr/bin/env python3
"""Guarded retry of a canceled current-main Xcode Cloud run; no automatic retries."""
import json
import os
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, build_opener

from verify_testflight import Client, NoRedirect, Unknown, Retry, attributes

REPOSITORY = "GodisinHisHeaven/ohMyTss"
UUID = re.compile(r"^[0-9a-fA-F-]{36}$")


def require(condition, message):
    if not condition:
        raise Unknown(message)


def github_branch(name):
    # Both the host and repository are constant. Do not follow redirects.
    path = quote(name, safe="")
    url = "https://api.github.com/repos/" + REPOSITORY + "/branches/" + path
    request = Request(url, headers={"Authorization": "Bearer " + os.environ["GH_READ_TOKEN"],
                                    "Accept": "application/vnd.github+json"})
    try:
        with build_opener(NoRedirect()).open(request, timeout=15) as response:
            data = json.load(response)
    except (HTTPError, URLError, OSError, ValueError):
        raise Unknown("GitHub branch lookup failed") from None
    commit = data.get("commit", {}) if isinstance(data, dict) else {}
    return commit.get("sha") if isinstance(commit, dict) else None


def link(resource, name, expected_type):
    relations = resource.get("relationships") or {}
    relation = relations.get(name) if isinstance(relations, dict) else None
    item = relation.get("data") if isinstance(relation, dict) else None
    require(isinstance(item, dict) and item.get("type") == expected_type,
            "Missing or unexpected " + name + " relationship")
    value = item.get("id")
    require(isinstance(value, str) and UUID.fullmatch(value), "Invalid relationship ID")
    return value


def request_data(client, path, expected_type, expected_id=None):
    item = client.get(path).get("data")
    require(isinstance(item, dict) and item.get("type") == expected_type,
            "Unexpected ASC resource")
    if expected_id is not None:
        require(item.get("id") == expected_id, "Unexpected ASC resource ID")
    return item


def source_sha(item):
    source = attributes(item).get("sourceCommit")
    return source.get("commitSha") if isinstance(source, dict) else None


def main_allowed(workflow):
    attrs = attributes(workflow)
    require(attrs.get("isEnabled") is True, "Workflow is not enabled")
    condition = attrs.get("manualBranchStartCondition")
    source = condition.get("source") if isinstance(condition, dict) else None
    require(isinstance(source, dict), "Manual branch start condition unavailable")
    if source.get("isAllMatch") is True:
        return True
    if source.get("isAllMatch") is not False:
        return False
    patterns = source.get("patterns")
    if not isinstance(patterns, list):
        return False
    # Only accept an explicit literal; avoid guessing prefix/glob semantics.
    return any(isinstance(p, dict) and p.get("pattern") == "main"
               and p.get("isPrefix") is False for p in patterns)


def check_branch(client, ref_id):
    ref = request_data(client, "/v1/scmGitReferences/" + ref_id, "scmGitReferences", ref_id)
    a = attributes(ref)
    require(a.get("kind") == "BRANCH" and a.get("canonicalName") == "refs/heads/main"
            and a.get("isDeleted") is False, "Cloud reference is not active main")


def recover(client, target, run_id, app, current_main=github_branch):
    require(re.fullmatch(r"[0-9a-f]{40}", target) is not None, "Invalid target SHA")
    require(UUID.fullmatch(run_id) is not None, "Invalid canceled run ID")
    require(re.fullmatch(r"[0-9]+", app) is not None, "Invalid app ID")
    require(current_main("main") == target, "GitHub main moved from target")
    old = request_data(client, "/v1/ciBuildRuns/" + run_id + "?include=workflow,product,sourceBranchOrTag",
                       "ciBuildRuns", run_id)
    a = attributes(old)
    require(source_sha(old) == target and a.get("isPullRequestBuild") is False,
            "Canceled run does not match target SHA")
    require(a.get("executionProgress") == "COMPLETE" and a.get("completionStatus") == "CANCELED",
            "Original run is not completed and canceled")
    reason = a.get("cancelReason")
    known_reason = (isinstance(reason, str) and 0 < len(reason) <= 256
                    and bool(reason.strip()) and reason.isprintable())
    # Apple documents free text. Use it as evidence without writing that text
    # to logs unless it has the restricted format of a safe enum-like value.
    safe_reason = reason if known_reason and re.fullmatch(r"[A-Z][A-Z_]{1,63}", reason) else "unavailable"
    print("cancelReason:", safe_reason)
    require(known_reason, "Cancellation reason unavailable or invalid; retry blocked")
    workflow_id = link(old, "workflow", "ciWorkflows")
    product_id = link(old, "product", "ciProducts")
    ref_id = link(old, "sourceBranchOrTag", "scmGitReferences")
    app_product = request_data(client, "/v1/apps/" + app + "/ciProduct", "ciProducts")
    require(app_product.get("id") == product_id, "Run belongs to a different app")
    check_branch(client, ref_id)
    workflow = request_data(client, "/v1/ciWorkflows/" + workflow_id + "?include=repository,product",
                            "ciWorkflows", workflow_id)
    require(link(workflow, "product", "ciProducts") == product_id, "Wrong workflow product")
    repository_id = link(workflow, "repository", "scmRepositories")
    repo = request_data(client, "/v1/scmRepositories/" + repository_id, "scmRepositories", repository_id)
    repo_attrs = attributes(repo)
    require(repo_attrs.get("ownerName") == "GodisinHisHeaven"
            and repo_attrs.get("repositoryName") == "ohMyTss", "Cloud repository identity differs")
    require(repo_attrs.get("httpCloneUrl") in {
        "https://github.com/GodisinHisHeaven/ohMyTss",
        "https://github.com/GodisinHisHeaven/ohMyTss.git",
    }, "Cloud repository URL differs")
    refs = client.all("/v1/scmRepositories/" + repository_id + "/gitReferences?limit=200")
    matching = [x for x in refs if isinstance(x, dict) and x.get("id") == ref_id]
    require(len(matching) == 1, "Main ref does not belong to workflow repository")
    require(main_allowed(workflow), "Workflow manual condition does not clearly permit main")
    print("Verified canceled run, app, Cloud workflow, main ref, and manual condition.")
    # Do not create another run if any newer run exists for this workflow/ref/SHA.
    runs = client.all("/v1/ciWorkflows/" + workflow_id + "/buildRuns?sort=-number&limit=200")
    old_number = a.get("number")
    require(isinstance(old_number, int) and not isinstance(old_number, bool), "Run number unavailable")
    for run in runs:
        ra = attributes(run)
        number = ra.get("number")
        require(isinstance(number, int) and not isinstance(number, bool), "Invalid run number")
        if number > old_number:
            newer_sha = source_sha(run)
            require(isinstance(newer_sha, str) and re.fullmatch(r"[0-9a-f]{40}", newer_sha),
                    "A newer run has an unknown SHA; inspect it before retrying")
            if newer_sha == target:
                raise Unknown("A newer run already exists for this SHA; inspect it before retrying")
    require(current_main("main") == target, "GitHub main changed before POST")
    body = {"data": {"type": "ciBuildRuns", "relationships": {
        "workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}},
        "sourceBranchOrTag": {"data": {"type": "scmGitReferences", "id": ref_id}}}}}
    # One POST only; a transport failure is ambiguous and must never be retried blindly.
    request = Request("https://api.appstoreconnect.apple.com/v1/ciBuildRuns",
                      data=json.dumps(body).encode(), method="POST",
                      headers={"Authorization": "Bearer " + client.token,
                               "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with client.opener.open(request, timeout=15) as response:
            if response.status != 201:
                raise Unknown("POST outcome is unknown; a run may exist; inspect ASC and do not dispatch again")
            payload = json.load(response)
    except (HTTPError, URLError, OSError, ValueError):
        raise Unknown("POST outcome is unknown; a run may exist; inspect ASC and do not dispatch again") from None
    created = payload.get("data") if isinstance(payload, dict) else None
    require(isinstance(created, dict) and created.get("type") == "ciBuildRuns",
            "POST may have created a run; inspect ASC and do not dispatch again")
    new_id = created.get("id")
    require(isinstance(new_id, str) and UUID.fullmatch(new_id), "POST may have created a run; ID unavailable; inspect ASC and do not dispatch again")
    print("Created Cloud run:", new_id, flush=True)
    try:
        # Apple may not attach a source commit immediately. GET is safe to poll;
        # never repeat the POST, even if these reads fail or time out.
        for attempt in range(10):
            new = request_data(client, "/v1/ciBuildRuns/" + new_id + "?include=workflow,product,sourceBranchOrTag",
                               "ciBuildRuns", new_id)
            if source_sha(new) is not None:
                break
            if attempt < 9:
                time.sleep(3)
        require(source_sha(new) == target, "New run SHA is missing or differs; inspect ASC")
        require(attributes(new).get("isPullRequestBuild") is False, "New run is a pull request")
        require(link(new, "workflow", "ciWorkflows") == workflow_id, "New run workflow differs")
        require(link(new, "product", "ciProducts") == product_id, "New run product differs")
        require(link(new, "sourceBranchOrTag", "scmGitReferences") == ref_id, "New run ref differs")
        require(current_main("main") == target, "GitHub main changed after POST; inspect ASC")
        print("New Cloud run has the expected main SHA:", target)
    except (Unknown, Retry, OSError, ValueError):
        raise Unknown("Cloud run %s may exist; inspect ASC and do not dispatch again" % new_id) from None
    return new_id


def main():
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Wrong event")
    require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Wrong dispatch branch")
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Wrong repository")
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Workflow rerun is forbidden")
    require(os.environ.get("TARGET_SHA") == os.environ.get("GITHUB_SHA"),
            "Retry is only allowed for the current main dispatch SHA")
    credentials = [os.environ.get(k) for k in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY")]
    require(all(credentials), "ASC credentials missing")
    client = Client(*credentials, deadline=time.monotonic() + 150)
    # Require the Actions output destination before any request is sent.
    output_path = os.environ.get("GITHUB_OUTPUT")
    require(bool(output_path), "GitHub Actions output is unavailable")
    new_id = recover(client, os.environ["TARGET_SHA"], os.environ.get("CANCELED_RUN_ID", ""),
                     os.environ.get("ASC_APP_ID", ""))
    try:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write("run_id=" + new_id + "\n")
    except OSError:
        raise Unknown("Cloud run %s may exist; inspect ASC and do not dispatch again" % new_id) from None


if __name__ == "__main__":
    try:
        main()
    except (Unknown, Retry, KeyError) as exc:
        print("Recovery stopped:", str(exc) if not isinstance(exc, KeyError) else "Required environment missing", file=sys.stderr)
        sys.exit(1)
