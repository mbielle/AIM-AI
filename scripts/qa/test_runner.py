"""Behavioral checks for truthful results, bounded processes and session fences."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).parent))
import catalog
import run
import session
import app_pilot


class ReportingTests(unittest.TestCase):
    def test_macos_fence_protects_actual_home_not_redirected_qa_home(self):
        profile = run.macos_test_profile("/synthetic-owner")
        self.assertIn('(subpath "/synthetic-owner/Library/Application Support/AddressBook")', profile)
        self.assertIn('(deny mach-lookup', profile)
        self.assertIn('com.apple.contactsd.persistence', profile)
        self.assertIn('(deny file-read* file-write*', profile)


    def test_simulator_receipt_is_collected_from_exact_qa_container_and_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); output = root / "evidence"; output.mkdir()
            execution = type("Run", (), {"id": "a" * 32, "output": output})()
            source = root / "container/Library/Application Support/AIM-QA" / execution.id / "client-result.json"
            source.parent.mkdir(parents=True)
            source.write_text(json.dumps({"run_id": execution.id, "status": "passed"}))
            with patch.object(app_pilot.subprocess, "check_output", side_effect=lambda cmd, **kwargs: json.dumps({"devices": {"ios": [{"udid": "qa-uuid", "name": "AIM QA App Pilot", "state": "Booted"}]}}) if "devices" in cmd else str(root / "container")) as command:
                value = app_pilot.collect_client_receipt(execution, "qa-uuid")
                self.assertEqual(value["status"], "passed")
                self.assertEqual(command.call_args[0][0], ["xcrun", "simctl", "get_app_container", "qa-uuid", "com.aimai.ios.qa.pilot", "data"])
                self.assertEqual((output / "client-result.json").stat().st_mode & 0o777, 0o600)
                source.write_text(json.dumps({"run_id": "another-run", "status": "passed"}))
                with self.assertRaises(ValueError): app_pilot.collect_client_receipt(execution, "qa-uuid")


    def test_json_secrets_are_redacted_in_nested_and_prefixed_logs(self):
        payload = {"api_key": "qa-key", "nested": [{"accessToken": "qa-token",
            "Authorization": "Bearer qa-auth", "password": "qa-password",
            "clientSecret": {"parts": ["qa-composite"]}, "safe": "visible"}],
            "refresh-token": "qa-refresh", "secret": "quotes \\\" and spaces"}
        for sample in [json.dumps(payload), "log prefix " + json.dumps(payload) + " suffix",
                       '{"api\\u005fkey": "qa-escaped"}']:
            clean = run.redact(sample)
            for secret in ["qa-key", "qa-token", "qa-auth", "qa-password", "qa-composite", "qa-refresh", "qa-escaped", "quotes"]:
                self.assertNotIn(secret, clean)
        self.assertIn('"safe": "visible"', run.redact(json.dumps(payload)))
        self.assertEqual(run.redact(run.redact(json.dumps(payload))), run.redact(json.dumps(payload)))

    def test_assertion_failure_survives_network_and_prerequisite_messages(self):
        for message in ["Executed 2 tests, with 1 failure. Network is unreachable",
                        "Executed 4 tests, with 1 test skipped and 2 failures. Network is unreachable",
                        "Test Case '-[Fixture testX]' failed. Operation not permitted",
                        "Test run with 2 tests failed. CoreDeviceError"]:
            for code in [0, 1]:
                self.assertEqual(run.classify(code, message, tests=True)[0], run.FAIL)
        self.assertEqual(run.classify(1, "Network is unreachable", tests=True)[0], run.BLOCKED)
        self.assertEqual(run.classify(1, "Executed 2 tests, with 0 failures. Network is unreachable", tests=True)[0], run.FAIL)
        self.assertEqual(run.classify(-15, "Network is unreachable", timed_out=True)[0], run.FAIL)

    def test_only_ui_test_target_receives_private_run_configuration(self):
        value = {"TestConfigurations": [{"TestTargets": [
            {"BlueprintName": "AIMTests", "EnvironmentVariables": {}},
            {"BlueprintName": "AIMUITests", "EnvironmentVariables": {"existing": "preserved"}},
        ]}]}
        self.assertEqual(app_pilot.inject_test_environment(value, {"AIM_QA_RUN_ID": "synthetic"}), 1)
        targets = value["TestConfigurations"][0]["TestTargets"]
        self.assertEqual(targets[0]["EnvironmentVariables"], {})
        self.assertEqual(targets[1]["EnvironmentVariables"]["existing"], "preserved")
        self.assertEqual(targets[1]["EnvironmentVariables"]["AIM_QA_RUN_ID"], "synthetic")

    def test_native_runner_refuses_an_arbitrary_app_binary_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "owner-app"
            binary.write_text("This must never execute")
            output = Path(directory) / "report"
            code = run.main(["--target", "native", "--probe", str(binary), "--report-dir", str(output)])
            value = json.loads((output / "report.json").read_text())
            self.assertEqual(code, 2)
            self.assertEqual(value["steps"][0]["id"], "native-identity")
            self.assertNotIn("command", value["steps"][0])

    def test_zero_tests_and_preview_cannot_pass(self):
        self.assertEqual(run.classify(0, "Executed 0 tests", tests=True)[0], run.BLOCKED)
        self.assertEqual(run.classify(0, "Build succeeded", tests=True)[0], run.BLOCKED)
        self.assertEqual(run.classify(0, "Executed 2 tests, with 2 tests skipped and 0 failures", tests=True)[0], run.BLOCKED)
        self.assertEqual(run.classify(0, "Executed 2 tests, with 1 failure", tests=True)[0], run.FAIL)
        self.assertEqual(run.aggregate([{"status": run.NOT_RUN}]), run.BLOCKED)
        self.assertEqual(run.aggregate([]), run.BLOCKED)

    def test_failure_outweighs_missing_prerequisite(self):
        self.assertEqual(run.aggregate([{"status": run.FAIL}, {"status": run.BLOCKED}]), run.FAIL)
        self.assertEqual(run.classify(1, "assertion failed")[0], run.FAIL)
        self.assertEqual(run.classify(1, "Device is locked")[0], run.BLOCKED)
        self.assertEqual(run.classify(-15, "", timed_out=True)[0], run.FAIL)

    def test_success_requires_actual_nonempty_test_output(self):
        self.assertEqual(run.classify(0, "Executed 24 tests, with 0 failures", tests=True)[0], run.PASS)
        self.assertEqual(run.classify(0, "Test run with 4 tests passed", tests=True)[0], run.PASS)

    def test_logs_remove_authentication_material_and_invitation(self):
        sample = "Authorization: Bearer private-token\napi_key=private-key\naimdirect://pair?secret=private-code\nsk-abcdefghijklmnopqrstuv"
        clean = run.redact(sample)
        for secret in ["private-token", "private-key", "private-code", "sk-abcdefgh"]:
            self.assertNotIn(secret, clean)

    def test_requested_missing_device_writes_report_and_returns_preparation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"
            before = catalog.GATE.read_bytes()
            code = run.main(["--suite", "remote", "--target", "device", "--report-dir", str(output)])
            value = json.loads((output / "report.json").read_text())
            self.assertEqual(code, 2)
            self.assertFalse(value["publication_qualified"])
            self.assertEqual(value["steps"][0]["status"], run.BLOCKED)
            self.assertEqual(before, catalog.GATE.read_bytes())
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / "report.json").stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                run.main(["--target", "device", "--report-dir", str(output)])

    def test_timeout_kills_the_owned_process_group_and_keeps_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            args = type("Args", (), dict(suite="quick", target="software", dry_run=False,
                report_dir=str(Path(directory) / "run"), minutes=1, human_minutes=None, interruptions=None))()
            execution = run.Run(args)
            ok = execution.command("slow-child", [sys.executable, "-c", "import time;time.sleep(30)"], "software", timeout=.05)
            self.assertFalse(ok)
            self.assertEqual(execution.report["steps"][0]["status"], run.FAIL)
            self.assertLess(execution.report["steps"][0]["duration_seconds"], 10)

    def test_resource_lock_rejects_concurrent_control(self):
        with run.resource_lock("test-exclusive"):
            with self.assertRaises(BlockingIOError):
                with run.resource_lock("test-exclusive"):
                    self.fail("Concurrent access was admitted")


class ProcessIntegrationTests(unittest.TestCase):
    def test_xctest_counts_sum_bundles_and_do_not_double_selected_summaries(self):
        output = """Test Suite 'First.xctest' passed at today.
 Executed 10 tests, with 2 tests skipped and 0 failures
Test Suite 'Selected tests' passed at today.
 Executed 10 tests, with 2 tests skipped and 0 failures
Test Suite 'Second.xctest' failed at today.
 Executed 4 tests, with 1 failure
Test Suite 'Selected tests' failed at today.
 Executed 4 tests, with 1 failure
Test Suite 'Empty.xctest' passed at today.
 Executed 0 tests, with 0 failures
"""
        counts = run.xctest_bundle_counts(output)
        self.assertEqual((counts["selected"], counts["skipped"], counts["executed"], counts["failures"]), (14, 2, 12, 1))
        self.assertEqual(len(counts["bundles"]), 3)

    def test_initialization_trace_must_be_active_and_contacts_initialization_fails(self):
        ordinary = "objc[123]: INITIALIZE: thread 1: calling +[NSObject initialize]"
        self.assertEqual(run.validate_initialization_trace(ordinary), 1)
        for output in ["", "QA checks passed", ordinary + "\nobjc[123]: INITIALIZE: calling +[CNContactStore initialize]"]:
            with self.assertRaises(ValueError): run.validate_initialization_trace(output)

    def receipt(self, root, case="sourcekit"):
        at = datetime.now(timezone.utc)
        value = dict(schema=1, runID="a" * 32, caseID=case,
            originalTest=run.PROCESS_CASES[case]["original"], sourceSHA256="b" * 64,
            binarySHA256="c" * 64, namespace="com.aimai.macos.qualification." + "d" * 32,
            pid=123, startedAt=at.isoformat(), finishedAt=at.isoformat(), status="passed",
            physicalDevicesQualified=False, checks=[dict(id=name, expected="Expected fixture result", observed="Observed fixture result", passed=True)
                for name in sorted(run.PROCESS_CASES[case]["checks"] | {"startup-no-discovery", "finish-no-discovery"})])
        path = root / "receipt.json"
        path.write_text(json.dumps(value))
        return path, value, at.timestamp() - .1, at.timestamp() + 1

    def validate(self, path, value, start, end):
        return run.validate_process_receipt(path, value["caseID"], "a" * 32, "b" * 64, "c" * 64,
            "com.aimai.macos.qualification." + "d" * 32, start, end)

    def test_each_native_case_requires_all_named_positive_negative_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            for case in run.PROCESS_CASES:
                path, value, start, end = self.receipt(Path(directory), case)
                self.assertEqual(len(self.validate(path, value, start, end)["checks"]), 6)
                for checks in [[], value["checks"][:-1], value["checks"] + [value["checks"][0]]]:
                    altered = dict(value, checks=checks); path.write_text(json.dumps(altered))
                    with self.assertRaises(ValueError): self.validate(path, value, start, end)

    def test_native_receipt_missing_stale_wrong_source_binary_run_and_case_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value, start, end = self.receipt(Path(directory))
            for key in ["sourceSHA256", "binarySHA256", "runID", "originalTest", "namespace", "caseID", "status"]:
                altered = dict(value); altered[key] = "wrong"; path.write_text(json.dumps(altered))
                with self.assertRaises(ValueError): self.validate(path, value, start, end)
            path.write_text(json.dumps(value))
            with self.assertRaises(ValueError): self.validate(path, value, start + 10, end + 10)
            path.unlink()
            with self.assertRaises(OSError): self.validate(path, value, start, end)

    def test_malformed_native_receipts_are_rejected_without_type_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value, start, end = self.receipt(Path(directory))
            for malformed in [None, [], "text", dict(value, pid=True), dict(value, checks=None),
                    dict(value, checks="text"), dict(value, checks=[None]), dict(value, checks=[[]])]:
                path.write_text(json.dumps(malformed))
                with self.assertRaises(ValueError): self.validate(path, value, start, end)

    def test_single_method_selects_only_its_native_equivalent(self):
        with tempfile.TemporaryDirectory() as directory:
            args = type("Args", (), dict(suite="quick", target="software", component="macos", controls="F01",
                dry_run=True, report_dir=str(Path(directory) / "run"), minutes=1,
                human_minutes=None, interruptions=None))()
            execution = run.Run(args)
            controls = [{"id": "F01", "supporting_selectors": [{"package": "macos", "suites": ["CodeIntelligenceTests"]}]}]
            with patch.object(execution, "process_integrations") as native:
                execution.software(controls)
                native.assert_called_once_with(["sourcekit"])

    def test_failed_native_assertion_cannot_pass_even_with_success_status(self):
        with tempfile.TemporaryDirectory() as directory:
            path, value, start, end = self.receipt(Path(directory))
            value["checks"][0]["passed"] = False; path.write_text(json.dumps(value))
            with self.assertRaises(ValueError): self.validate(path, value, start, end)
        self.assertEqual(run.classify(-6, "")[0], run.FAIL)
        self.assertEqual(run.classify(0, "", timed_out=True)[0], run.FAIL)

    def test_native_routing_excludes_only_exact_original_methods_and_keeps_contacts_fence(self):
        with tempfile.TemporaryDirectory() as directory:
            args = type("Args", (), dict(suite="release", target="software", component="macos", controls="",
                dry_run=True, report_dir=str(Path(directory) / "run"), minutes=1,
                human_minutes=None, interruptions=None))()
            execution = run.Run(args)
            with patch.object(execution, "process_integrations") as native:
                execution.software([])
                native.assert_called_once_with(["sourcekit", "confinement"])
            step = next(s for s in execution.report["steps"] if s["id"] == "macos-tests")
            cmd = step["command"]
            self.assertEqual(cmd[0], "sandbox-exec")
            skips = [cmd[i+1] for i, arg in enumerate(cmd) if arg == "--skip"]
            self.assertEqual(len(skips), 2)
            for case in run.PROCESS_CASES.values():
                self.assertTrue(any(__import__("re").fullmatch(skip, case["original"]) for skip in skips))
            self.assertFalse(any(__import__("re").search(skip,
                "AIMMacPlatformTests.CodeIntelligenceTests/testClosedServerInputReturnsAnErrorWithoutTerminatingTheHost") for skip in skips))

    def test_quick_macos_selection_does_not_launch_unselected_native_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            args = type("Args", (), dict(suite="quick", target="software", component="macos", controls="",
                dry_run=True, report_dir=str(Path(directory) / "run"), minutes=1,
                human_minutes=None, interruptions=None))()
            execution = run.Run(args)
            with patch.object(execution, "process_integrations") as native:
                execution.software([])
                native.assert_not_called()
            self.assertNotIn("--skip", execution.report["steps"][0]["command"])


class DirectReceiptTests(unittest.TestCase):
    def exercise(self, mutation=None, missing=False):
        direct = run.direct_qualification()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); probe = root / "unexecuted-probe"; probe.write_text("fixture")
            args = type("Args", (), dict(suite="remote", target="native", dry_run=False,
                report_dir=str(root / "run"), minutes=1, human_minutes=None, interruptions=None, probe=str(probe)))()
            execution = run.Run(args)
            provenance = dict(sourceSHA256="b" * 64, binarySHA256="c" * 64,
                namespace="com.aimai.macos.qualification." + "d" * 32)
            calls = []
            def command(name, arguments, *unused, **kwargs):
                calls.append((arguments, kwargs))
                scenario = "permissions" if "--permission-edit" in arguments else "lifecycle"
                at = __import__("time").time()
                value = dict(schema=2, scenario=scenario, runID=execution.id, **provenance, status="passed",
                    startedAt=at, finishedAt=at, pairedVia="local-Bonjour-first", secureSignalling=False,
                    forcedRelay=False, nativeProcesses=2 if scenario == "permissions" else 3,
                    transportPath="lan", **direct.SCENARIOS[scenario])
                path = Path(arguments[arguments.index("--receipt") + 1])
                if not missing:
                    value = mutation(value) if mutation else value
                    path.write_text(value if isinstance(value, str) else json.dumps(value))
                execution.report["steps"].append(dict(id=name, status=run.PASS,
                    evidence_level="synthetic-child-stub", observed="No child process executed"))
                return True
            with patch.object(run, "direct_qualification", return_value=direct), patch.object(direct.build, "verify_probe", return_value=provenance), patch.object(execution, "command", side_effect=command):
                execution.native()
            return execution.report, calls

    def test_actual_native_method_rejects_QA13_empty_and_negative_receipts(self):
        for value in [{}, dict(nativeEffectCount=2, readOnlyOverviewSucceeded=False, removedChatEffectDenied=False,
                              physicalDevicesQualified=False, appIntegrationQualified=False)]:
            report, _ = self.exercise(lambda _: value)
            self.assertEqual(len(report["artifacts"]), 0)
            self.assertEqual(sum(step["status"] == run.FAIL for step in report["steps"]), 2)

    def test_actual_native_method_rejects_missing_malformed_wrong_run_source_binary_scenario(self):
        variants = [lambda _: "{broken", lambda _: None, lambda _: [], lambda value: dict(value, nativeEffectCount=True),
            lambda value: dict(value, physicalDevicesQualified=True), lambda value: dict(value, startedAt=0)]
        variants += [lambda value, key=key: dict(value, **{key: "wrong"}) for key in
                     ["scenario", "runID", "sourceSHA256", "binarySHA256", "namespace"]]
        for mutation in variants:
            report, _ = self.exercise(mutation)
            self.assertEqual(len(report["artifacts"]), 0)
            self.assertEqual(sum(step["status"] == run.FAIL for step in report["steps"]), 2)
        report, _ = self.exercise(missing=True)
        self.assertEqual(sum(step["status"] == run.FAIL for step in report["steps"]), 2)

    def test_actual_native_method_accepts_complete_both_receipts_and_passes_exact_run(self):
        report, calls = self.exercise()
        self.assertEqual(len(report["artifacts"]), 2)
        self.assertFalse(any(step["status"] == run.FAIL for step in report["steps"]))
        for command, kwargs in calls:
            self.assertEqual(command[command.index("--run-id") + 1], report["run_id"])
            self.assertNotIn("--coordinator", command)
            self.assertTrue(kwargs["cleanup_group"])
            self.assertEqual(kwargs["preparation_exit_codes"], (2,))


class RegistryTests(unittest.TestCase):
    def test_budget_transfer_and_lifecycle_mappings_are_actual_suites(self):
        controls = {c["id"]: c for c in catalog.registry()["controls"]}
        suites = lambda key: {s for group in controls[key]["supporting_selectors"] for s in group["suites"]}
        self.assertIn("GlobalSpendLedgerTests", suites("I08"))
        self.assertIn("DirectRemoteAccessTests", suites("R07"))
        self.assertIn("DirectConnectionLifecycleTests", suites("D05"))
        self.assertIn("NativeSkillsTests", suites("F08"))

    def test_unit_path_selects_aimtests_without_ui_or_device(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"
            args = type("Args", (), dict(suite="quick", target="simulator", dry_run=True,
                report_dir=str(output), minutes=1, human_minutes=None, interruptions=None,
                simulator=None, ios_tests="unit", ios_test_filter=[]))()
            execution = run.Run(args)
            execution.simulator()
            value = json.loads((output / "report.json").read_text())
            step = next(s for s in value["steps"] if s["id"] == "ios-unit")
            self.assertIn("-only-testing:AIMTests", step["command"])
            self.assertIn("AIM_APP_BUNDLE_IDENTIFIER=com.aimai.ios.qa.autonomy", step["command"])
            self.assertFalse(any("-only-testing:AIMUITests" in arg for arg in step["command"]))
            self.assertEqual(step["status"], run.NOT_RUN)


    def test_every_owner_gate_is_mapped_without_changing_its_expected_result(self):
        value = catalog.registry()
        self.assertEqual(len(value["controls"]), 71)
        self.assertEqual({c["id"] for c in value["controls"]}, {c["id"] for c in catalog.gate_rows()})
        for control in value["controls"]:
            self.assertTrue(control["owner_scenarios"] or control["developer_preparations"], control["id"])
            self.assertTrue(control["prerequisites"])
            self.assertTrue(control["missing_evidence"])
            for source in control["supporting_tests"]:
                self.assertTrue((catalog.ROOT / source).is_file(), source)


class SessionTests(unittest.TestCase):
    def valid(self):
        at = datetime.now(timezone.utc)
        return at, dict(started_at=at.isoformat(), expires_at=(at + timedelta(minutes=45)).isoformat(),
            owner_authorization="Owner made the isolated test apps available for 45 minutes",
            mac_bundle_id="com.aimai.macos.qualification." + "a" * 32,
            ios_bundle_id="com.aimai.ios.continuityqualification", device_id="test-device",
            allowed_actions=["observe", "close", "install", "launch", "control"])

    def test_valid_authorization_is_bounded_and_expires(self):
        at, value = self.valid()
        self.assertIs(session.validate(value, at), value)
        with self.assertRaises(ValueError):
            session.validate(value, at + timedelta(minutes=45))
        value["expires_at"] = (at + timedelta(minutes=46)).isoformat()
        with self.assertRaises(ValueError):
            session.validate(value, at)

    def test_official_apps_and_extra_actions_are_not_admitted(self):
        at, value = self.valid()
        value["mac_bundle_id"] = "com.aimai.macos"
        with self.assertRaises(ValueError):
            session.validate(value, at)
        at, value = self.valid()
        value["allowed_actions"].append("reset-pairing")
        with self.assertRaises(ValueError):
            session.validate(value, at)

    def test_authentication_material_is_not_authorization(self):
        at, value = self.valid()
        value["owner_authorization"] = ""
        with self.assertRaises(ValueError):
            session.validate(value, at)


if __name__ == "__main__":
    unittest.main()
