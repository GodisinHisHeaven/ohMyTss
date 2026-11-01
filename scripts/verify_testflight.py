#!/usr/bin/env python3
"""Verify an exact Xcode Cloud commit reached an internal TestFlight group.

Exit codes: 0 verified, 1 definite build failure, 2 unknown/configuration,
3 timed out waiting for evidence. The tool performs only App Store Connect GETs.
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

BASE = "https://api.appstoreconnect.apple.com"


class Unknown(Exception):
    pass


class Retry(Exception):
    pass


class Failed(Exception):
    pass


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_signature(signature):
    """Convert OpenSSL's ASN.1 ECDSA signature to JOSE's fixed-width R || S."""
    def length(pos):
        if pos >= len(signature):
            raise ValueError("invalid signature")
        value = signature[pos]
        pos += 1
        if value & 0x80:
            count = value & 0x7f
            if not count or count > 2 or pos + count > len(signature):
                raise ValueError("invalid signature")
            value = int.from_bytes(signature[pos:pos + count], "big")
            pos += count
        return value, pos

    if not signature or signature[0] != 0x30:
        raise ValueError("invalid signature")
    total, pos = length(1)
    if pos + total != len(signature):
        raise ValueError("invalid signature")
    values = []
    for _ in range(2):
        if pos >= len(signature) or signature[pos] != 2:
            raise ValueError("invalid signature")
        size, pos = length(pos + 1)
        if not size or pos + size > len(signature):
            raise ValueError("invalid signature")
        raw = signature[pos:pos + size]
        pos += size
        if raw[0] & 0x80:
            raise ValueError("invalid signature")
        raw = raw.lstrip(b"\0") or b"\0"
        if len(raw) > 32:
            raise ValueError("invalid signature")
        values.append(raw.rjust(32, b"\0"))
    if pos != len(signature):
        raise ValueError("invalid signature")
    return b"".join(values)


def create_token(issuer, key_id, private_key):
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = (header + "." + payload).encode("ascii")
    try:
        # mkstemp is mode 0600; the file is removed even on signing failure.
        fd, path = tempfile.mkstemp(prefix="asc-key-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as key_file:
                key_file.write(private_key)
            child_env = {key: value for key, value in os.environ.items()
                         if key not in {"ASC_PRIVATE_KEY", "ASC_ISSUER_ID", "ASC_KEY_ID"}}
            result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", path], input=signing_input,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, check=True,
                                    env=child_env)
            signature = der_signature(result.stdout)
        finally:
            os.unlink(path)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise Unknown("Could not sign with the supplied ASC private key using openssl") from None
    return header + "." + payload + "." + b64(signature)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, issuer, key_id, private_key, deadline):
        self.credentials = (issuer, key_id, private_key)
        self.deadline = deadline
        self.opener = build_opener(NoRedirect())
        self.token = None
        self.token_time = 0

    def get(self, path):
        url = urljoin(BASE, path)
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com" or parsed.username or parsed.password:
            raise Unknown("ASC returned an unsafe pagination URL")
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Retry("Time limit reached")
        if not self.token or time.monotonic() - self.token_time >= 480:
            self.token = create_token(*self.credentials)
            self.token_time = time.monotonic()
        request = Request(url, headers={"Authorization": "Bearer " + self.token, "Accept": "application/json"})
        try:
            with self.opener.open(request, timeout=min(15, remaining)) as response:
                body = json.load(response)
        except HTTPError as exc:
            if exc.code == 429 or 500 <= exc.code < 600:
                raise Retry("ASC temporarily unavailable (HTTP %d)" % exc.code) from None
            raise Unknown("ASC request was rejected (HTTP %d); check access and configuration" % exc.code) from None
        except (URLError, TimeoutError, OSError):
            raise Retry("ASC network request failed") from None
        except (ValueError, UnicodeError):
            raise Unknown("ASC returned invalid JSON") from None
        if not isinstance(body, dict):
            raise Unknown("ASC returned an unexpected response")
        return body

    def all(self, path):
        items, visited = [], set()
        while path:
            url = urljoin(BASE, path)
            if url in visited or len(visited) >= 1000:
                raise Unknown("ASC returned invalid pagination")
            visited.add(url)
            page = self.get(url)
            data = page.get("data")
            if not isinstance(data, list):
                raise Unknown("ASC returned an unexpected list")
            items.extend(data)
            links = page.get("links") or {}
            if not isinstance(links, dict):
                raise Unknown("ASC returned invalid pagination")
            path = links.get("next")
            if path is not None and not isinstance(path, str):
                raise Unknown("ASC returned invalid pagination")
        return items


def resource_id(resource):
    value = resource.get("id") if isinstance(resource, dict) else None
    if not isinstance(value, str) or not value:
        raise Unknown("ASC returned a resource without an ID")
    return quote(value, safe="")


def attributes(resource):
    value = resource.get("attributes") if isinstance(resource, dict) else None
    if not isinstance(value, dict):
        raise Unknown("ASC returned a resource without attributes")
    return value


def run_is_main(client, run):
    run_id = resource_id(run)
    response = client.get("/v1/ciBuildRuns/%s?include=sourceBranchOrTag" % run_id)
    details = response.get("data")
    if resource_id(details) != run_id:
        raise Unknown("Xcode Cloud returned the wrong run")
    relationships = details.get("relationships") or {}
    relation = relationships.get("sourceBranchOrTag") if isinstance(relationships, dict) else None
    linkage = relation.get("data") if isinstance(relation, dict) else None
    if not isinstance(linkage, dict) or linkage.get("type") != "scmGitReferences" or not linkage.get("id"):
        raise Unknown("Xcode Cloud source branch is unavailable")
    included = response.get("included")
    if not isinstance(included, list):
        raise Unknown("Xcode Cloud source branch is unavailable")
    refs = [ref for ref in included if isinstance(ref, dict) and ref.get("type") == "scmGitReferences"
            and ref.get("id") == linkage["id"]]
    if len(refs) != 1:
        raise Unknown("Xcode Cloud source branch is unavailable")
    ref = attributes(refs[0])
    if not isinstance(ref.get("kind"), str) or not isinstance(ref.get("canonicalName"), str):
        raise Unknown("Xcode Cloud source branch is unavailable")
    return ref["kind"] == "BRANCH" and ref["canonicalName"] == "refs/heads/main"


def verify_once(client, app_id, group_name, commit, expected_run_id=None):
    app = quote(app_id, safe="")
    product = resource_id(client.get("/v1/apps/%s/ciProduct" % app).get("data"))
    groups = client.all("/v1/apps/%s/betaGroups?limit=200" % app)
    matching = [g for g in groups if attributes(g).get("name") == group_name]
    if len(matching) != 1 or attributes(matching[0]).get("isInternalGroup") is not True:
        raise Unknown("Target group must uniquely identify an internal beta group for this app")
    group = resource_id(matching[0])
    runs = client.all("/v1/ciProducts/%s/buildRuns?sort=-number&limit=200" % product)
    exact = []
    for run in runs:
        a = attributes(run)
        source = a.get("sourceCommit") or {}
        sha = source.get("commitSha") if isinstance(source, dict) else None
        if (isinstance(sha, str) and sha.lower() == commit and a.get("isPullRequestBuild") is False
                and run_is_main(client, run)):
            exact.append(run)
    if not exact:
        raise Retry("Waiting for a main-branch Xcode Cloud run for the exact commit")
    if expected_run_id is not None and not any(r.get("id") == expected_run_id for r in exact):
        raise Retry("Waiting for the newly created Xcode Cloud run to appear")
    # An older successful retry must not hide a newer failed or running retry.
    if any(not isinstance(attributes(r).get("number"), int) for r in exact):
        raise Unknown("Xcode Cloud run number is unavailable")
    exact.sort(key=lambda r: attributes(r)["number"], reverse=True)
    if len(exact) > 1 and attributes(exact[0])["number"] == attributes(exact[1])["number"]:
        raise Unknown("Xcode Cloud run ordering is ambiguous")
    run = exact[0]
    run_id, state = resource_id(run), attributes(run)
    status = state.get("completionStatus")
    if status == "CANCELED":
        reason = state.get("cancelReason")
        # Apple documents a string, not an enum. Never emit arbitrary server text
        # or control characters into Actions logs.
        safe_reason = reason if isinstance(reason, str) and re.fullmatch(r"[A-Z][A-Z_]{1,63}", reason) else "unavailable"
        raise Failed("Xcode Cloud run was canceled (cancelReason: %s)" % safe_reason)
    if status in {"FAILED", "ERRORED", "SKIPPED"}:
        raise Failed("Xcode Cloud run failed or was canceled")
    if state.get("executionProgress") != "COMPLETE" or status != "SUCCEEDED":
        raise Retry("Waiting for Xcode Cloud run completion")
    actions = client.all("/v1/ciBuildRuns/%s/actions?limit=200" % run_id)
    action_attrs = [attributes(a) for a in actions]
    post_actions = [a for a in action_attrs if a.get("name") == "TestFlight Internal Testing - iOS"]
    if len(post_actions) != 1 or post_actions[0].get("actionType") != "TEST":
        raise Unknown("The unique TestFlight Internal Testing - iOS action is unavailable")
    post_action = post_actions[0]
    if post_action.get("completionStatus") in {"FAILED", "ERRORED", "CANCELED", "SKIPPED"}:
        raise Failed("Xcode Cloud TestFlight internal testing post-action did not succeed")
    if post_action.get("completionStatus") != "SUCCEEDED" or post_action.get("executionProgress") != "COMPLETE":
        raise Retry("Waiting for the TestFlight internal testing post-action to complete")
    for kind in ("BUILD", "TEST", "ARCHIVE"):
        selected = [a for a in action_attrs if a.get("actionType") == kind]
        if not selected:
            raise Unknown("Required %s action is absent" % kind)
        if any(a.get("completionStatus") in {"FAILED", "ERRORED", "CANCELED", "SKIPPED"} for a in selected):
            raise Failed("Xcode Cloud %s action did not succeed" % kind)
        if any(a.get("completionStatus") != "SUCCEEDED" or a.get("executionProgress") != "COMPLETE" for a in selected):
            raise Retry("Waiting for Xcode Cloud %s action completion" % kind)
        if kind == "TEST":
            ios = [a for a in selected if a.get("name") == "Test - iOS"]
            if len(ios) != 1 or ios[0].get("isRequiredToPass") is not True:
                raise Unknown("The unique Test - iOS action is not marked required to pass")
    builds = client.all("/v1/ciBuildRuns/%s/builds?limit=200" % run_id)
    if not builds:
        raise Retry("Waiting for the run's App Store Connect build")
    group_builds = client.all("/v1/betaGroups/%s/builds?limit=200" % group)
    group_ids = {resource_id(b) for b in group_builds}
    pending = False
    for build in builds:
        build_id = resource_id(build)
        detail = client.get("/v1/builds/%s" % build_id).get("data")
        values = attributes(detail)
        if values.get("processingState") in {"FAILED", "INVALID"} or values.get("expired") is True:
            continue
        if values.get("processingState") != "VALID" or values.get("expired") is not False or build_id not in group_ids:
            pending = True
            continue
        beta = attributes(client.get("/v1/builds/%s/buildBetaDetail" % build_id).get("data"))
        if beta.get("internalBuildState") == "IN_BETA_TESTING":
            return {"runNumber": state["number"], "buildVersion": values.get("version"), "commit": commit}
        pending = True
    if pending:
        raise Retry("Waiting for a valid build in the target group with internal testing active")
    raise Failed("All builds from the matching run are invalid or expired")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-id", default=os.environ.get("ASC_APP_ID"))
    parser.add_argument("--group", default=os.environ.get("ASC_BETA_GROUP"))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--expected-run-id", help="Wait for this newly created run to appear")
    parser.add_argument("--timeout-seconds", type=int, default=3600)
    parser.add_argument("--poll-seconds", type=int, default=30)
    args = parser.parse_args(argv)
    credentials = tuple(os.environ.get(k) for k in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY"))
    if not all(credentials) or not args.app_id or not args.group:
        print("UNKNOWN: ASC credentials, app ID, and internal beta group are required", file=sys.stderr)
        return 2
    if (not re.fullmatch(r"[0-9a-fA-F]{40}", args.commit) or args.timeout_seconds <= 0 or args.poll_seconds <= 0
            or (args.expected_run_id is not None and not re.fullmatch(r"[0-9a-fA-F-]{36}", args.expected_run_id))):
        print("UNKNOWN: a full 40-character commit, valid expected run ID, and positive timeouts are required", file=sys.stderr)
        return 2
    deadline = time.monotonic() + args.timeout_seconds
    client = Client(*credentials, deadline)
    last = "No ASC response"
    while time.monotonic() < deadline:
        try:
            result = verify_once(client, args.app_id, args.group, args.commit.lower(), args.expected_run_id)
            print("VERIFIED " + json.dumps(result, sort_keys=True))
            return 0
        except Failed as exc:
            print("FAILED: " + str(exc), file=sys.stderr)
            return 1
        except Unknown as exc:
            print("UNKNOWN: " + str(exc), file=sys.stderr)
            return 2
        except Retry as exc:
            last = str(exc)
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(args.poll_seconds, remaining))
    print("TIMEOUT: " + last, file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
