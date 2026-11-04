#!/usr/bin/env python3
"""Check release prerequisites without building or starting a simulator."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
REPO = "GodisinHisHeaven/ohMyTss"
REMOTE = "https://github.com/" + REPO + ".git"
REQUIRED = ("Quick checks", "iOS unit and UI tests")
CHECK_URL = re.compile(r"^https://github\.com/GodisinHisHeaven/ohMyTss/actions/runs/([0-9]+)/job/[0-9]+/?$")


def command(args):
    # The Git and GitHub CLI subprocesses do not need release credentials.
    env = {key: value for key, value in os.environ.items()
           if key not in {"STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET", "ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_PRIVATE_KEY"}}
    try:
        result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=60, check=True)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("A Git or GitHub prerequisite could not be verified") from None
    return result.stdout


def remote_main():
    parts = command(["git", "ls-remote", "--heads", REMOTE, "refs/heads/main"]).strip().split()
    if len(parts) != 2 or not re.fullmatch(r"[0-9a-f]{40}", parts[0]) or parts[1] != "refs/heads/main":
        raise ValueError("Could not establish the remote main commit")
    return parts[0]


def latest_required_run(pages):
    if not isinstance(pages, list):
        raise ValueError("GitHub returned an invalid check list")
    checks = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("check_runs"), list):
            raise ValueError("GitHub returned an invalid check list")
        checks.extend(page["check_runs"])
    run_ids = set()
    for name in REQUIRED:
        candidates = [check for check in checks if isinstance(check, dict) and check.get("name") == name
                      and isinstance(check.get("app"), dict) and check["app"].get("slug") == "github-actions"]
        if not candidates or any(not isinstance(check.get("id"), int) for check in candidates):
            raise ValueError("Required GitHub checks are missing or ambiguous")
        latest = max(candidates, key=lambda check: check["id"])
        if latest.get("status") != "completed" or latest.get("conclusion") != "success":
            raise ValueError("The latest required GitHub checks have not passed")
        url = latest.get("details_url")
        match = CHECK_URL.fullmatch(url) if isinstance(url, str) else None
        if not match:
            raise ValueError("A required check has an unexpected source")
        run_ids.add(match.group(1))
    if len(run_ids) != 1:
        raise ValueError("Required checks must belong to the same main-branch run")
    return run_ids.pop()


def verify_run(run, sha):
    if (not isinstance(run, dict) or run.get("head_sha") != sha or run.get("head_branch") != "main"
            or run.get("event") not in {"push", "workflow_dispatch"}
            or run.get("path") != ".github/workflows/pr-tests.yml"
            or run.get("status") != "completed" or run.get("conclusion") != "success"):
        raise ValueError("The exact main-commit test run has not passed")


def check_strava_config(path):
    if not path.is_file():
        raise ValueError("The ignored Strava build configuration is missing")
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"\s*(STRAVA_CLIENT_ID|STRAVA_CLIENT_SECRET)\s*=\s*([^\s]+)\s*", line)
        if match:
            values[match.group(1)] = match.group(2)
    client_id = values.get("STRAVA_CLIENT_ID", "")
    secret = values.get("STRAVA_CLIENT_SECRET", "")
    if (not re.fullmatch(r"[0-9]+", client_id) or not re.fullmatch(r"[A-Za-z0-9_-]+", secret)
            or secret in {"SET_ME", "YOUR_STRAVA_CLIENT_SECRET"}):
        raise ValueError("The Strava build configuration is missing or contains placeholders")


def main():
    try:
        if command(["git", "status", "--porcelain", "--untracked-files=normal"]).strip():
            raise ValueError("The release checkout has uncommitted changes")
        sha = command(["git", "rev-parse", "HEAD"]).strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha) or remote_main() != sha:
            raise ValueError("The release checkout is not the current remote main commit")
        check_strava_config(ROOT / "onMyTss/Config/Secrets.xcconfig")
        pages = json.loads(command(["gh", "api", "--paginate", "--slurp",
                                    f"repos/{REPO}/commits/{sha}/check-runs?per_page=100"]))
        run_id = latest_required_run(pages)
        run = json.loads(command(["gh", "api", f"repos/{REPO}/actions/runs/{run_id}"]))
        verify_run(run, sha)
        if remote_main() != sha:
            raise ValueError("Main changed while release prerequisites were checked")
        print(f"Release preflight passed for {sha}; required checks passed in run {run_id}.")
        print("Archive this commit once, upload it, then verify its TestFlight build.")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("Release preflight failed:", str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
