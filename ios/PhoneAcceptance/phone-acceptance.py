#!/usr/bin/env python3
"""Drive the installed Beep Boop app with the phone acceptance runner and keep its evidence.

`device` attaches to the app already on a phone and never installs or replaces it.
`simulator` rehearses the same runner against a simulator's Debug build and loopback peers.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "ios/PhoneAcceptance/PhoneAcceptance.xcodeproj"
DERIVED_DATA = ROOT / "target/phone-acceptance/derived-data"
PROFILES = "Library/Application Support/Agent/profiles.json"
TEST_BUNDLE = "PhoneAcceptanceTests"
ADHOC_SIGNING = [
    "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
]


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    device = commands.add_parser("device", help="run against the app installed on a phone")
    device.add_argument("--device", required=True, metavar="UDID")
    device.add_argument("--app", required=True, metavar="BUNDLE", help="the installed app's bundle ID")
    device.add_argument("--team", required=True, help="the development team that signs the runner")
    device.add_argument("--runner-bundle", required=True, metavar="ID",
                        help="the runner's bundle ID, which the team's profile must admit")
    device.add_argument("--coordinator", required=True, metavar="NAME",
                        help="the saved coordinator every message goes to")
    simulator = commands.add_parser("simulator", help="rehearse on a simulator with loopback peers")
    simulator.add_argument("--simulator", required=True, metavar="UDID")
    simulator.add_argument("--coordinator", default="Work", help=argparse.SUPPRESS)
    for command in (device, simulator):
        command.add_argument("--out", required=True, type=Path, metavar="DIR")
        command.add_argument("--only", action="append", default=[], metavar="CLASS[/TEST]",
                             help="run only this test class or test; repeatable")
        command.add_argument("--run", default=datetime.now().strftime("pa-%m%d%H%M"),
                             help="the label every message starts with (default: pa-MMDDHHMM)")
    arguments = parser.parse_args(argv)
    if arguments.out.exists() and any(arguments.out.iterdir()):
        parser.error(f"--out must be empty or absent: {arguments.out}")
    return arguments


def run(command, **options):
    print("+", " ".join(str(part) for part in command), flush=True)
    return subprocess.run(command, check=True, **options)


def read_json(path):
    return json.loads(Path(path).read_text())


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def lock_state_problem(lock_state):
    """The reason to refuse a run, from `devicectl device info lockState` JSON, or None."""
    result = lock_state.get("result", {})
    if "passcodeRequired" not in result:
        return f"lockState did not report passcodeRequired: {json.dumps(result)}"
    if result["passcodeRequired"]:
        return "The phone is locked. Unlock it, turn Auto-Lock off, and run again."
    return None


def app_baseline(apps, bundle):
    """The target app's entries in `devicectl device info apps` JSON, with version and build."""
    matches = [app for app in apps.get("result", {}).get("apps", [])
               if app.get("bundleIdentifier") == bundle]
    only = matches[0] if len(matches) == 1 else {}
    return {"count": len(matches), "version": only.get("version"), "build": only.get("bundleVersion")}


def baseline_problems(before, after):
    """What changed about the installed app across the run. Empty when nothing did."""
    problems = []
    if before["app"]["count"] != 1:
        problems.append(f"before the run, {before['app']['count']} apps had the target ID")
    if after["app"]["count"] != 1:
        problems.append(f"after the run, {after['app']['count']} apps had the target ID")
    for key in ("version", "build"):
        if before["app"][key] != after["app"][key]:
            problems.append(f"the app's {key} changed from {before['app'][key]} to {after['app'][key]}")
    if before["profiles_sha256"] != after["profiles_sha256"]:
        problems.append("the saved coordinators changed: profiles.json has a new hash")
    return problems


def device_baseline(arguments, private, name):
    """Records the installed app and a private copy of its saved coordinators."""
    base = arguments.out / f"baseline-{name}"
    base.mkdir()
    devicectl = ["xcrun", "devicectl", "device"]
    run(devicectl + ["info", "apps", "--device", arguments.device,
                     "--json-output", str(base / "apps.json")], stdout=subprocess.DEVNULL)
    profiles = private / f"profiles-{name}.json"
    run(devicectl + ["copy", "from", "--device", arguments.device, "--domain-type", "appDataContainer",
                     "--domain-identifier", arguments.app, "--source", PROFILES,
                     "--destination", str(profiles)], stdout=subprocess.DEVNULL)
    profiles.chmod(0o600)
    return {"app": app_baseline(read_json(base / "apps.json"), arguments.app),
            "profiles_sha256": sha256(profiles)}


def xctestrun_problems(xctestrun):
    """Why this .xctestrun could install or launch an app besides the runner. Empty when it cannot."""
    with open(xctestrun, "rb") as file:
        plan = plistlib.load(file)
    targets = [value for key, value in plan.items()
               if key != "__xctestrun_metadata__" and isinstance(value, dict)]
    targets += [target for configuration in plan.get("TestConfigurations", [])
                for target in configuration.get("TestTargets", [])]
    if not targets:
        return [f"{xctestrun} names no test target"]
    problems = []
    for target in targets:
        name = target.get("BlueprintName", "?")
        for key in ("UITargetAppPath", "UITargetAppBundleIdentifier", "TestHostBundleIdentifierForApp"):
            if target.get(key):
                problems.append(f"{name} names a target app in {key}: {target[key]}")
        for path in target.get("DependentProductPaths", []):
            if path.endswith(".app") and not path.endswith(f"/{TEST_BUNDLE}-Runner.app"):
                problems.append(f"{name} depends on another app: {path}")
    return problems


def build_runner(destination, settings, derived_data):
    run(["xcodebuild", "-project", str(PROJECT), "-scheme", "PhoneAcceptance",
         "-destination", destination, "-derivedDataPath", str(derived_data),
         *settings, "build-for-testing"])
    plans = sorted((derived_data / "Build/Products").glob("*.xctestrun"),
                   key=lambda path: path.stat().st_mtime)
    if not plans:
        sys.exit(f"build-for-testing left no .xctestrun in {derived_data}")
    problems = xctestrun_problems(plans[-1])
    if problems:
        sys.exit("Refusing a runner that names a target app:\n" + "\n".join(problems))
    return plans[-1]


def run_runner(xctestrun, destination, arguments, rehearsal):
    environment = dict(os.environ)
    environment.update({
        "TEST_RUNNER_PHONE_ACCEPTANCE_APP": arguments.app,
        "TEST_RUNNER_PHONE_ACCEPTANCE_COORDINATOR": arguments.coordinator,
        "TEST_RUNNER_PHONE_ACCEPTANCE_RUN": arguments.run,
    })
    if rehearsal:
        environment["TEST_RUNNER_PHONE_ACCEPTANCE_REHEARSAL"] = "1"
    selection = [f"-only-testing:{TEST_BUNDLE}/{only}" for only in arguments.only]
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
               "-destination", destination, "-parallel-testing-enabled", "NO",
               "-resultBundlePath", str(arguments.out / "run.xcresult"), *selection]
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, env=environment).returncode


def export_evidence(out):
    """Exports the result bundle's attachments and test results, and returns both."""
    bundle = out / "run.xcresult"
    attachments = out / "attachments"
    if not bundle.exists():
        return [], []
    run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
         "--output-path", str(attachments)], stdout=subprocess.DEVNULL)
    tests = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests",
                            "--path", str(bundle), "--compact"],
                           check=True, capture_output=True, text=True).stdout
    (out / "tests.json").write_text(tests)
    return load_records(attachments), test_results(json.loads(tests))


def attachment_name(exported):
    """The name the runner gave an attachment. The export adds `_<index>_<UUID>.<extension>`."""
    stem, _, extension = exported["suggestedHumanReadableName"].rpartition(".")
    parts = stem.rsplit("_", 2)
    return (parts[0] if len(parts) == 3 else stem), extension


def load_records(attachments):
    """The JSON records the runner attached, each with the files its attachment names point to."""
    manifest_path = attachments / "manifest.json"
    if not manifest_path.exists():
        return []
    records = []
    for test in read_json(manifest_path):
        named = [(attachment_name(item), item["exportedFileName"]) for item in test["attachments"]]
        images = {name: f"attachments/{file}" for (name, extension), file in named
                  if extension != "json" and (attachments / file).exists()}
        for (name, extension), file in named:
            if extension != "json":
                continue
            body = read_json(attachments / file)
            if "kind" not in body:
                records.append({"kind": name, "test": test["testIdentifier"], "record": body,
                                "problems": [], "files": {}})
                continue
            body["files"] = {key: images.get(value) for key, value in body["record"].items()
                             if key == "attachment" or key.endswith("Attachment")}
            body["problems"] += [f"the {key} image {body['record'][key]!r} is missing"
                                 for key, path in body["files"].items() if path is None]
            body["test"] = test["testIdentifier"]
            records.append(body)
    return records


def test_results(tree):
    """Each test case's result and failure messages, from `xcresulttool get test-results tests`."""
    results = []

    def visit(node):
        if node.get("nodeType") == "Test Case":
            messages = [child.get("name", "") for child in node.get("children", [])
                        if child.get("nodeType") in ("Failure Message", "Skip Message")
                        or child.get("result") in ("Failed", "Skipped")]
            results.append({"test": node.get("nodeIdentifier", node.get("name")),
                            "result": node.get("result"), "messages": messages})
        for child in node.get("children", []):
            visit(child)

    for node in tree.get("testNodes", []):
        visit(node)
    return results


def cell(value):
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def link(path):
    return f"[{Path(path).name}]({path})" if path else "missing"


def stamp(milliseconds):
    """An epoch-milliseconds time as the runner recorded it, with its UTC reading."""
    if milliseconds is None:
        return ""
    utc = datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
    return f"{milliseconds} ({utc.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]}Z)"


def verdict(record):
    if record["problems"]:
        return "FAIL: " + "; ".join(record["problems"])
    if record["kind"] == "alert" and record["record"].get("alertLabel") is None:
        return "not seen"
    return "ok"


def render_report(manifest):
    records = manifest["records"]
    lines = [
        f"# Phone acceptance {manifest['run']}",
        "",
        f"Mode: {manifest['mode']}. Target: `{manifest['app']}`. Coordinator: {manifest['coordinator']}.",
        f"Result bundle: `{manifest['xcresult']}`. Runner exit status: {manifest['runner_status']}.",
    ]
    if manifest["mode"] == "simulator":
        lines.append("The simulator's alerts are rehearsal pushes from this script. "
                     "They prove the runner detects alerts, not that a coordinator delivered them.")
    lines += ["", "## Tests", "", "| Test | Result | Messages |", "| --- | --- | --- |"]
    lines += [f"| {cell(test['test'])} | {cell(test['result'])} | {cell('; '.join(test['messages']))} |"
              for test in manifest["tests"]]
    lines += ["", "## Send records", "",
              "| Test | Check | Sent at | Placeholder shown | Sent glyphs absent | Keyboard shown "
              "| Recipient line | Composer | Screen | Verdict |",
              "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for record in (r for r in records if r["kind"] == "send"):
        fields = record["record"]
        lines.append(
            f"| {cell(record['test'])} | {cell(fields['label'])} | {stamp(fields['sentAt'])} "
            f"| {fields['placeholderShown']} "
            f"| {fields['sentGlyphsAbsent']} | {fields['keyboardShown']} | {cell(fields.get('recipientLine'))} "
            f"| {link(record['files'].get('cropAttachment'))} | {link(record['files'].get('screenAttachment'))} "
            f"| {cell(verdict(record))} |")
    lines += ["", "Composer checks that follow no Send:", "",
              "| Test | Check | Expected | Shown | Sent glyphs absent | Composer | Verdict |",
              "| --- | --- | --- | --- | --- | --- | --- |"]
    for record in (r for r in records if r["kind"] == "draft"):
        fields = record["record"]
        lines.append(
            f"| {cell(record['test'])} | {cell(fields['label'])} | {cell(fields['expected'])} "
            f"| {fields['expectedShown']} | {fields['sentGlyphsAbsent']} "
            f"| {link(record['files'].get('cropAttachment'))} | {cell(verdict(record))} |")
    lines += ["", "## Alert records", "",
              "| Test | Codeword | Surface | App state | Seen at | Tapped at | Alert label | Screen "
              "| Verdict |",
              "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for record in (r for r in records if r["kind"] == "alert"):
        fields = record["record"]
        lines.append(
            f"| {cell(record['test'])} | {cell(fields['codeword'])} | {fields['surface']} "
            f"| {fields['appState']} | {stamp(fields.get('seenAt'))} | {stamp(fields.get('tappedAt'))} "
            f"| {cell(fields.get('alertLabel'))} "
            f"| {link(record['files'].get('attachment'))} | {cell(verdict(record))} |")
    lines += ["", "An alert test passes when any of its surfaces showed the codeword. "
              "A surface that did not is kept as an observation."]
    submits = [r for r in records if r["kind"] == "submit"]
    if submits:
        lines += ["", "What the rehearsal coordinator received:", ""]
        lines += [f"- {cell(r['record']['label'])}: {len(r['record']['submits'])} submit, "
                  f"{r['record']['draftLines']} lines in the draft. {verdict(r)}." for r in submits]
    for record in (r for r in records if r["kind"] == "registration"):
        fields = record["record"]
        lines += ["", f"Registration: Main-chat updates {'on' if fields['mainChatUpdates'] else 'off'}, "
                  f"coordinator hints {fields['coordinatorHints'] or 'none'}, "
                  f"{link(record['files'].get('attachment'))}. {verdict(record)}."]
    peers = [r for r in records if r["kind"] == "rehearsal-peers"]
    if peers:
        lines += ["", "Submits the rehearsal peers took, per test:", ""]
        lines += [f"- {cell(r['test'])}: Work {r['record']['work']}, Personal {r['record']['personal']}"
                  for r in peers]
    lines += ["", "## Installed app", ""]
    lines += [f"- {check}" for check in manifest["baseline"]["checks"]]
    lines += ["", f"Overall: {'PASS' if manifest['passed'] else 'FAIL'}.", ""]
    return "\n".join(lines)


def write_evidence(arguments, mode, baseline, runner_status):
    records, tests = export_evidence(arguments.out)
    failed_records = [r for r in records if r["problems"]]
    passed = (runner_status == 0 and not baseline["problems"] and not failed_records
              and any(test["result"] == "Passed" for test in tests))
    manifest = {
        "mode": mode, "run": arguments.run, "app": arguments.app, "coordinator": arguments.coordinator,
        "xcresult": str(arguments.out / "run.xcresult"), "runner_status": runner_status,
        "baseline": baseline, "tests": tests, "records": records, "passed": passed,
    }
    (arguments.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (arguments.out / "report.md").write_text(render_report(manifest))
    print(f"Report: {arguments.out / 'report.md'}")
    return passed


def device_command(arguments):
    arguments.out.mkdir(parents=True, exist_ok=True)
    private = arguments.out / "private"
    private.mkdir(mode=0o700)
    lock = arguments.out / "lock-state.json"
    run(["xcrun", "devicectl", "device", "info", "lockState", "--device", arguments.device,
         "--json-output", str(lock)], stdout=subprocess.DEVNULL)
    problem = lock_state_problem(read_json(lock))
    if problem:
        sys.exit(problem)
    before = device_baseline(arguments, private, "before")
    if before["app"]["count"] != 1:
        sys.exit(f"Expected exactly one installed {arguments.app}, found {before['app']['count']}")
    destination = f"platform=iOS,id={arguments.device}"
    xctestrun = build_runner(destination, [f"DEVELOPMENT_TEAM={arguments.team}",
                                           f"PRODUCT_BUNDLE_IDENTIFIER={arguments.runner_bundle}"],
                             DERIVED_DATA / "device")
    status = run_runner(xctestrun, destination, arguments, rehearsal=False)
    after = device_baseline(arguments, private, "after")
    problems = baseline_problems(before, after)
    baseline = {
        "before": before, "after": after, "problems": problems,
        "checks": [f"Before: {before['app']['count']} app with the target ID, version "
                   f"{before['app']['version']} build {before['app']['build']}.",
                   f"After: {after['app']['count']} app with the target ID, version "
                   f"{after['app']['version']} build {after['app']['build']}.",
                   "profiles.json hash " + ("unchanged." if before["profiles_sha256"] == after["profiles_sha256"]
                                            else "CHANGED."),
                   *problems],
    }
    return 0 if write_evidence(arguments, "device", baseline, status) else 1


def checked_in_bundle_id():
    for line in (ROOT / "ios/Shared.xcconfig").read_text().splitlines():
        key, _, value = line.partition("=")
        if key.strip() == "AGENT_BUNDLE_IDENTIFIER":
            return value.strip()
    sys.exit("ios/Shared.xcconfig sets no AGENT_BUNDLE_IDENTIFIER")


def installed_simulator_app(simulator, bundle):
    path = subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, bundle],
                                   text=True).strip()
    info = os.stat(path)
    return {"container": path, "installed": info.st_birthtime, "modified": info.st_mtime}


class PushWatcher:
    """Answers the rehearsal runner's push requests with `simctl push`, until stopped."""

    def __init__(self, simulator, bundle, out):
        self.simulator, self.bundle, self.out = simulator, bundle, out
        self.request = Path(f"/tmp/phone-acceptance-{simulator}-push.json")
        self.watching = Path(f"/tmp/phone-acceptance-{simulator}.watching")
        self.stopped = threading.Event()
        self.delivered = set()
        self.thread = threading.Thread(target=self.watch, daemon=True)

    def __enter__(self):
        self.request.unlink(missing_ok=True)
        self.watching.touch()
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stopped.set()
        self.thread.join()
        self.watching.unlink(missing_ok=True)
        self.request.unlink(missing_ok=True)

    def watch(self):
        while not self.stopped.wait(0.2):
            try:
                request = read_json(self.request)
                key = (request["stage"], request["codeword"])
                if key not in self.delivered:
                    self.push(request)
                    self.delivered.add(key)
            except (OSError, KeyError, json.JSONDecodeError, subprocess.CalledProcessError):
                pass

    def push(self, request):
        container = subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", self.simulator, self.bundle, "data"], text=True).strip()
        profiles = (Path(container) / "Library/Application Support/Agent/Interaction"
                    / request["id"].lower() / "Support/Agent/profiles.json")
        work = read_json(profiles)["profiles"][0]["id"]
        payload = {
            "aps": {"alert": {"title": "Beep Boop", "body": f"Rehearsal {request['stage']}: {request['codeword']}"},
                    "sound": "default"},
            "agent": {"conversation_id": "1", "entry_id": "42", "installation_id": work},
        }
        path = self.out / f"push-{request['stage']}.apns"
        path.write_text(json.dumps(payload))
        run(["xcrun", "simctl", "push", self.simulator, self.bundle, str(path)])
        print(f"Pushed the {request['stage']} rehearsal alert", flush=True)


def simulator_command(arguments):
    arguments.out.mkdir(parents=True, exist_ok=True)
    arguments.app = checked_in_bundle_id()
    destination = f"platform=iOS Simulator,id={arguments.simulator}"
    app_data = DERIVED_DATA / "agent"
    run(["xcodebuild", "-project", str(ROOT / "ios/Agent.xcodeproj"), "-scheme", "Agent",
         "-destination", destination, "-derivedDataPath", str(app_data),
         "-onlyUsePackageVersionsFromResolvedFile", *ADHOC_SIGNING, "build"])
    run(["xcrun", "simctl", "install", arguments.simulator,
         str(app_data / "Build/Products/Debug-iphonesimulator/Agent.app")])
    before = installed_simulator_app(arguments.simulator, arguments.app)
    xctestrun = build_runner(destination, ADHOC_SIGNING, DERIVED_DATA / "simulator")
    with PushWatcher(arguments.simulator, arguments.app, arguments.out):
        status = run_runner(xctestrun, destination, arguments, rehearsal=True)
    after = installed_simulator_app(arguments.simulator, arguments.app)
    problems = [f"the app's {key} changed from {before[key]} to {after[key]}"
                for key in ("container", "installed") if before[key] != after[key]]
    baseline = {
        "before": before, "after": after, "problems": problems,
        "checks": [f"App container: {'unchanged' if before['container'] == after['container'] else 'CHANGED'}.",
                   f"Install time: {'unchanged' if before['installed'] == after['installed'] else 'CHANGED'}.",
                   *problems],
    }
    return 0 if write_evidence(arguments, "simulator", baseline, status) else 1


def main(argv):
    arguments = parse_arguments(argv)
    if shutil.which("xcrun") is None:
        sys.exit("xcrun is required: select full Xcode")
    return device_command(arguments) if arguments.command == "device" else simulator_command(arguments)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
