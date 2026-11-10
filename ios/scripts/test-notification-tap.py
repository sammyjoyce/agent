#!/usr/bin/env python3
"""Run the notification UI test and deliver its APNs payloads to one simulator."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--watch", action="store_true",
    help="only deliver payloads, until terminated, while another process runs the test")
parser.add_argument("simulator", metavar="SIMULATOR_UDID")
parser.add_argument("artifact_directory", metavar="ARTIFACT_DIRECTORY")
arguments = parser.parse_args()
simulator, artifact_directory, watch = (
    arguments.simulator, arguments.artifact_directory, arguments.watch)
root = Path(__file__).resolve().parents[2]
artifacts = Path(artifact_directory).resolve()
artifacts.mkdir(parents=True, exist_ok=True)
request_file = Path(f"/tmp/agent-notification-{simulator}.json")
enabled = Path(f"/tmp/agent-notification-{simulator}.enabled")
request_file.unlink(missing_ok=True)
result = artifacts / "notification-ui.xcresult"
if not watch and result.exists():
    sys.exit(f"Remove or rename the existing result bundle first: {result}")
command = [
    "xcodebuild", "-project", "ios/Agent.xcodeproj", "-scheme", "Agent",
    "-destination", f"platform=iOS Simulator,id={simulator}",
    "-derivedDataPath", "target/ios-notification-tap", "-resultBundlePath", str(result),
    "-only-testing:AgentUITests/ScopeInteractionTests/testNotificationTapsRouteWithoutChangingTheDraft",
    "test",
]
if watch:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
enabled.touch()
process = None if watch else subprocess.Popen(command, cwd=root)
seen = set()
try:
    while process is None or process.poll() is None:
        if request_file.exists():
            try:
                request = json.loads(request_file.read_text())
                stage = request["stage"]
                if stage not in seen:
                    container = subprocess.check_output([
                        "xcrun", "simctl", "get_app_container", simulator,
                        "dev.jessfraz.Agent", "data",
                    ], text=True).strip()
                    profiles = Path(container) / "Library/Application Support/Agent/Interaction" / request["id"].lower() / "Support/Agent/profiles.json"
                    personal = json.loads(profiles.read_text())["profiles"][1]["id"]
                    agent = {"conversation_id": "1", "entry_id": "42"}
                    if stage != "unnamed":
                        agent["installation_id"] = personal
                    payload = {
                        "aps": {"alert": {"title": "Beep Boop", "body": "Private fixture response"}, "sound": "default"},
                        "agent": agent,
                    }
                    path = artifacts / f"notification-{stage}.apns"
                    path.write_text(json.dumps(payload))
                    time.sleep(1)
                    subprocess.run([
                        "xcrun", "simctl", "push", simulator, "dev.jessfraz.Agent", str(path),
                    ], check=True)
                    print(f"Delivered {stage} notification", flush=True)
                    seen.add(stage)
            except (OSError, KeyError, json.JSONDecodeError):
                pass
        time.sleep(0.2)
    status = process.wait()
    if status == 0 and seen != {"named", "cold", "unnamed"}:
        sys.exit(f"Missing notification stages: {seen}")
    sys.exit(status)
finally:
    enabled.unlink(missing_ok=True)
    request_file.unlink(missing_ok=True)
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait()
