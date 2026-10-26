#!/usr/bin/env bash
# Export the demo for Windows (spec playable-demo 3.12), headless and watched:
#   tools/export.sh [player|dev|full]   (default player)
#   player: preset "Windows Desktop", release template, the game only        -> build/demo/rpgDemo.exe
#   dev:    preset "Windows Desktop Dev", debug template, + console and tools -> build/dev/rpgDemo.exe (+ .console.exe)
#   full:   preset "Windows Desktop Full", debug template, everything (tests) -> build/full/rpgDemo.exe (+ .console.exe)
# The build folder is emptied first. Exit 1 when the export fails, a GodotGAS export patch no longer matches
# ("RPG export:" in the log) or the .exe or .pck is missing; 124 on a stall.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
level=${1:-player}
case $level in
	player) preset="Windows Desktop"; mode=--export-release; dir=demo ;;
	dev) preset="Windows Desktop Dev"; mode=--export-debug; dir=dev ;;
	full) preset="Windows Desktop Full"; mode=--export-debug; dir=full ;;
	*) echo "export.sh: level must be player, dev or full (got '$level')" >&2; exit 2 ;;
esac
out="$root/build/$dir"
rm -rf "$out"; mkdir -p "$out"
log="$out/../export-$level.log"
"$root/tools/watch.sh" --name "export-$level" --timeout 900 --log "$log" -- \
	"$godot" --headless --path "$root/client-godot" "$mode" "$preset" "../build/$dir/rpgDemo.exe"
code=$?
if (( code != 0 )); then echo "export.sh: export failed (exit $code), log $log"; exit "$code"; fi
if grep -q 'RPG export:' "$log"; then grep 'RPG export:' "$log"; echo "export.sh: an export patch failed, log $log"; exit 1; fi
for file in rpgDemo.exe rpgDemo.pck; do
	[[ -f $out/$file ]] || { echo "export.sh: $file missing, log $log"; exit 1; }
done
echo "export.sh: $level -> build/$dir ($(du -h "$out/rpgDemo.pck" | cut -f1) pack), log $log"
