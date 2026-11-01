#!/usr/bin/env python3
"""Read-only inspection of Cloud runs for a verified main ancestor."""
import argparse
import json
import os
import re
import sys
import time
from urllib.parse import parse_qsl, urljoin, urlsplit

from configure_cloud_manual_main import is_checked_out_ancestor
from retry_canceled_cloud_run import (REPOSITORY, github_branch, link, request_data, require, source_sha)
from verify_testflight import Client, Unknown, attributes

BASE = "https://api.appstoreconnect.apple.com"
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SHA = re.compile(r"^[0-9a-f]{40}$")
PROGRESS = {"PENDING", "RUNNING", "COMPLETE"}
COMPLETION = {"SUCCEEDED", "FAILED", "ERRORED", "CANCELED", "SKIPPED"}
ACTION_TYPES = {"BUILD", "TEST", "ARCHIVE", "ANALYZE"}


def protected_main():
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Wrong event")
    require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Wrong dispatch branch")
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY, "Wrong repository")
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Workflow rerun is forbidden")
    dispatch_sha = os.environ.get("GITHUB_SHA", "")
    requested = os.environ.get("REQUESTED_SHA") or dispatch_sha
    require(SHA.fullmatch(dispatch_sha) is not None and SHA.fullmatch(requested) is not None,
            "Invalid SHA")
    require(github_branch("main") == dispatch_sha, "GitHub main changed")
    return dispatch_sha, requested


def preflight():
    # This step runs before any App Store Connect secret is passed to the job.
    dispatch_sha, requested = protected_main()
    require(is_checked_out_ancestor(requested, dispatch_sha), "Target is not a verified main ancestor")
    require(github_branch("main") == dispatch_sha, "GitHub main changed during preflight")
    output = os.environ.get("GITHUB_OUTPUT")
    require(bool(output), "GitHub output unavailable")
    with open(output, "a", encoding="utf-8") as file:
        file.write("target=" + requested + "\n")
    print("Read-only preflight passed; no Apple request was made.")


def safe_pages(client, path):
    """Fetch every page; next links must stay on the same ASC collection."""
    expected = urlsplit(urljoin(BASE, path)).path
    current = urljoin(BASE, path)
    pending = current
    seen = set()
    items = []
    initial_query = dict(parse_qsl(urlsplit(current).query, keep_blank_values=True, strict_parsing=True))
    while pending:
        require(isinstance(pending, str) and len(pending) <= 4096, "Invalid ASC pagination")
        url = urljoin(current, pending)
        parsed = urlsplit(url)
        require(parsed.scheme == "https" and parsed.netloc == "api.appstoreconnect.apple.com"
                and parsed.path == expected and not parsed.fragment and not parsed.username and not parsed.password,
                "Unsafe ASC pagination")
        try:
            query = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
        except ValueError:
            raise Unknown("Invalid ASC pagination") from None
        require(all(key in {"limit", "sort", "cursor"} and value and len(value) <= 2048
                    for key, value in query) and len({key for key, _ in query}) == len(query),
                "Unexpected ASC pagination parameters")
        params = dict(query)
        require({key: value for key, value in params.items() if key != "cursor"} == initial_query
                and (not seen or bool(params.get("cursor"))), "ASC pagination changed query or lacks cursor")
        require(url not in seen and len(seen) < 1000, "ASC pagination is incomplete or cyclic")
        seen.add(url)
        current = url
        page = client.get(url)
        data = page.get("data") if isinstance(page, dict) else None
        require(isinstance(data, list), "ASC list is unavailable")
        items.extend(data)
        links = page.get("links")
        require(isinstance(links, dict), "ASC pagination is unavailable")
        pending = links.get("next")
        require(pending is None or isinstance(pending, str) and bool(pending), "Invalid ASC next page")
    return items


def safe_status(item):
    a = attributes(item)
    progress = a.get("executionProgress")
    completion = a.get("completionStatus")
    require(isinstance(progress, str) and progress in PROGRESS, "Cloud progress unavailable")
    require(completion is None or isinstance(completion, str) and completion in COMPLETION,
            "Cloud completion unavailable")
    require((progress == "COMPLETE") == (completion is not None), "Cloud status is inconsistent")
    return progress, completion or "NOT_FINISHED"


def action_summary(client, run_id):
    actions = safe_pages(client, "/v1/ciBuildRuns/" + run_id + "/actions?limit=200")
    require(len(actions) <= 500, "Too many Cloud actions to inspect")
    result, seen = [], set()
    for action in actions:
        require(isinstance(action, dict) and action.get("type") == "ciBuildActions", "Cloud action unavailable")
        ident = action.get("id")
        require(isinstance(ident, str) and UUID.fullmatch(ident) and ident not in seen,
                "Cloud action identity unavailable")
        seen.add(ident)
        a = attributes(action)
        kind, name = a.get("actionType"), a.get("name")
        require(isinstance(kind, str) and kind in ACTION_TYPES and isinstance(name, str) and len(name) <= 1024,
                "Cloud action type unavailable")
        label = ("TEST_IOS" if kind == "TEST" and name == "Test - iOS" else
                 "TESTFLIGHT_POST_ACTION" if kind == "TEST" and name == "TestFlight Internal Testing - iOS" else kind)
        progress, completion = safe_status(action)
        required = a.get("isRequiredToPass")
        require(required is None or type(required) is bool, "Cloud action required state unavailable")
        result.append({"kind": label, "progress": progress, "completion": completion,
                       "required": "YES" if required is True else "NO" if required is False else "UNKNOWN"})
    return result


def inspect(client, app, target):
    require(isinstance(app, str) and re.fullmatch(r"[0-9]+", app), "Invalid app ID")
    require(isinstance(target, str) and SHA.fullmatch(target), "Invalid SHA")
    product = request_data(client, "/v1/apps/" + app + "/ciProduct", "ciProducts")
    product_id = product.get("id")
    require(isinstance(product_id, str) and UUID.fullmatch(product_id), "Cloud product identity unavailable")
    runs = safe_pages(client, "/v1/ciProducts/" + product_id + "/buildRuns?sort=-number&limit=200")
    seen, matches = set(), []
    for item in runs:
        require(isinstance(item, dict) and item.get("type") == "ciBuildRuns", "Cloud run unavailable")
        ident = item.get("id")
        require(isinstance(ident, str) and UUID.fullmatch(ident) and ident not in seen,
                "Cloud run identity unavailable")
        seen.add(ident)
        sha = source_sha(item)
        require(isinstance(sha, str) and SHA.fullmatch(sha), "Cloud run source SHA unavailable")
        if sha == target:
            matches.append((ident, item))
    require(len(matches) <= 100, "Too many matching Cloud runs to inspect")
    results, ignored = [], 0
    for ident, listed in matches:
        detail = request_data(client, "/v1/ciBuildRuns/" + ident + "?include=workflow,product,sourceBranchOrTag",
                              "ciBuildRuns", ident)
        a, listed_attrs = attributes(detail), attributes(listed)
        require(source_sha(detail) == target and type(a.get("isPullRequestBuild")) is bool
                and type(listed_attrs.get("isPullRequestBuild")) is bool
                and a["isPullRequestBuild"] == listed_attrs["isPullRequestBuild"], "Cloud run source changed")
        require(link(detail, "product", "ciProducts") == product_id, "Cloud run product differs")
        workflow_id = link(detail, "workflow", "ciWorkflows")
        require(UUID.fullmatch(workflow_id), "Cloud workflow identity unavailable")
        workflow = request_data(client, "/v1/ciWorkflows/" + workflow_id + "?include=repository,product",
                                "ciWorkflows", workflow_id)
        require(link(workflow, "product", "ciProducts") == product_id, "Cloud workflow product differs")
        repo_id = link(workflow, "repository", "scmRepositories")
        require(UUID.fullmatch(repo_id), "Cloud repository identity unavailable")
        repo = request_data(client, "/v1/scmRepositories/" + repo_id, "scmRepositories", repo_id)
        repo_attrs = attributes(repo)
        require(repo_attrs.get("ownerName") == "GodisinHisHeaven" and repo_attrs.get("repositoryName") == "ohMyTss"
                and repo_attrs.get("httpCloneUrl") in {"https://github.com/GodisinHisHeaven/ohMyTss",
                                                      "https://github.com/GodisinHisHeaven/ohMyTss.git"},
                "Cloud repository identity differs")
        if a["isPullRequestBuild"]:
            ignored += 1
            continue
        ref_id = link(detail, "sourceBranchOrTag", "scmGitReferences")
        require(UUID.fullmatch(ref_id), "Cloud reference identity unavailable")
        ref = request_data(client, "/v1/scmGitReferences/" + ref_id, "scmGitReferences", ref_id)
        ref_attrs = attributes(ref)
        canonical = ref_attrs.get("canonicalName")
        # Only classify verified branch references. Unknown kinds and malformed
        # or contradictory names cannot establish that a run is non-main.
        require(ref_attrs.get("kind") == "BRANCH" and isinstance(canonical, str)
                and re.fullmatch(r"refs/heads/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*", canonical) is not None
                and type(ref_attrs.get("isDeleted")) is bool, "Cloud reference details unavailable")
        require(not (ref_attrs["kind"] == "BRANCH" and ref_attrs["canonicalName"] == "refs/heads/main"
                     and ref_attrs["isDeleted"] is True), "Cloud main reference is deleted")
        refs = safe_pages(client, "/v1/scmRepositories/" + repo_id + "/gitReferences?limit=200")
        require(all(isinstance(ref, dict) and ref.get("type") == "scmGitReferences"
                    and isinstance(ref.get("id"), str) and UUID.fullmatch(ref["id"]) for ref in refs)
                and len({ref["id"] for ref in refs}) == len(refs), "Cloud repository references unavailable")
        require(sum(ref["id"] == ref_id for ref in refs) == 1, "Cloud reference does not belong to repository")
        if not (ref_attrs["canonicalName"] == "refs/heads/main" and ref_attrs["isDeleted"] is False):
            ignored += 1
            continue
        number = a.get("number")
        listed_number = listed_attrs.get("number")
        require(type(number) is int and type(listed_number) is int and 0 < number <= 2_147_483_647
                and number == listed_number,
                "Cloud run number unavailable")
        progress, completion = safe_status(detail)
        results.append({"id": ident, "number": number, "progress": progress, "completion": completion,
                        "actions": action_summary(client, ident)})
    require(len({run["number"] for run in results}) == len(results), "Cloud run ordering is ambiguous")
    return sorted(results, key=lambda run: run["number"], reverse=True), ignored


def lookup():
    dispatch_sha, requested = protected_main()
    require(os.environ.get("TARGET_SHA") == requested, "Preflight target differs")
    credentials = [os.environ.get(key) for key in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY")]
    require(all(credentials), "ASC credentials unavailable")
    client = Client(*credentials, deadline=time.monotonic() + 180)
    runs, ignored = inspect(client, os.environ.get("ASC_APP_ID", ""), requested)
    require(github_branch("main") == dispatch_sha, "GitHub main changed during inspection")
    print("READ_ONLY_CLOUD_LOOKUP " + json.dumps({"target": requested, "runs": runs,
                                                 "ignoredNonMain": ignored}, sort_keys=True))
    if not runs:
        print("No matching main run is visible in this complete list; visibility may be delayed.")
    print("Never repeat a POST because of an empty list. This is not TestFlight verification.")
    print("Run and action states are separate reads, not an atomic snapshot.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("preflight", "lookup"))
    args = parser.parse_args(argv)
    try:
        preflight() if args.mode == "preflight" else lookup()
    except Exception:
        print("UNKNOWN: read-only Cloud inspection incomplete; no conclusion; do not repeat POST", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
