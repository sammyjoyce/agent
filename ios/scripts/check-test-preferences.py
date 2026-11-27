#!/usr/bin/env python3
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1] / "Tests"
violations = []
for path in root.rglob("*.swift"):
    if path.relative_to(root) == pathlib.Path("AgentCoreTests/TestPreferences.swift"):
        continue
    source = re.sub(
        r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"',
        lambda match: "\n" * match.group().count("\n"),
        path.read_text(),
        flags=re.DOTALL,
    )
    for number, line in enumerate(source.splitlines(), 1):
        if re.search(r"\bUserDefaults\b", line):
            violations.append(f"{path}:{number}: use TestPreferences() from AgentCoreTests/TestPreferences.swift; tests must not access disk-backed preferences")
if violations:
    print("\n".join(violations), file=sys.stderr)
    sys.exit(1)
