#!/bin/sh
# Dreams check: every `make <target>` that AGENTS.md names must be a target in
# the Makefile. It runs in the candidate checkout and reads both files as data.
# It never runs make, so proposed text is never executed.
status=0
for target in $(grep -o 'make [a-z][a-z0-9-]*' AGENTS.md | cut -d' ' -f2 | sort -u); do
  if ! grep -q "^$target:" Makefile; then
    echo "missing make target: $target"
    status=1
  fi
done
exit $status
