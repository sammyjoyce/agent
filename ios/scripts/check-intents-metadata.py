#!/usr/bin/env python3
"""Fails unless a built Agent.app ships every App Intents action, entity and query, and a phrase.

A shortcuts provider in the wrong target still builds, and only the extracted metadata shows that
the app ships no phrase.

Usage: check-intents-metadata.py <Agent.app | extract.actionsdata>
"""

import json
import sys
from pathlib import Path

ACTIONS = {"OpenCoordinatorIntent"}
ENTITIES = {"CoordinatorEntity"}
QUERIES = {"CoordinatorQuery"}


def metadata_path(argument: str) -> Path:
    path = Path(argument)
    if path.is_dir():
        return path / "Metadata.appintents" / "extract.actionsdata"
    return path


def problems(metadata: dict) -> list[str]:
    found = []
    for kind, expected in (("actions", ACTIONS), ("entities", ENTITIES), ("queries", QUERIES)):
        missing = expected - set(metadata.get(kind) or {})
        if missing:
            found.append(f"missing {kind}: {', '.join(sorted(missing))}")
    shortcuts = metadata.get("autoShortcuts") or []
    if not shortcuts:
        found.append("autoShortcuts is empty, so the app ships no phrase")
    unknown = {s.get("actionIdentifier") for s in shortcuts} - ACTIONS
    if unknown:
        found.append(f"shortcuts name unexpected actions: {', '.join(sorted(map(str, unknown)))}")
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
    print(
        f"intents metadata ok actions={len(ACTIONS)} entities={len(ENTITIES)}"
        f" shortcuts={len(metadata['autoShortcuts'])}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
