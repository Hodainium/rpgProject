#!/usr/bin/env bash
# dotnet test through the watcher (spec dev-tools, "Headless safeguards and parallel runs"); the test platform already
# runs projects in parallel. Testcontainers tests need Docker.
#   tools/dotnet_test.sh [dotnet test args...]
root=$(cd "$(dirname "$0")/.." && pwd)
log=$(mktemp)
"$root/tools/watch.sh" --idle 300 --timeout 1800 --log "$log" --name dotnet -- dotnet test "$root/Rpg.slnx" "$@"
code=$?
grep -E "total:|failed:|succeeded:|^failed " "$log" | tr -d '\r'
exit $code
