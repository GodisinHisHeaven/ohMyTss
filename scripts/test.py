#!/usr/bin/env python3
"""Run the project's local test layers and retain a machine-readable report.

Release runs automated checks only; it deliberately exits incomplete until the
device, Release-interaction and distribution gates are reviewed separately.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "onMyTss/onMyTss.xcodeproj"
BASELINES = ("fdab778b6b51181bd76c3627b765da8af5ed6eef",
             "c5c598787432a1836c41d5ddfe912cefb7b044b9")


def secret_values() -> list[str]:
    """Collect known credentials for log redaction without displaying their values."""
    values = [value for name, value in os.environ.items()
              if re.search(r"(?:SECRET|TOKEN|PASSWORD|CREDENTIAL|API_KEY)", name, re.IGNORECASE)
              or name == "STRAVA_CLIENT_ID"]
    path = ROOT / "onMyTss/Config/Secrets.xcconfig"
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r"\s*(?:STRAVA_CLIENT_ID|STRAVA_CLIENT_SECRET)\s*=\s*(.*?)\s*$", line)
            if match:
                values.append(match.group(1).split("//", 1)[0].split("#", 1)[0].strip().strip("\"'"))
    except (OSError, UnicodeError):
        pass
    return sorted({value for value in values if len(value) >= 4 and "$" not in value}, key=len, reverse=True)


def redact(text: str, secrets: list[str]) -> str:
    for secret in secrets:
        text = text.replace(secret, "[REDACTED]")
    # Never save resolved assignment values, even if the source was not local.
    return re.sub(r"(?im)\b(STRAVA_CLIENT_(?:ID|SECRET)\s*=\s*)[^\s]+", r"\1[REDACTED]", text)


def summarize_xcresult(data: dict) -> dict:
    """Extract counts and failures even when a test run did not pass."""
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests")
    if not all(type(data.get(key)) is int and data[key] >= 0 for key in keys):
        raise ValueError("xcresult is missing valid test counts")
    if data["passedTests"] + data["failedTests"] + data["skippedTests"] != data["totalTestCount"]:
        raise ValueError("xcresult test counts do not add up")
    failures = data.get("testFailures", [])
    if not isinstance(failures, list):
        raise ValueError("xcresult has invalid test failure details")
    return {key: data[key] for key in keys} | {
        "result": data.get("result"),
        "testFailures": failures,
        "devicesAndConfigurations": data.get("devicesAndConfigurations", []),
        "runtimeWarnings": data.get("runtimeWarnings", []),
    }


def validate_xcresult(data: dict) -> dict:
    summary = summarize_xcresult(data)
    if summary["totalTestCount"] == 0:
        raise ValueError("xcresult contains no executed tests")
    if summary["result"] != "Passed" or summary["failedTests"] or summary["skippedTests"]:
        raise ValueError("xcresult contains failures, skips, or an incomplete result")
    return summary


class TestResultError(ValueError):
    def __init__(self, message: str, summary: dict):
        super().__init__(message)
        self.summary = summary


def inspect_swift_output(text: str) -> dict:
    matches = re.findall(r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?", text)
    if not matches:
        raise ValueError("Swift test output has no XCTest total")
    count, failed = map(int, matches[-1])
    skipped = len(re.findall(r"(?m)^Test Case .* skipped \(", text))
    if count == 0 or failed or skipped:
        raise ValueError(f"Swift tests: {count} executed, {failed} failed, {skipped} skipped")
    return {"executed": count, "failed": failed, "skipped": skipped}


def inspect_python_output(text: str) -> dict:
    match = re.search(r"Ran (\d+) tests? in", text)
    if not match or int(match.group(1)) == 0 or not re.search(r"(?m)^OK\s*$", text):
        raise ValueError("Python unittest output is empty, failed, or contains skips")
    return {"executed": int(match.group(1)), "failed": 0, "skipped": 0}


def metadata(exclude_output: Path | None = None) -> dict:
    def capture(args: list[str]) -> str | None:
        try:
            return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, timeout=20, check=True).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None

    revision = capture(["git", "rev-parse", "HEAD"])
    status = capture(["git", "status", "--porcelain", "--untracked-files=all"])
    tracked_digest = None
    untracked_digest = None
    untracked_count = None
    try:
        diff = subprocess.run(["git", "diff", "--binary", "HEAD", "--"], cwd=ROOT, capture_output=True, timeout=60, check=True).stdout
        tracked_digest = hashlib.sha256(diff).hexdigest()
        listing = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT, capture_output=True, timeout=60, check=True).stdout
        paths = [path for path in listing.split(b"\0") if path]
        if exclude_output is not None:
            output_path = exclude_output.resolve()
            paths = [path for path in paths if not (ROOT / os.fsdecode(path)).absolute().is_relative_to(output_path)]
        digest = hashlib.sha256()
        for raw_path in sorted(paths):
            path = ROOT / os.fsdecode(raw_path)
            digest.update(len(raw_path).to_bytes(8, "big"))
            digest.update(raw_path)
            if path.is_symlink():
                digest.update(b"symlink\0" + os.fsencode(os.readlink(path)))
            elif path.is_file():
                digest.update(b"file\0")
                with path.open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(chunk)
            else:
                raise OSError("Untracked path is not a regular file or symbolic link")
        untracked_digest = digest.hexdigest()
        untracked_count = len(paths)
    except (OSError, subprocess.SubprocessError):
        pass
    return {"commit": revision, "dirty": None if status is None else bool(status),
            "modified_paths_count": None if status is None else len(status.splitlines()),
            "tracked_diff_sha256": tracked_digest, "untracked_count": untracked_count,
            "untracked_sha256": untracked_digest,
            "fingerprint_scope": "tracked diff against HEAD and non-ignored untracked files at start; ignored files excluded",
            "platform": platform.platform(), "xcode": capture(["xcodebuild", "-version"])}


class Pipeline:
    def __init__(self, mode: str, output: Path, destination: str | None, secrets: list[str] | None = None):
        self.output = output
        self.secrets = secret_values() if secrets is None else secrets
        self.report = {"schemaVersion": 1, "mode": mode, "status": "running",
                       "startedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                       "destination": destination, "metadata": metadata(output), "steps": [],
                       "manualGates": []}
        self.started = time.monotonic()
        self.write_report()

    def write_report(self) -> None:
        target = self.output / "summary.json"
        temporary = target.with_suffix(".tmp")
        def sanitize(value):
            if isinstance(value, str):
                return redact(value, self.secrets)
            if isinstance(value, list):
                return [sanitize(item) for item in value]
            if isinstance(value, dict):
                return {key: sanitize(item) for key, item in value.items()}
            return value
        temporary.write_text(json.dumps(sanitize(self.report), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(target)

    def step(self, name: str, args: list[str], *, timeout: int = 1800, parser=None) -> bool:
        print(f"[{name}] running", flush=True)
        log_path = self.output / f"{name}.log"
        started = time.monotonic()
        step = {"name": name, "status": "running", "log": log_path.name}
        self.report["steps"].append(step)
        self.write_report()
        output: list[str] = []
        try:
            process = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, encoding="utf-8", errors="replace", start_new_session=True)
            def drain() -> None:
                assert process.stdout is not None
                with process.stdout, log_path.open("w", encoding="utf-8") as log:
                    for line in process.stdout:
                        safe = redact(line, self.secrets)
                        log.write(safe)
                        log.flush()
                        output.append(safe)
            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                reader.join()
                raise TimeoutError(f"timed out after {timeout} seconds")
            reader.join()
            step["exitCode"] = code
            if code != 0:
                raise RuntimeError(f"command exited {code}")
            if parser:
                step["tests"] = parser("".join(output))
            step["status"] = "passed"
        except (OSError, RuntimeError, TimeoutError, ValueError) as error:
            step["status"] = "failed"
            if isinstance(error, TestResultError):
                step["tests"] = error.summary
            step["error"] = redact(str(error), self.secrets)
            print(f"[{name}] failed: {step['error']} (log: {log_path})", file=sys.stderr, flush=True)
        step["durationSeconds"] = round(time.monotonic() - started, 2)
        self.write_report()
        if step["status"] == "passed":
            print(f"[{name}] passed in {step['durationSeconds']}s", flush=True)
        return step["status"] == "passed"

    def finish(self, status: str) -> int:
        if status in ("passed", "incomplete"):
            end_metadata = metadata(self.output)
            fields = ("commit", "tracked_diff_sha256", "untracked_sha256")
            available = all(self.report["metadata"].get(field) is not None and end_metadata.get(field) is not None for field in fields)
            unchanged = available and all(self.report["metadata"][field] == end_metadata[field] for field in fields)
            self.report["sourceUnchangedDuringRun"] = unchanged if available else None
            if not unchanged:
                self.report["error"] = "Source changed during the run or its fingerprint could not be determined; rerun the checks."
                status = "failed"
        self.report["status"] = status
        self.report["finishedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.report["durationSeconds"] = round(time.monotonic() - self.started, 2)
        self.write_report()
        print(f"Report: {self.output / 'summary.json'} ({status})", flush=True)
        return {"passed": 0, "failed": 1, "incomplete": 2}[status]

    def fail_step(self, name: str, message: str) -> None:
        safe = redact(message, self.secrets)
        log = self.output / f"{name}.log"
        log.write_text(safe + "\n", encoding="utf-8")
        self.report["steps"].append({"name": name, "status": "failed", "error": safe,
                                     "log": log.name, "durationSeconds": 0.0})
        self.write_report()
        print(f"[{name}] failed: {safe} (log: {log})", file=sys.stderr, flush=True)


def choose_destination(raw_json: str) -> str:
    data = json.loads(raw_json)
    choices = []
    for runtime, devices in data.get("devices", {}).items():
        match = re.search(r"iOS-(\d+)-(\d+)", runtime)
        if not match or tuple(map(int, match.groups())) < (26, 1):
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone") and device.get("udid"):
                choices.append((tuple(map(int, match.groups())), device["name"] == "iPhone 17 Pro", device["udid"]))
    if not choices:
        raise ValueError("No available iPhone simulator with iOS 26.1 or later")
    return "platform=iOS Simulator,id=" + max(choices)[2]


def simulator_udid(destination: str) -> str:
    """Only boot a specifically identified simulator; do not guess by name."""
    components: dict[str, str] = {}
    for item in destination.split(","):
        key, separator, value = item.strip().partition("=")
        key = key.strip()
        if not separator or not key or key in components:
            raise ValueError("Destination must use unique key=value components and an iOS Simulator UDID")
        components[key] = value.strip()
    if components.get("platform") != "iOS Simulator":
        raise ValueError("Destination must specify platform=iOS Simulator and a simulator UDID")
    udid = components.get("id", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", udid):
        raise ValueError("Destination must include a valid simulator UDID as id=<UUID>; name alone is not sufficient")
    return udid


def boot_simulator(pipeline: Pipeline, destination: str) -> bool:
    try:
        udid = simulator_udid(destination)
    except ValueError as error:
        pipeline.fail_step("simulator-boot", str(error))
        return False
    return pipeline.step("simulator-boot", ["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=300)


def run_quick(pipeline: Pipeline, scratch: Path) -> bool:
    if not pipeline.step("swift-domain", ["swift", "test", "--scratch-path", str(scratch / "swift")], timeout=600, parser=inspect_swift_output):
        return False
    if not pipeline.step("ci-script-tests", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "onMyTss/ci_scripts/tests", "-v"], timeout=120, parser=inspect_python_output):
        return False
    if not pipeline.step("test-entry-tests", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "scripts/tests", "-v"], timeout=120, parser=inspect_python_output):
        return False
    binary = scratch / "verify-strava-http"
    sources = ["onMyTss/onMyTss/Services/StravaConfig.swift", "onMyTss/onMyTss/Services/AppIdentity.swift",
               "onMyTss/onMyTss/Services/StravaOAuth.swift", "onMyTss/onMyTss/Services/StravaAPI.swift",
               "scripts/VerifyStravaHTTP.swift"]
    def parse_http(text: str) -> dict:
        if "PASS: production Strava detail API; 9 synthetic HTTP/offline/decoding cases" not in text:
            raise ValueError("Strava synthetic HTTP checks did not report completion")
        return {"executed": 9, "failed": 0, "skipped": 0}
    return pipeline.step("strava-http-build", ["swiftc", "-swift-version", "5", "-parse-as-library", *sources, "-o", str(binary)], timeout=300) and pipeline.step("strava-http", [str(binary)], timeout=120, parser=parse_http)


def xcode_test(pipeline: Pipeline, scratch: Path, destination: str, name: str, extra: list[str]) -> bool:
    result = pipeline.output / f"{name}.xcresult"
    args = ["xcodebuild", "test", "-project", str(PROJECT), "-scheme", "onMyTss", "-destination", destination,
            "-derivedDataPath", str(scratch / "derived"), "-resultBundlePath", str(result),
            "-parallel-testing-enabled", "NO", "-enableCodeCoverage", "YES", "CODE_SIGNING_ALLOWED=NO", *extra]
    build_and_test_passed = pipeline.step(name, args, timeout=2400)
    if not result.is_dir():
        error = "xcodebuild did not produce a result bundle"
        log = pipeline.output / f"{name}-result.log"
        log.write_text(error + "\n", encoding="utf-8")
        pipeline.report["steps"].append({"name": name + "-result", "status": "failed", "error": error,
                                         "log": log.name, "resultBundle": str(result)})
        pipeline.write_report()
        print(f"[{name}-result] failed: {error}", file=sys.stderr)
        return False
    def parse_result(text: str) -> dict:
        try:
            data = json.loads(text)
            summary = summarize_xcresult(data)
            try:
                return validate_xcresult(data)
            except ValueError as error:
                raise TestResultError(str(error), summary) from error
        except (json.JSONDecodeError, TypeError) as error:
            raise ValueError(f"cannot parse xcresult summary: {error}") from error
    result_passed = pipeline.step(name + "-result", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--format", "json"], parser=parse_result)
    result_step = pipeline.report["steps"][-1]
    result_step["resultBundle"] = str(result)
    pipeline.write_report()
    return build_and_test_passed and result_passed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("quick", "full", "release"))
    parser.add_argument("--destination", help="xcodebuild destination, e.g. platform=iOS Simulator,id=UDID")
    parser.add_argument("--output-dir", type=Path, help="new or empty directory for logs, result bundle and summary")
    args = parser.parse_args(argv)
    if args.output_dir:
        output = args.output_dir.expanduser().resolve()
        if output.exists() and (not output.is_dir() or any(output.iterdir())):
            parser.error("--output-dir must be a new or empty directory")
        output.mkdir(parents=True, exist_ok=True)
    else:
        output = Path(tempfile.mkdtemp(prefix="ohmytss-tests-"))
    pipeline = Pipeline(args.mode, output, args.destination)
    try:
        with tempfile.TemporaryDirectory(prefix="ohmytss-test-build-") as temp:
            scratch = Path(temp)
            if not run_quick(pipeline, scratch):
                return pipeline.finish("failed")
            if args.mode == "quick":
                return pipeline.finish("passed")
            if platform.system() != "Darwin":
                pipeline.report["error"] = "full and release require macOS, Xcode and an iOS simulator"
                return pipeline.finish("failed")
            destination = args.destination
            if not destination:
                try:
                    result = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                                            text=True, capture_output=True, timeout=30, check=True)
                    destination = choose_destination(result.stdout)
                except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError) as error:
                    pipeline.report["error"] = redact(f"Could not choose a simulator: {error}", pipeline.secrets)
                    return pipeline.finish("failed")
            pipeline.report["destination"] = destination
            pipeline.report["iosScope"] = "Unsigned simulator build; not proof of device signing, HealthKit background delivery, or real Strava authorization."
            if not boot_simulator(pipeline, destination):
                return pipeline.finish("failed")
            if not xcode_test(pipeline, scratch, destination, "ios-full", []):
                return pipeline.finish("failed")
            if args.mode == "full":
                return pipeline.finish("passed")
            for baseline in BASELINES:
                if not pipeline.step("baseline-" + baseline[:8], ["git", "cat-file", "-e", baseline + "^{commit}"]):
                    pipeline.report["error"] = f"Migration baseline {baseline} is missing; fetch full history and retry."
                    return pipeline.finish("failed")
            for script in ("scripts/check_v2_migration.sh", "scripts/check_rpe_migration.sh"):
                if not pipeline.step(Path(script).stem, ["bash", script]):
                    return pipeline.finish("failed")
            # Release uses explicit, non-secret simulator values. It does not validate real Strava OAuth.
            fake = ["STRAVA_CLIENT_ID=123456", "STRAVA_CLIENT_SECRET=SIMULATOR_TEST_ONLY"]
            build = ["xcodebuild", "build", "-project", str(PROJECT), "-scheme", "onMyTss", "-configuration", "Release",
                     "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(scratch / "derived"),
                     "CODE_SIGNING_ALLOWED=NO", *fake]
            if not pipeline.step("release-build", build, timeout=3600):
                return pipeline.finish("failed")
            extra = ["-configuration", "Release", "-only-testing:onMyTssTests/ActivitySyncTests",
                     "-only-testing:onMyTssTests/BodyBatteryEngineNoWorkoutTests", "ENABLE_TESTABILITY=YES",
                     "CODE_SIGNING_ALLOWED=NO", *fake]
            if not xcode_test(pipeline, scratch, destination, "release-sync-tests", extra):
                return pipeline.finish("failed")
            pipeline.report["manualGates"] = [
                "Exercise optimized Release interactions, including saved-history upgrade, cancellation and 1000-workout retention.",
                "Verify applicable physical-device HealthKit, Strava, background delivery and Watch behavior.",
                "Verify the exact merge commit in Xcode Cloud and the TestFlight post-action before claiming delivery.",
            ]
            return pipeline.finish("incomplete")
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        pipeline.report["error"] = redact(str(error), pipeline.secrets)
        return pipeline.finish("failed")


if __name__ == "__main__":
    raise SystemExit(main())
