#!/usr/bin/env python3
"""Verify an explicitly named build is available to an internal TestFlight group.

This is a read-only App Store Connect check. Apple build metadata does not prove
which Git commit produced the uploaded archive; keep that evidence separately.
"""
import argparse
import os
import re
import sys
import time

from verify_testflight import Client, Retry, Unknown, attributes, resource_id


def internal_build_state(client, app_id, group_name, version, build_number):
    groups = client.all(f"/v1/apps/{app_id}/betaGroups?limit=200")
    matches = [row for row in groups if attributes(row).get("name") == group_name]
    if len(matches) != 1 or attributes(matches[0]).get("isInternalGroup") is not True:
        raise Unknown("The target must be one unique internal testing group")
    auto_access = attributes(matches[0]).get("hasAccessToAllBuilds")
    if not isinstance(auto_access, bool):
        raise Unknown("Automatic internal-group access is unknown")
    group_id = resource_id(matches[0])

    builds = client.all(f"/v1/apps/{app_id}/builds?limit=200")
    candidates = []
    for row in builds:
        if attributes(row).get("version") != build_number:
            continue
        build_id = resource_id(row)
        release = attributes(client.get(f"/v1/builds/{build_id}/preReleaseVersion").get("data"))
        if release.get("version") == version and release.get("platform") == "IOS":
            candidates.append(row)
    if not candidates:
        raise Retry("Waiting for the uploaded build to appear")
    if len(candidates) != 1:
        raise Unknown("The requested iOS version and build are ambiguous")

    build_id = resource_id(candidates[0])
    details = client.get(f"/v1/builds/{build_id}").get("data")
    if resource_id(details) != build_id:
        raise Unknown("Apple returned a different build")
    values = attributes(details)
    if values.get("version") != build_number:
        raise Unknown("Build identity differs")
    if values.get("expired") is True or values.get("processingState") in {"FAILED", "INVALID"}:
        raise Unknown("The build is expired or invalid")
    if values.get("processingState") != "VALID" or values.get("expired") is not False:
        raise Retry("Apple is processing the build")
    if values.get("buildAudienceType") != "INTERNAL_ONLY":
        raise Unknown("The build is not marked for internal-only testing")

    linked = any(resource_id(row) == build_id for row in
                 client.all(f"/v1/betaGroups/{group_id}/builds?limit=200"))
    beta = attributes(client.get(f"/v1/builds/{build_id}/buildBetaDetail").get("data"))
    state = beta.get("internalBuildState")
    if state in {"PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE", "EXPIRED", "IN_EXPORT_COMPLIANCE_REVIEW"}:
        raise Unknown("Apple reports the build requires attention: " + state)
    if state not in {"PROCESSING", "READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}:
        raise Unknown("Apple returned an unknown internal testing state")
    if not linked and not auto_access:
        raise Unknown("The build is not assigned to the internal group and automatic access is disabled")
    if not linked or state != "IN_BETA_TESTING":
        raise Retry("Waiting for the build to be available to the internal group")
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--app-id", default=os.environ.get("ASC_APP_ID", "6755509363"))
    parser.add_argument("--group", default=os.environ.get("ASC_BETA_GROUP", "close door"))
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    parser.add_argument("--poll-seconds", type=int, default=30)
    args = parser.parse_args(argv)
    if (not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.version)
            or len(args.version) > 40 or not re.fullmatch(r"[0-9]{1,20}", args.build)
            or not re.fullmatch(r"[0-9]{1,20}", args.app_id)
            or not args.group or len(args.group) > 120 or any(ord(c) < 32 for c in args.group)
            or not 1 <= args.timeout_seconds <= 5400 or not 1 <= args.poll_seconds <= 300):
        parser.error("Invalid version, build, app ID, group, or polling interval")
    credentials = [os.environ.get(name) for name in ("ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY")]
    if not all(credentials):
        print("Verification failed: App Store Connect credentials are missing", file=sys.stderr)
        return 2
    deadline = time.monotonic() + args.timeout_seconds
    client = Client(*credentials, deadline=deadline)
    last = None
    while time.monotonic() < deadline:
        try:
            internal_build_state(client, args.app_id, args.group, args.version, args.build)
            print(f"VERIFIED: iOS {args.version} ({args.build}) is available to the internal group")
            print("Source commit and archive provenance must be verified separately.")
            return 0
        except Retry as exc:
            if str(exc) != last:
                print("Waiting:", str(exc), flush=True)
                last = str(exc)
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(args.poll_seconds, remaining))
        except Unknown as exc:
            print("Verification failed:", str(exc), file=sys.stderr)
            return 2
    print("Verification timed out before internal testing was confirmed", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
