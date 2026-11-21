#!/usr/bin/env python3
"""Fails unless a built Agent.app ships every App Intents action, entity with its properties,
enum and query, at least one shortcut, the retry behind authentication, Send Message behind an
unlock of the device that runs it, and each open action as the system's open intent for its
entity. Every shortcut must hold a phrase that is not empty. One of Open Coordinator's phrases
must name ${target} and ${applicationName}, and one of Send Message's must name ${coordinator}
and ${applicationName}. No other action has a phrase. Open Job has none, because a phrase on its
job would make each refresh of the app's phrases read every coordinator's jobs. Send Message
takes exactly a message and one saved coordinator, and runs without opening the app. On iOS 27.3 SDK
builds (or when `--sdk-27-3` is passed), it also verifies `ToolIntent` conformance on Open
Coordinator and Send Message only, plus `.requiresLocalDeviceAuthentication` and Siri-visible
metadata on Coordinator and Job entities and their properties.

A shortcuts provider in the wrong target still builds, and only the extracted metadata shows that
the app ships no phrase.

Usage: check-intents-metadata.py [--sdk-27-3 | --no-sdk-27-3] <Agent.app | extract.actionsdata>
"""

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path

ACTIONS = {
    "OpenCoordinatorIntent",
    "OpenJobIntent",
    "RetryInterruptedRunIntent",
    "SendMessageIntent",
}
TOOLS = {"OpenCoordinatorIntent", "SendMessageIntent"}
TOOL_INTENT = "com.apple.link.systemProtocol.ToolIntent"
ENTITIES = {
    "CoordinatorEntity": {"name"},
    "JobEntity": {"title", "coordinator", "schedule", "state", "lastRun", "nextRun"},
}
AUTHENTICATED_ENTITIES = {"CoordinatorEntity": 2, "JobEntity": 2}
ENUMS = {"JobRunState"}
QUERIES = {"CoordinatorQuery", "JobQuery"}
# Each action a phrase runs, and what one of its phrases must name.
PHRASED = {
    "OpenCoordinatorIntent": {"${target}", "${applicationName}"},
    "SendMessageIntent": {"${coordinator}", "${applicationName}"},
}
# `authenticationPolicy` 1 is `.requiresAuthentication`, 2 `.requiresLocalDeviceAuthentication`.
AUTHENTICATED = {"RetryInterruptedRunIntent": 1, "SendMessageIntent": 2}
POLICIES = {1: "require authentication", 2: "require an unlock of the device that runs it"}
# `typeIdentifier` 0 is a String.
STRING = "primitive 0"
# Each action's parameters, by name and the type it takes: an entity's name or STRING.
PARAMETERS = {"SendMessageIntent": {"message": STRING, "coordinator": "CoordinatorEntity"}}
# Actions that run without opening the app.
IN_BACKGROUND = {"SendMessageIntent"}
OPENS = {"OpenCoordinatorIntent": "CoordinatorEntity", "OpenJobIntent": "JobEntity"}
OPEN_ENTITY = "com.apple.link.systemProtocol.OpenEntity"
INDEXED = {"CoordinatorEntity", "JobEntity"}
INDEXED_ENTITY = "com.apple.appintents.entity.Indexed"


def metadata_path(argument: str) -> Path:
    path = Path(argument)
    if path.is_dir():
        return path / "Metadata.appintents" / "extract.actionsdata"
    return path


def app_uses_sdk_27_3(argument: str) -> bool:
    path = Path(argument)
    plist_path = path / "Info.plist" if path.is_dir() else path.parent.parent / "Info.plist"
    try:
        info = plistlib.loads(plist_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise ValueError(f"cannot read {plist_path}: {error}") from error
    sdk = str(info.get("DTSDKName") or "")
    match = re.search(r"(\d+)(?:\.(\d+))?", sdk)
    if not match:
        raise ValueError(f"missing or unparseable DTSDKName {sdk!r} in {plist_path}")
    major = int(match.group(1))
    minor = int(match.group(2) or 0)
    return (major, minor) >= (27, 3)


def value_type(value: dict) -> str | None:
    if "entity" in value:
        return (value["entity"].get("wrapper") or {}).get("typeName")
    if "primitive" in value:
        return f"primitive {(value['primitive'].get('wrapper') or {}).get('typeIdentifier')}"
    return None


def problems(metadata: dict, *, expect_27_3: bool = False) -> list[str]:
    found = []
    shipped = {kind: set(metadata.get(kind) or {}) for kind in ("actions", "entities", "queries")}
    shipped["enums"] = {enum.get("identifier") for enum in metadata.get("enums") or []}
    expected_kinds = (
        ("actions", ACTIONS),
        ("entities", ENTITIES.keys()),
        ("enums", ENUMS),
        ("queries", QUERIES),
    )
    for kind, expected in expected_kinds:
        missing = expected - shipped[kind]
        if missing:
            found.append(f"missing {kind}: {', '.join(sorted(missing))}")
    entities = metadata.get("entities") or {}
    for entity, expected in ENTITIES.items():
        listed = {p.get("identifier") for p in entities.get(entity, {}).get("properties") or []}
        missing = expected - listed
        if entity in entities and missing:
            found.append(f"{entity} is missing properties: {', '.join(sorted(missing))}")
    for entity, record in entities.items():
        indexed = INDEXED_ENTITY in (record.get("systemProtocolMetadata") or [])
        if entity in INDEXED and not indexed:
            found.append(f"{entity} is not indexed in Spotlight")
        if indexed and entity not in INDEXED:
            found.append(f"{entity} is indexed in Spotlight, where only coordinators and jobs go")
        for p in record.get("properties") or []:
            if p.get("spotlightAttributeKey"):
                found.append(f"{entity}.{p.get('identifier')} names a Spotlight attribute")
    shortcuts = metadata.get("autoShortcuts") or []
    if not shortcuts:
        found.append("autoShortcuts is empty, so the app ships no phrase")
    phrases: dict[str, list[str]] = {}
    for shortcut in shortcuts:
        action = str(shortcut.get("actionIdentifier"))
        keys = [t.get("key") or "" for t in shortcut.get("phraseTemplates") or []]
        if not any(keys):
            found.append(f"a shortcut for {action} holds no phrase")
        phrases.setdefault(action, []).extend(keys)
    if shortcuts and PHRASED.keys() - phrases.keys():
        found.append(f"no phrase runs {', '.join(sorted(PHRASED.keys() - phrases.keys()))}")
    if phrases.keys() - PHRASED.keys():
        unexpected = ", ".join(sorted(phrases.keys() - PHRASED.keys()))
        found.append(f"a phrase runs {unexpected}, which must have none")
    for action, named in PHRASED.items():
        keys = [key for key in phrases.get(action, []) if key]
        if keys and not any(all(name in key for name in named) for key in keys):
            found.append(f"no phrase for {action} names {' and '.join(sorted(named))}: {keys}")
    actions = metadata.get("actions") or {}
    for action, policy in AUTHENTICATED.items():
        if action in actions and actions[action].get("authenticationPolicy") != policy:
            found.append(f"{action} does not {POLICIES[policy]}")
    for action, expected in PARAMETERS.items():
        if action in actions:
            taken = {
                p.get("name"): value_type(p.get("valueType") or {})
                for p in actions[action].get("parameters") or []
            }
            if taken != expected:
                found.append(f"{action} takes {taken}, not {expected}")
    for action in IN_BACKGROUND:
        if action in actions and actions[action].get("openAppWhenRun") is not False:
            found.append(f"{action} opens the app")
    for action, entity in OPENS.items():
        if action not in actions:
            continue
        action_metadata = actions[action]
        targets = [
            ((p.get("valueType") or {}).get("entity") or {}).get("wrapper", {}).get("typeName")
            for p in action_metadata.get("parameters") or []
            if p.get("name") == "target"
        ]
        if OPEN_ENTITY not in (action_metadata.get("systemProtocols") or []) or targets != [entity]:
            found.append(f"{action} is not the open intent for {entity}: targets {targets}")
        if action_metadata.get("openAppWhenRun") is not True:
            found.append(f"{action} does not open the app")
    tools = {
        name for name, action in actions.items() if TOOL_INTENT in (action.get("systemProtocols") or [])
    }
    if expect_27_3:
        missing_tools = TOOLS - tools
        if missing_tools:
            found.append(f"missing ToolIntent conformance: {', '.join(sorted(missing_tools))}")
        unexpected_tools = tools - TOOLS
        if unexpected_tools:
            found.append(f"unexpected ToolIntent conformance: {', '.join(sorted(unexpected_tools))}")
        for entity, policy in AUTHENTICATED_ENTITIES.items():
            if entity not in entities:
                continue
            record = entities[entity]
            entity_policy = record.get("authenticationPolicy")
            if entity_policy != policy:
                found.append(f"{entity} does not {POLICIES[policy]}")
            entity_vis = record.get("visibilityMetadata") or {}
            if entity_vis.get("isDiscoverable") is not True or entity_vis.get("assistantOnly") is True:
                found.append(f"{entity} is hidden from Siri and Shortcuts")
            for prop in record.get("properties") or []:
                prop_name = prop.get("identifier")
                eff_policy = (
                    prop.get("authenticationPolicy")
                    if prop.get("authenticationPolicy") is not None
                    else entity_policy
                )
                if eff_policy != policy:
                    found.append(f"{entity}.{prop_name} does not {POLICIES[policy]}")
                vis = (
                    prop["visibilityMetadata"]
                    if prop.get("visibilityMetadata") is not None
                    else entity_vis
                )
                if vis.get("isDiscoverable") is not True or vis.get("assistantOnly") is True:
                    found.append(f"{entity}.{prop_name} is hidden from Siri and Shortcuts")
    else:
        if tools:
            found.append(f"unexpected ToolIntent conformance on pre-27.3 build: {', '.join(sorted(tools))}")
        for entity in AUTHENTICATED_ENTITIES:
            if entity not in entities:
                continue
            record = entities[entity]
            if record.get("authenticationPolicy") not in (None, 0):
                found.append(f"{entity} sets 27.3 authenticationPolicy on pre-27.3 build")
            for prop in record.get("properties") or []:
                if prop.get("authenticationPolicy") not in (None, 0):
                    found.append(
                        f"{entity}.{prop.get('identifier')} sets 27.3 authenticationPolicy"
                        " on pre-27.3 build"
                    )
    return found


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(usage=__doc__.strip().splitlines()[-1])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--sdk-27-3", action="store_true", dest="sdk_27_3")
    group.add_argument("--no-sdk-27-3", action="store_false", dest="sdk_27_3")
    parser.set_defaults(sdk_27_3=None)
    parser.add_argument("target")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args(sys.argv[1:])
    path = metadata_path(args.target)
    if args.sdk_27_3 is None:
        try:
            expect_27_3 = app_uses_sdk_27_3(args.target)
        except ValueError as error:
            print(
                f"cannot determine SDK version ({error}); pass an Agent.app bundle or"
                " --sdk-27-3 / --no-sdk-27-3",
                file=sys.stderr,
            )
            return 2
    else:
        expect_27_3 = args.sdk_27_3
    try:
        metadata = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        print(f"intents metadata unreadable at {path}: {error}", file=sys.stderr)
        return 1
    found = problems(metadata, expect_27_3=expect_27_3)
    if found:
        for problem in found:
            print(f"intents metadata check failed: {problem}", file=sys.stderr)
        return 1
    properties = sum(map(len, ENTITIES.values()))
    summary = (
        f"intents metadata ok actions={len(ACTIONS)} entities={len(ENTITIES)}"
        f" properties={properties} enums={len(ENUMS)} shortcuts={len(metadata['autoShortcuts'])}"
        f" indexed={len(INDEXED)}"
    )
    if expect_27_3:
        summary += f" tools={len(TOOLS)} authenticated_entities={len(AUTHENTICATED_ENTITIES)}"
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
