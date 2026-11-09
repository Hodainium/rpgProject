#!/usr/bin/env bash
# Spec card-collection 2.1: a report, not a test (system tests never depend on the user's content). Rebuilds the card catalog from
# client-godot/content and compares it with infra/economy/card_catalog.json, the file the server seeds from. Exit 0 same,
# 1 different (re-run build_card_catalog.tscn and commit the file), 3 the content has card problems.
#   tools/check_card_catalog.sh
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/h/Godot/Godot_v4.7.2-stable_mono_win64_console.exe}
fresh=$(mktemp)
"$root/tools/watch.sh" --idle 120 --timeout 300 --name card-catalog -- "$godot" --headless --path "$root/client-godot" --quit-after 900 \
	res://game/tools/build_card_catalog.tscn -- --out "$fresh" || { echo "check_card_catalog: the content has card problems (see above)"; exit 3; }
if diff -q <(tr -d '\r' <"$fresh") <(tr -d '\r' <"$root/infra/economy/card_catalog.json") >/dev/null; then
	echo "check_card_catalog: infra/economy/card_catalog.json matches the content"
	exit 0
fi
echo "check_card_catalog: the content and infra/economy/card_catalog.json differ: run build_card_catalog.tscn and commit the file"
python -I - "$fresh" "$root/infra/economy/card_catalog.json" <<'PY'
import json, sys
new = {c["id"]: c for c in json.load(open(sys.argv[1]))["cards"]}
old = {c["id"]: c for c in json.load(open(sys.argv[2]))["cards"]}
for i in sorted(new.keys() - old.keys()): print("  new in content:", i)
for i in sorted(old.keys() - new.keys()): print("  only in the file:", i)
for i in sorted(new.keys() & old.keys()):
    if new[i] != old[i]: print("  changed:", i)
PY
exit 1
