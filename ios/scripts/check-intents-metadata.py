#!/usr/bin/env python3
"""Fails unless a built Agent.app ships every App Intents action, entity with its properties,
enum and query, at least one shortcut, each for Open Coordinator, and the retry behind
authentication. It does not check that a shortcut holds a phrase.

A shortcuts provider in the wrong target still builds, and only the extracted metadata shows that
the app ships no phrase.

Usage: check-intents-metadata.py <Agent.app | extract.actionsdata>
"""

import json
import sys
from pathlib import Path

ACTIONS = {"OpenCoordinatorIntent", "RetryInterruptedRunIntent"}
ENTITIES = {
    "CoordinatorEntity": {"name"},
    "JobEntity": {"title", "coordinator", "schedule", "state", "lastRun", "nextRun"},
}
ENUMS = {"JobRunState"}
QUERIES = {"CoordinatorQuery", "JobQuery"}
PHRASED = {"OpenCoordinatorIntent"}
# `authenticationPolicy` 1 is `.requiresAuthentication`.
AUTHENTICATED = {"RetryInterruptedRunIntent": 1}


def metadata_path(argument: str) -> Path:
    path = Path(argument)
    if path.is_dir():
        return path / "Metadata.appintents" / "extract.actionsdata"
    return path


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
    shortcuts = metadata.get("autoShortcuts") or []
    if not shortcuts:
        found.append("autoShortcuts is empty, so the app ships no phrase")
    phrased = {s.get("actionIdentifier") for s in shortcuts}
    if shortcuts and PHRASED - phrased:
        found.append(f"no phrase runs {', '.join(sorted(PHRASED - phrased))}")
    if phrased - PHRASED:
        unexpected = ", ".join(sorted(map(str, phrased - PHRASED)))
        found.append(f"a phrase runs {unexpected}, which must have none")
    actions = metadata.get("actions") or {}
    for action, policy in AUTHENTICATED.items():
        if action in actions and actions[action].get("authenticationPolicy") != policy:
            found.append(f"{action} does not require authentication")
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
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
