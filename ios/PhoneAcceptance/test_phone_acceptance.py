#!/usr/bin/env python3
"""Checks the parts of phone-acceptance.py that need no device.

Set PHONE_ACCEPTANCE_EVIDENCE to a finished `simulator` run's --out directory to also check its
exported records, its report and its runner plan.
"""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("phone_acceptance", HERE / "phone-acceptance.py")
phone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phone)
EVIDENCE = os.environ.get("PHONE_ACCEPTANCE_EVIDENCE")


def plan(path, value):
    with open(path, "wb") as file:
        plistlib.dump(value, file)
    return path


class ArgumentTests(unittest.TestCase):
    def test_device_needs_every_identity_value(self):
        with self.assertRaises(SystemExit):
            phone.parse_arguments(["device", "--device", "00000000-0000000000000000", "--out", "x"])

    def test_device_takes_repeated_selections(self):
        with tempfile.TemporaryDirectory() as directory:
            arguments = phone.parse_arguments([
                "device", "--device", "00000000-0000000000000000", "--app", "dev.example.Agent",
                "--team", "EXAMPLE123", "--runner-bundle", "dev.example.PhoneAcceptanceTests",
                "--coordinator", "Studio", "--out", str(Path(directory) / "run"),
                "--only", "ComposerRecurrenceTests", "--only", "NotificationDeliveryTests/testRegistration",
                "--run", "r15-0412",
            ])
        self.assertEqual(arguments.only, ["ComposerRecurrenceTests", "NotificationDeliveryTests/testRegistration"])
        self.assertEqual((arguments.coordinator, arguments.run), ("Studio", "r15-0412"))

    def test_simulator_rehearses_work_unless_told_otherwise(self):
        with tempfile.TemporaryDirectory() as directory:
            out = str(Path(directory) / "run")
            plain = phone.parse_arguments(["simulator", "--simulator", "SIM", "--out", out])
            nobody = phone.parse_arguments(
                ["simulator", "--simulator", "SIM", "--out", out, "--coordinator", "Nobody"])
        self.assertEqual(plain.coordinator, "Work")
        self.assertEqual(nobody.coordinator, "Nobody")
        self.assertRegex(plain.run, r"^pa-\d{8}$")

    def test_out_must_not_hold_an_earlier_run(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "report.md").write_text("earlier")
            with self.assertRaises(SystemExit):
                phone.parse_arguments(["simulator", "--simulator", "SIM", "--out", directory])


class BaselineTests(unittest.TestCase):
    def test_a_locked_phone_is_refused(self):
        self.assertIn("locked", phone.lock_state_problem(
            {"result": {"passcodeRequired": True, "unlockedSinceBoot": True}}))
        self.assertIsNone(phone.lock_state_problem(
            {"result": {"passcodeRequired": False, "unlockedSinceBoot": True}}))
        self.assertIn("did not report", phone.lock_state_problem({"result": {}}))

    def test_the_baseline_names_the_one_target_app(self):
        apps = {"result": {"apps": [
            {"bundleIdentifier": "dev.example.Agent", "version": "0.1", "bundleVersion": "41"},
            {"bundleIdentifier": "dev.example.PhoneAcceptanceTests.xctrunner", "version": "1.0",
             "bundleVersion": "1"},
        ]}}
        self.assertEqual(phone.app_baseline(apps, "dev.example.Agent"),
                         {"count": 1, "version": "0.1", "build": "41"})
        self.assertEqual(phone.app_baseline(apps, "dev.example.Other")["count"], 0)

    def test_a_changed_build_or_profile_fails_the_run(self):
        before = {"app": {"count": 1, "version": "0.1", "build": "41"}, "profiles_sha256": "a"}
        self.assertEqual(phone.baseline_problems(before, before), [])
        rebuilt = {"app": {"count": 1, "version": "0.1", "build": "42"}, "profiles_sha256": "a"}
        self.assertEqual(phone.baseline_problems(before, rebuilt),
                         ["the app's build changed from 41 to 42"])
        doubled = {"app": {"count": 2, "version": None, "build": None}, "profiles_sha256": "b"}
        self.assertEqual(len(phone.baseline_problems(before, doubled)), 4)


class PlanTests(unittest.TestCase):
    def test_a_runner_only_plan_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = plan(Path(directory) / "a.xctestrun", {
                "__xctestrun_metadata__": {"FormatVersion": 1},
                "PhoneAcceptanceTests": {
                    "BlueprintName": "PhoneAcceptanceTests", "IsUITestBundle": True,
                    "DependentProductPaths": ["__TESTROOT__/Debug-iphoneos/PhoneAcceptanceTests-Runner.app"],
                },
            })
            self.assertEqual(phone.xctestrun_problems(path), [])

    def test_a_plan_with_a_target_app_is_refused_in_either_format(self):
        with tempfile.TemporaryDirectory() as directory:
            first = plan(Path(directory) / "1.xctestrun", {
                "AgentUITests": {"BlueprintName": "AgentUITests",
                                 "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/Agent.app"},
            })
            second = plan(Path(directory) / "2.xctestrun", {
                "__xctestrun_metadata__": {"FormatVersion": 2},
                "TestConfigurations": [{"TestTargets": [{
                    "BlueprintName": "AgentUITests",
                    "DependentProductPaths": ["__TESTROOT__/Debug-iphoneos/Agent.app"],
                }]}],
            })
            empty = plan(Path(directory) / "3.xctestrun", {"__xctestrun_metadata__": {}})
            self.assertIn("UITargetAppPath", phone.xctestrun_problems(first)[0])
            self.assertIn("Agent.app", phone.xctestrun_problems(second)[0])
            self.assertIn("names no test target", phone.xctestrun_problems(empty)[0])


def send_record(label, problems=()):
    return {
        "kind": "send", "test": "ComposerRecurrenceTests/testTwoConsecutiveSendsKeepTheKeyboardUp()",
        "problems": list(problems),
        "record": {"label": label, "sentAt": 1794790000123, "placeholderShown": True,
                   "sentGlyphsAbsent": not problems, "keyboardShown": True, "recipientLine": "To Work"},
        "files": {"cropAttachment": f"attachments/{label}-composer.png",
                  "screenAttachment": f"attachments/{label}-screen.png"},
    }


class ReportTests(unittest.TestCase):
    def manifest(self, records, runner_status=0):
        return {
            "mode": "simulator", "run": "r15-0412", "app": "dev.example.Agent", "coordinator": "Work",
            "xcresult": "out/run.xcresult", "runner_status": runner_status, "passed": runner_status == 0,
            "baseline": {"checks": ["App container: unchanged."], "problems": []},
            "tests": [{"test": "ComposerRecurrenceTests/testTwoConsecutiveSendsKeepTheKeyboardUp()",
                       "result": "Passed", "messages": []}],
            "records": records,
        }

    def test_the_report_has_a_row_per_record_and_says_rehearsal(self):
        alert = {"kind": "alert", "test": "NotificationDeliveryTests/testMidJobNotice()", "problems": [],
                 "record": {"codeword": "r15-0412qzxv", "surface": "banner", "appState": "background",
                            "alertLabel": "Beep Boop, r15-0412qzxv", "seenAt": 1794790060000,
                            "tappedAt": 1794790061500},
                 "files": {"attachment": "attachments/alert.png"}}
        hidden = {"kind": "alert", "test": "NotificationDeliveryTests/testMidJobNotice()", "problems": [],
                  "record": {"codeword": "r15-0412qzxv", "surface": "notificationCenter",
                             "appState": "background", "alertLabel": None, "seenAt": None},
                  "files": {"attachment": "attachments/center.png"}}
        report = phone.render_report(
            self.manifest([send_record("first"), send_record("second"), alert, hidden]))
        self.assertIn("| notificationCenter | background |  |  |  | [center.png](attachments/center.png) "
                      "| not seen |", report)
        self.assertIn("rehearsal pushes", report)
        self.assertIn("| 1794790000123 (2026-11-16T00:46:40.123Z) |", report)
        self.assertEqual(report.count("| ok |"), 3)
        self.assertIn("| 1794790060000 (", report)
        self.assertIn("| 1794790061500 (", report)
        self.assertIn("Overall: PASS.", report)

    def test_a_failed_record_reads_as_a_failure(self):
        report = phone.render_report(self.manifest(
            [send_record("first", ["the composer still showed sent text"])], runner_status=65))
        self.assertIn("FAIL: the composer still showed sent text", report)
        self.assertIn("Overall: FAIL.", report)

    def test_records_are_read_back_with_their_screenshots(self):
        with tempfile.TemporaryDirectory() as directory:
            attachments = Path(directory)
            test = "ComposerRecurrenceTests/testTwoConsecutiveSendsKeepTheKeyboardUp()"
            envelope = {"kind": "send", "test": "-[ComposerRecurrenceTests test]", "problems": [],
                        "record": {"label": "first", "sentAt": 1, "cropAttachment": "first-composer",
                                   "screenAttachment": "first-screen"}}
            (attachments / "A.json").write_text(json.dumps(envelope))
            (attachments / "B.json").write_text(json.dumps({"work": 0, "personal": 0}))
            (attachments / "E.json").write_text(json.dumps({"work": 9, "personal": 9}))
            (attachments / "manifest.json").write_text(json.dumps([{"testIdentifier": test, "attachments": [
                {"exportedFileName": "A.json", "suggestedHumanReadableName": "send-first_0_A.json"},
                {"exportedFileName": "E.json", "suggestedHumanReadableName": "first-composer_0_E.json"},
                {"exportedFileName": "C.png", "suggestedHumanReadableName": "first-composer_0_C.png"},
                {"exportedFileName": "D.png", "suggestedHumanReadableName": "first-screen_0_D.png"},
                {"exportedFileName": "B.json", "suggestedHumanReadableName": "rehearsal-peers_0_B.json"},
            ]}]))
            records = phone.load_records(attachments)
        self.assertEqual([record["kind"] for record in records],
                         ["send", "first-composer", "rehearsal-peers"])
        self.assertEqual(records[0]["test"], test)
        self.assertEqual(records[0]["files"], {"cropAttachment": "attachments/C.png",
                                               "screenAttachment": "attachments/D.png"})
        self.assertEqual(records[2]["record"], {"work": 0, "personal": 0})

    def test_test_results_list_each_case_with_its_reason(self):
        tree = {"testNodes": [{"nodeType": "Test Plan", "children": [{
            "nodeType": "Test Suite", "name": "NotificationDeliveryTests", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": "NotificationDeliveryTests/testRegistration()",
                 "result": "Skipped", "children": [
                     {"nodeType": "Skip Message", "name": "The simulator has no APNs"}]},
                {"nodeType": "Test Case", "nodeIdentifier": "NotificationDeliveryTests/testBackgroundReply()",
                 "result": "Passed", "children": []},
            ]}]}]}
        self.assertEqual(phone.test_results(tree), [
            {"test": "NotificationDeliveryTests/testRegistration()", "result": "Skipped",
             "messages": ["The simulator has no APNs"]},
            {"test": "NotificationDeliveryTests/testBackgroundReply()", "result": "Passed", "messages": []},
        ])


class MissingEvidenceTests(unittest.TestCase):
    """A Send whose composer crop did not reach the host fails its record and the run."""

    test = "ComposerRecurrenceTests/testTwoConsecutiveSendsKeepTheKeyboardUp()"

    def run_with(self, attachments_listed, files_written):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            attachments = out / "attachments"
            attachments.mkdir()
            record = {"kind": "send", "test": self.test, "problems": [], "record": {
                "label": "first", "sentAt": 1794790000123, "placeholderShown": True,
                "sentGlyphsAbsent": True, "keyboardShown": True, "recipientLine": "To Work",
                "cropAttachment": "first-composer", "screenAttachment": "first-screen"}}
            (attachments / "record.json").write_text(json.dumps(record))
            for name in files_written:
                (attachments / name).write_bytes(b"invented image")
            listed = [{"exportedFileName": "record.json",
                       "suggestedHumanReadableName": "send-first_0_record.json"}]
            listed += [{"exportedFileName": file, "suggestedHumanReadableName": f"{name}_0_{file}"}
                       for name, file in attachments_listed]
            (attachments / "manifest.json").write_text(
                json.dumps([{"testIdentifier": self.test, "attachments": listed}]))
            records = phone.load_records(attachments)
            arguments = SimpleNamespace(out=out, run="r15-0412", app="dev.example.Agent", coordinator="Work")
            tests = [{"test": self.test, "result": "Passed", "messages": []}]
            with patch.object(phone, "export_evidence", return_value=(records, tests)):
                passed = phone.write_evidence(arguments, "simulator", {"checks": [], "problems": []}, 0)
            return passed, (out / "report.md").read_text()

    def test_every_capture_present_passes(self):
        passed, report = self.run_with(
            [("first-composer", "crop.png"), ("first-screen", "screen.png")], ["crop.png", "screen.png"])
        self.assertTrue(passed)
        self.assertIn("| [crop.png](attachments/crop.png) | [screen.png](attachments/screen.png) | ok |", report)
        self.assertIn("Overall: PASS.", report)

    def test_a_crop_the_export_never_listed_fails_the_run(self):
        passed, report = self.run_with([("first-screen", "screen.png")], ["screen.png"])
        self.assertFalse(passed)
        self.assertIn("| missing | [screen.png](attachments/screen.png) | FAIL: ", report)
        self.assertIn("cropAttachment", report)
        self.assertIn("Overall: FAIL.", report)

    def test_a_listed_crop_whose_file_is_gone_fails_the_run(self):
        passed, report = self.run_with(
            [("first-composer", "crop.png"), ("first-screen", "screen.png")], ["screen.png"])
        self.assertFalse(passed)
        self.assertIn("| missing | [screen.png](attachments/screen.png) | FAIL: ", report)
        self.assertIn("cropAttachment", report)
        self.assertIn("Overall: FAIL.", report)


@unittest.skipUnless(EVIDENCE, "set PHONE_ACCEPTANCE_EVIDENCE to a simulator run's --out directory")
class SimulatorEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.out = Path(EVIDENCE)
        self.manifest = json.loads((self.out / "manifest.json").read_text())

    def test_the_report_renders_again_from_the_manifest(self):
        self.assertEqual(phone.render_report(self.manifest), (self.out / "report.md").read_text())

    def test_every_record_points_at_exported_files(self):
        records = phone.load_records(self.out / "attachments")
        self.assertEqual(records, self.manifest["records"])
        for record in records:
            for path in record["files"].values():
                self.assertIsNotNone(path, record)
                self.assertTrue((self.out / path).exists(), path)

    def test_the_runner_plan_names_no_app(self):
        plans = sorted((phone.DERIVED_DATA / "simulator/Build/Products").glob("*.xctestrun"))
        self.assertTrue(plans)
        self.assertEqual(phone.xctestrun_problems(plans[-1]), [])


if __name__ == "__main__":
    unittest.main()
