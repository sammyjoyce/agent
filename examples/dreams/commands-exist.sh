#!/bin/sh
status=0
for target in $(grep -o 'make [a-z][a-z0-9-]*' AGENTS.md | cut -d' ' -f2 | sort -u); do
  if ! grep -q "^$target:" Makefile; then
    echo "missing make target: $target"
    status=1
  fi
done
exit $status
