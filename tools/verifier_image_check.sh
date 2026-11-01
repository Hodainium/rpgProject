#!/usr/bin/env bash
# Spec battle-verify 6: the cross-platform determinism check, on demand (Docker required, a few minutes plus the Godot
# download). Builds infra/verifier/Dockerfile and, inside the Linux container:
#   1. the ruleset version must equal the one the Windows build computes for the same source;
#   2. every committed combat golden (recorded on Windows) must replay to Verified (exit 0) and every tampered copy to
#      Rejected 2002 (exit 2), each with the SAME final state hash as its committed .result.json.
# This is what the fixed-point rules in client-godot/CLAUDE.md section 3 exist for: a hash that differs here is a false
# 2002 for every honest player on the other platform.
#   tools/verifier_image_check.sh [--no-build] [--image NAME]
# Exit 0 all match, 1 any difference or a build/run failure, 124 a stall.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
image=rpg-verifier:check
build=1
while [[ $# -gt 0 ]]; do
	case $1 in
		--no-build) build=0; shift ;;
		--image) image=$2; shift 2 ;;
		*) echo "verifier_image_check.sh: unknown option $1" >&2; exit 2 ;;
	esac
done
command -v docker > /dev/null 2>&1 || { echo "verifier_image_check.sh: docker not found"; exit 1; }
out="$root/build/image_check/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$out"
win() { cygpath -m "$1" 2> /dev/null || echo "$1"; }
version_pattern='[0-9]+\.[0-9]+\.[0-9]+\.[a-z0-9.]+\+[0-9a-f]{16}'
failures=0

if (( build )); then
	echo "verifier_image_check.sh: building $image (the Godot download is large on the first run)"
	"$root/tools/watch.sh" --name image-build --idle 600 --timeout 3600 --log "$out/build.log" -- \
		docker build -f "$root/infra/verifier/Dockerfile" -t "$image" "$root"
	code=$?
	(( code == 0 )) || { echo "FAIL build (exit $code), see $out/build.log"; tail -15 "$out/build.log"; exit 1; }
	grep -i "WARNING: godot --import" "$out/build.log" && echo "note: the import step reported a problem (above)"
fi

# --- 1. The ruleset version ------------------------------------------------------------------------------------------
linux_log="$out/ruleset-linux.log"
MSYS_NO_PATHCONV=1 "$root/tools/watch.sh" --name image-ruleset --timeout 300 --log "$linux_log" -- \
	docker run --rm --entrypoint godot "$image" --headless --path /srv/client-godot --quit-after 100000 \
	res://game/tools/print_ruleset_version.tscn
linux_version=$(grep -oE "^$version_pattern\$" "$linux_log" | tail -1 | tr -d '\r')
windows_log="$out/ruleset-windows.log"
"$root/tools/watch.sh" --name windows-ruleset --timeout 300 --log "$windows_log" -- \
	"$godot" --headless --path "$root/client-godot" --quit-after 100000 res://game/tools/print_ruleset_version.tscn
windows_version=$(grep -oE "^$version_pattern\$" "$windows_log" | tail -1 | tr -d '\r')
if [[ -n $linux_version && $linux_version == "$windows_version" ]]; then
	echo "ok   ruleset version $linux_version (Linux image = Windows build)"
else
	echo "FAIL ruleset version: image '$linux_version', Windows '$windows_version'"
	failures=$((failures + 1))
fi

# --- 2. The goldens --------------------------------------------------------------------------------------------------
goldens="$root/client-godot/tests/fixtures/golden"
MSYS_NO_PATHCONV=1 "$root/tools/watch.sh" --name image-replay --idle 600 --timeout 3600 --log "$out/replay.log" -- \
	docker run --rm --entrypoint bash -v "$(win "$goldens"):/goldens:ro" "$image" -c '
		for f in /goldens/*.json; do
			case $f in *.result.json|*.trace.json) continue ;; esac
			name=$(basename "$f" .json)
			timeout 120 godot --headless --path /srv/client-godot --quit-after 200000 \
				res://combat/headless/replay_main.tscn -- --in "$f" --out "/tmp/$name.res.json" \
				--content-root res://tests/fixtures/ > "/tmp/$name.log" 2>&1
			echo "RESULT $name $? $(grep -o "\"finalStateHash\":\"[0-9a-f]*\"" "/tmp/$name.res.json" 2> /dev/null)"
		done'
code=$?
(( code == 124 )) && { echo "FAIL the replay stalled"; exit 124; }
checked=0
while read -r _ name exit_code hash_field; do
	[[ -n $name ]] || continue
	checked=$((checked + 1))
	expected_exit=0; [[ $name == *-tampered-* ]] && expected_exit=2
	expected_hash=$(grep -o '"finalStateHash":"[0-9a-f]*"' "$goldens/$name.result.json" 2> /dev/null | head -1)
	if [[ $exit_code == "$expected_exit" && -n $expected_hash && $hash_field == "$expected_hash" ]]; then
		echo "ok   $name (exit $exit_code, ${hash_field:17:12}...)"
	else
		echo "FAIL $name: exit $exit_code (expected $expected_exit), $hash_field (expected $expected_hash)"
		failures=$((failures + 1))
	fi
done < <(grep '^RESULT ' "$out/replay.log" | tr -d '\r')
(( checked >= 10 )) || { echo "FAIL only $checked golden(s) replayed, see $out/replay.log"; failures=$((failures + 1)); }
echo "verifier_image_check.sh: $checked golden(s), $failures failure(s) (logs in $out)"
(( failures == 0 ))
