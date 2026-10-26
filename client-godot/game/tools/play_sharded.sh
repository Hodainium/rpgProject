#!/usr/bin/env bash
# Spec playable-demo 2.3d: one play report split across parallel headless Godot processes, then merged.
#   game/tools/play_sharded.sh <shards> <out.json> <from> <count> [seed_report --play options...]
# e.g. the gold standard (smart, four members, 300 seeds in 6 shards):
#   game/tools/play_sharded.sh 6 /tmp/smart4.json 1 300 --policy smart --party-size 4 --check
# GODOT overrides the Godot console binary. Every shard has a timeout and a large --quit-after.
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
for (( i = 0; i < shards; i++ )); do
	start=$(( from + i * size ))
	left=$(( from + count - start ))
	(( left <= 0 )) && break
	n=$(( left < size ? left : size ))
	part="$base.shard$i.json"
	parts+=("$part")
	timeout 3600 "$godot" --headless --path "$here" --quit-after 2000000000 res://game/tools/seed_report.tscn -- \
		--play --records --from "$start" --count "$n" --out "$part" "$@" > "$base.shard$i.log" 2>&1 &
done
status=0
wait || status=$?
timeout 600 "$godot" --headless --path "$here" --quit-after 100000 res://game/tools/seed_report.tscn -- \
	--merge "${parts[@]}" --out "$out" | grep -v "^Godot Engine\|leaked\|still in use\|object.cpp\|resource.cpp" || true
