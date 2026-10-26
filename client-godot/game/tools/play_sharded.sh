#!/usr/bin/env bash
# Spec playable-demo 2.3d: one play report split across parallel headless Godot processes, then merged.
#   game/tools/play_sharded.sh <shards> <out.json> <from> <count> [seed_report --play options...]
# e.g. the gold standard (smart, four members, 300 seeds in 6 shards):
#   game/tools/play_sharded.sh 6 /tmp/smart4.json 1 300 --policy smart --party-size 4 --check
# GODOT overrides the Godot console binary. Every shard runs under tools/watch.sh (killed after 240 s of silence) and
# the Watchdog autoload (quits on a script that failed to load or 180 s without progress).
# Exit: the merged report's code (0, or 3 when a run stopped, an invariant broke or a script or engine error was raised
# in any shard); a shard that ended any other way (124 hung, 70 or 1 broken tool) wins, named with its log.
set -euo pipefail
shards=$1; out=$2; from=$3; count=$4; shift 4
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
here=$(cd "$(dirname "$0")/../.." && pwd)
base=${out%.json}
# Fail fast: a script that doesn't parse leaves Godot idling until --quit-after, which looks like a hang.
if timeout 120 "$godot" --headless --path "$here" --check-only --script res://game/tools/seed_report.gd --quit-after 10 2>&1 		| grep -q "Parse Error"; then
	echo "play_sharded: seed_report.gd does not parse; not starting shards" >&2
	exit 1
fi
size=$(( (count + shards - 1) / shards ))
parts=()
pids=()
for (( i = 0; i < shards; i++ )); do
	start=$(( from + i * size ))
	left=$(( from + count - start ))
	(( left <= 0 )) && break
	n=$(( left < size ? left : size ))
	part="$base.shard$i.json"
	parts+=("$part")
	"$here/../tools/watch.sh" --idle 240 --timeout 3600 --log "$base.shard$i.log" --name "shard$i" -- \
		"$godot" --headless --path "$here" --quit-after 2000000000 res://game/tools/seed_report.tscn -- \
		--play --records --from "$start" --count "$n" --out "$part" "$@" &
	pids+=($!)
done
status=0
for i in "${!pids[@]}"; do
	code=0
	wait "${pids[$i]}" || code=$?
	if (( code != 0 && code != 3 )); then
		echo "play_sharded: shard $i exited $code (log: $base.shard$i.log)" >&2
		status=$code
	fi
done
set +e
timeout 600 "$godot" --headless --path "$here" --quit-after 100000 res://game/tools/seed_report.tscn -- \
	--merge "${parts[@]}" --out "$out" | grep -v "^Godot Engine\|leaked\|still in use\|object.cpp\|resource.cpp"
merged=${PIPESTATUS[0]}
set -e
(( status != 0 )) && exit "$status"
exit "$merged"
