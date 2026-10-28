import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


ENTRY = Path(__file__).resolve().parents[1] / "test.py"
SPEC = importlib.util.spec_from_file_location("ohmytss_test_entry", ENTRY)
entry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(entry)


class TestReport(unittest.TestCase):
    def test_step_failure_writes_nonzero_report_and_redacts_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            pipeline = entry.Pipeline("quick", Path(directory), None, secrets=["sensitive-test-value"])
            code = "import sys; print('STRAVA_CLIENT_SECRET=sensitive-test-value'); sys.exit(9)"
            self.assertFalse(pipeline.step("failing", [sys.executable, "-c", code]))
            self.assertEqual(pipeline.finish("failed"), 1)
            report_text = (Path(directory) / "summary.json").read_text()
            log = (Path(directory) / "failing.log").read_text()
            self.assertNotIn("sensitive-test-value", report_text + log)
            self.assertIn("[REDACTED]", log)
            result = json.loads(report_text)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["steps"][0]["exitCode"], 9)
            self.assertEqual(result["steps"][0]["log"], "failing.log")

    def test_failure_details_and_result_bundle_survive_xcode_failure(self):
        data = {"totalTestCount": 2, "passedTests": 1, "failedTests": 1, "skippedTests": 0,
                "result": "Failed", "testFailures": [{"testIdentifier": "Suite/testThing", "failureText": "wrong result"}]}
        report = self.run_fake_xcode(65, json.dumps(data))
        self.assertEqual(report["status"], "failed")
        result = report["steps"][-1]
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["tests"]["testFailures"][0]["testIdentifier"], "Suite/testThing")
        self.assertEqual(result["tests"]["testFailures"][0]["failureText"], "wrong result")
        self.assertTrue(result["resultBundle"].endswith("ios-full.xcresult"))

    def test_missing_or_corrupt_result_never_passes(self):
        for contents in ("", "not json", "{}"):
            with self.subTest(contents=contents):
                report = self.run_fake_xcode(0, contents)
                self.assertEqual(report["status"], "failed")
                self.assertEqual(report["steps"][-1]["status"], "failed")
        report = self.run_fake_xcode(0, '{"result": "Passed"}', create_bundle=False)
        self.assertEqual(report["status"], "failed")
        self.assertIn("did not produce a result bundle", report["steps"][-1]["error"])

    def test_skips_are_reported_and_do_not_pass(self):
        data = {"totalTestCount": 2, "passedTests": 1, "failedTests": 0, "skippedTests": 1,
                "result": "Passed", "testFailures": []}
        report = self.run_fake_xcode(0, json.dumps(data))
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["steps"][-1]["tests"]["skippedTests"], 1)

    def test_empty_and_inconsistent_xcresult_are_rejected(self):
        for data in (
            {"totalTestCount": 0, "passedTests": 0, "failedTests": 0, "skippedTests": 0, "result": "Passed"},
            {"totalTestCount": 3, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"},
        ):
            with self.subTest(data=data), self.assertRaises(ValueError):
                entry.validate_xcresult(data)

    def test_auto_destination_ignores_old_or_unavailable_runtimes(self):
        data = {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-25-4": [{"name": "iPhone 17 Pro", "udid": "old", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                {"name": "iPhone 17 Pro", "udid": "preferred", "isAvailable": True},
                {"name": "iPhone 17 Pro", "udid": "unavailable", "isAvailable": False},
            ]}}
        self.assertEqual(entry.choose_destination(json.dumps(data)), "platform=iOS Simulator,id=preferred")
        with self.assertRaises(ValueError):
            entry.choose_destination(json.dumps({"devices": {}}))

    def test_simulator_boot_uses_explicit_udid_and_bounded_wait(self):
        pipeline = Mock()
        pipeline.step.return_value = True
        udid = "B25005BC-DF45-4EBA-8C34-752CAB10D134"
        self.assertTrue(entry.boot_simulator(pipeline, f"platform=iOS Simulator,id={udid}"))
        pipeline.step.assert_called_once_with("simulator-boot", ["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=300)

    def test_destination_without_valid_simulator_udid_reports_failure(self):
        bad_destinations = ("platform=iOS Simulator,name=iPhone 17 Pro", "platform=iOS,id=bad",
                            "platform=iOS Simulator,id=not-a-uuid", "platform=iOS Simulator,id=x,id=y")
        for destination in bad_destinations:
            with self.subTest(destination=destination), tempfile.TemporaryDirectory() as directory:
                pipeline = entry.Pipeline("full", Path(directory), destination, secrets=[])
                self.assertFalse(entry.boot_simulator(pipeline, destination))
                self.assertEqual(pipeline.finish("failed"), 1)
                report = json.loads((Path(directory) / "summary.json").read_text())
                self.assertEqual(report["steps"][-1]["name"], "simulator-boot")
                self.assertEqual(report["steps"][-1]["status"], "failed")
                self.assertIn("simulator", report["steps"][-1]["error"].lower())
                self.assertTrue((Path(directory) / "simulator-boot.log").is_file())

    def test_simulator_boot_failure_retains_log_and_fails_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            xcrun = bin_dir / "xcrun"
            xcrun.write_text('#!/bin/sh\nprintf "simulator unavailable\\n" >&2\nexit 42\n')
            xcrun.chmod(0o755)
            output = root / "output"
            output.mkdir()
            destination = "platform=iOS Simulator,id=B25005BC-DF45-4EBA-8C34-752CAB10D134"
            pipeline = entry.Pipeline("full", output, destination, secrets=[])
            with patch.dict(os.environ, {"PATH": f"{bin_dir}:{os.environ.get('PATH', '')}"}):
                self.assertFalse(entry.boot_simulator(pipeline, destination))
            self.assertEqual(pipeline.finish("failed"), 1)
            report = json.loads((output / "summary.json").read_text())
            self.assertEqual(report["steps"][-1]["exitCode"], 42)
            self.assertIn("simulator unavailable", (output / "simulator-boot.log").read_text())

    def test_swift_and_python_reports_cannot_pass_without_tests(self):
        with self.assertRaises(ValueError):
            entry.inspect_swift_output("Build complete!")
        with self.assertRaises(ValueError):
            entry.inspect_python_output("Ran 0 tests in 0.001s\n\nOK\n")
        with self.assertRaises(ValueError):
            entry.inspect_python_output("Ran 1 test in 0.001s\n\nOK (skipped=1)\n")

    def test_source_change_during_run_prevents_success(self):
        first = {"commit": "a", "tracked_diff_sha256": "b", "untracked_sha256": "c"}
        changed = {"commit": "a", "tracked_diff_sha256": "changed", "untracked_sha256": "c"}
        with tempfile.TemporaryDirectory() as directory, patch.object(entry, "metadata", side_effect=[first, changed]):
            pipeline = entry.Pipeline("quick", Path(directory), None, secrets=[])
            self.assertEqual(pipeline.finish("passed"), 1)
            report = json.loads((Path(directory) / "summary.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertFalse(report["sourceUnchangedDuringRun"])

    def test_missing_source_fingerprint_prevents_success(self):
        incomplete = {"commit": "a", "tracked_diff_sha256": None, "untracked_sha256": "c"}
        with tempfile.TemporaryDirectory() as directory, patch.object(entry, "metadata", return_value=incomplete):
            pipeline = entry.Pipeline("quick", Path(directory), None, secrets=[])
            self.assertEqual(pipeline.finish("passed"), 1)
            report = json.loads((Path(directory) / "summary.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIsNone(report["sourceUnchangedDuringRun"])

    def run_fake_xcode(self, exit_code, result_text, create_bundle=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            make_bundle = ('while [ "$#" -gt 0 ]; do\n'
                           '  if [ "$1" = "-resultBundlePath" ]; then shift; /bin/mkdir -p "$1"; fi\n'
                           '  shift\ndone\n') if create_bundle else ""
            (bin_dir / "xcodebuild").write_text(f"#!/bin/sh\n{make_bundle}exit {exit_code}\n")
            (bin_dir / "xcrun").write_text('#!/bin/sh\n/bin/cat "$OHMYTSS_FAKE_RESULT"\n')
            for path in bin_dir.iterdir():
                path.chmod(0o755)
            source = root / "result.json"
            source.write_text(result_text)
            output = root / "output"
            output.mkdir()
            pipeline = entry.Pipeline("full", output, "platform=iOS Simulator,id=test", secrets=[])
            with patch.dict(os.environ, {"PATH": f"{bin_dir}:{os.environ.get('PATH', '')}", "OHMYTSS_FAKE_RESULT": str(source)}):
                passed = entry.xcode_test(pipeline, root, "platform=iOS Simulator,id=test", "ios-full", [])
            pipeline.finish("passed" if passed else "failed")
            return json.loads((output / "summary.json").read_text())


if __name__ == "__main__":
    unittest.main()
