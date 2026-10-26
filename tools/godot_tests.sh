#!/usr/bin/env bash
# The Godot system tests in parallel shards, each watched (spec dev-tools, "Headless safeguards and parallel runs").
#   tools/godot_tests.sh [-j N] [-- runner args like --filter <text> | --update-goldens]
# N defaults to 8 (or half the cores); --update-goldens always runs as one shard. Exit 1 on any failure or stall.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
cores=$(nproc 2> /dev/null || echo 4)
jobs=$(( cores / 2 > 8 ? 8 : (cores / 2 > 0 ? cores / 2 : 1) ))
while [[ $# -gt 0 && $1 != "--" ]]; do
	case $1 in
		-j) jobs=$2; shift 2 ;;
		*) echo "godot_tests.sh: unknown option $1" >&2; exit 2 ;;
	esac
done
[[ ${1:-} == "--" ]] && shift
[[ " $* " == *" --update-goldens "* ]] && jobs=1
logs=$(mktemp -d)
start=$(date +%s)
pids=()
for (( i = 0; i < jobs; i++ )); do
	"$root/tools/watch.sh" --idle 240 --timeout 2400 --log "$logs/shard$i.log" --name "tests$i/$jobs" -- \
		"$godot" --headless --path "$root/client-godot" --quit-after 2000000000 res://tests/run_tests.tscn -- \
		--shard "$i/$jobs" "$@" > "$logs/watch$i.log" 2>&1 &
	pids+=($!)
done
status=0
for (( i = 0; i < jobs; i++ )); do
	wait "${pids[$i]}"; code=$?
	if (( code != 0 && code != 1 )); then
		echo "shard $i/$jobs stopped (exit $code):"; cat "$logs/watch$i.log"; status=1
	fi
done
passed=0; failed=0
for (( i = 0; i < jobs; i++ )); do
	line=$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$logs/shard$i.log" | tail -1)
	if [[ -z $line ]]; then echo "shard $i/$jobs printed no totals (see $logs/shard$i.log)"; status=1; continue; fi
	passed=$(( passed + $(echo "$line" | cut -d' ' -f1) ))
	failed=$(( failed + $(echo "$line" | cut -d' ' -f3) ))
	grep -A8 '^  FAIL' "$logs/shard$i.log" | grep -E '^  FAIL|^          ' | tr -d '\r'
done
echo "$passed passed, $failed failed ($jobs shards, $(( $(date +%s) - start ))s, logs in $logs)"
(( failed > 0 || passed == 0 )) && status=1
exit $status
