#!/usr/bin/env python3
"""Fails unless a built Agent.app ships every App Intents action, entity with its properties,
enum and query, at least one shortcut, the retry behind authentication, Send Message behind an
unlock of the device that runs it, and each open action as the system's open intent for its
entity. Every shortcut must hold a phrase that is not empty. One of Open Coordinator's phrases
must name ${target} and ${applicationName}, and one of Send Message's must name ${coordinator}
and ${applicationName}. No other action has a phrase. Open Job has none, because a phrase on its
job would make each refresh of the app's phrases read every coordinator's jobs. Send Message
takes exactly a message and one saved coordinator, and runs without opening the app.

A shortcuts provider in the wrong target still builds, and only the extracted metadata shows that
the app ships no phrase.

Usage: check-intents-metadata.py <Agent.app | extract.actionsdata>
"""

import json
import sys
from pathlib import Path

ACTIONS = {
    "OpenCoordinatorIntent",
    "OpenJobIntent",
    "RetryInterruptedRunIntent",
    "SendMessageIntent",
}
ENTITIES = {
    "CoordinatorEntity": {"name"},
    "JobEntity": {"title", "coordinator", "schedule", "state", "lastRun", "nextRun"},
}
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


def value_type(value: dict) -> str | None:
    if "entity" in value:
        return (value["entity"].get("wrapper") or {}).get("typeName")
    if "primitive" in value:
        return f"primitive {(value['primitive'].get('wrapper') or {}).get('typeIdentifier')}"
    return None


def problems(metadata: dict) -> list[str]:
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
        metadata = actions[action]
        targets = [
            ((p.get("valueType") or {}).get("entity") or {}).get("wrapper", {}).get("typeName")
            for p in metadata.get("parameters") or []
            if p.get("name") == "target"
        ]
        if OPEN_ENTITY not in (metadata.get("systemProtocols") or []) or targets != [entity]:
            found.append(f"{action} is not the open intent for {entity}: targets {targets}")
        if metadata.get("openAppWhenRun") is not True:
            found.append(f"{action} does not open the app")
    return found


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    path = metadata_path(sys.argv[1])
    try:
        metadata = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        print(f"intents metadata unreadable at {path}: {error}", file=sys.stderr)
        return 1
    found = problems(metadata)
    if found:
        for problem in found:
            print(f"intents metadata check failed: {problem}", file=sys.stderr)
        return 1
    properties = sum(map(len, ENTITIES.values()))
    print(
        f"intents metadata ok actions={len(ACTIONS)} entities={len(ENTITIES)}"
        f" properties={properties} enums={len(ENUMS)} shortcuts={len(metadata['autoShortcuts'])}"
        f" indexed={len(INDEXED)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
