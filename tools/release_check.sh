#!/usr/bin/env bash
# Release check (spec playable-demo 3.12 D35): starts an exported build in a window and checks it from outside
# (tools/release_check.py): title screen shot, a backtick keypress, a second shot, no script or engine errors in its log.
#   tools/release_check.sh <shots folder> [player|dev]   (default player: build/demo, the console must NOT open;
#                                                          dev: build/dev, the control, the console MUST open)
# Takes focus for a few seconds. Exit 0 ok, 1 a check failed, 2 no build or no window, 124 a stall.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
shots=${1:?usage: tools/release_check.sh <shots folder> [player|dev]}
level=${2:-player}
case $level in
	player) exe="$root/build/demo/rpgDemo.exe"; expect=no ;;
	dev) exe="$root/build/dev/rpgDemo.exe"; expect=yes ;;
	*) echo "release_check.sh: level must be player or dev" >&2; exit 2 ;;
esac
log=$(mktemp)
"$root/tools/watch.sh" --name "release-check-$level" --timeout 180 --log "$log" -- \
	python "$root/tools/release_check.py" --exe "$exe" --name "$level" --shots "$shots" --expect-console "$expect"
code=$?
cat "$log"
exit $code
