#!/usr/bin/env bash
# Export the demo for Windows (spec playable-demo 3.12), headless and watched:
#   tools/export.sh [player|dev|full]   (default player)
#   player: preset "Windows Desktop", release template, the game only        -> build/demo/rpgDemo.exe
#   dev:    preset "Windows Desktop Dev", debug template, + console and tools -> build/dev/rpgDemo.exe (+ .console.exe)
#   full:   preset "Windows Desktop Full", debug template, everything (tests) -> build/full/rpgDemo.exe (+ .console.exe)
# The build folder is emptied first. Exit 1 when the export fails or the .exe or .pck is missing; 124 on a stall.
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
# Spec server-authority 3.5: the ruleset version is computed from source here and stamped into the pack (a pack can't
# recompute it); the stamp is removed afterwards, whatever happens.
stamp="$root/client-godot/game/ruleset_stamp.tres"
trap 'rm -f "$stamp"' EXIT
"$root/tools/watch.sh" --name "ruleset-$level" --timeout 300 --log "$out/../ruleset-$level.log" -- \
	"$godot" --headless --path "$root/client-godot" --quit-after 100000 res://game/tools/print_ruleset_version.tscn -- --stamp
code=$?
if (( code != 0 )) || [[ ! -f $stamp ]]; then echo "export.sh: ruleset stamp failed (exit $code)"; exit 1; fi
echo "export.sh: ruleset $(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+\.[a-z0-9.]+\+[0-9a-f]{16}' "$out/../ruleset-$level.log")"
# Godot publishes the C# project with dotnet; without these the compiler and MSBuild servers it starts outlive it,
# keep the log pipe open, and the watcher reports a stall although the export finished.
"$root/tools/watch.sh" --name "export-$level" --timeout 900 --log "$log" -- \
	env MSBUILDDISABLENODEREUSE=1 DOTNET_CLI_USE_MSBUILD_SERVER=0 UseSharedCompilation=false \
	"$godot" --headless --path "$root/client-godot" "$mode" "$preset" "../build/$dir/rpgDemo.exe"
code=$?
if (( code != 0 )); then echo "export.sh: export failed (exit $code), log $log"; exit "$code"; fi
for file in rpgDemo.exe rpgDemo.pck; do
	[[ -f $out/$file ]] || { echo "export.sh: $file missing, log $log"; exit 1; }
done
# The C# half (net/ServerBridge.cs, server mode) ships as a data_* folder of assemblies. Godot reports a failed .NET
# build as an ERROR line yet still exits 0 with a GDScript-only pack, which crashes on the first server link.
if grep -q "ERROR: Export .NET" "$log"; then
	echo "export.sh: the .NET part of the export failed: $(grep -m1 -A1 'ERROR: Export .NET' "$log" | tr '\n' ' ')"
	exit 1
fi
compgen -G "$out/data_*/*.dll" > /dev/null || { echo "export.sh: no data_*/ assemblies next to the exe, log $log"; exit 1; }
echo "export.sh: $level -> build/$dir ($(du -h "$out/rpgDemo.pck" | cut -f1) pack), log $log"
