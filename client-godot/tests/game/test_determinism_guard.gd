## Playtest-fixes B24 (client-godot/CLAUDE.md section 3): no run or battle code orders StringNames by pointer. A plain .sort() on an
## array that may hold StringNames (dictionary keys of tags and ids, untyped arrays) orders them by their interned pointer, which
## differs between a windowed client and the headless verifier; the hash or conditions then differ and the run is rejected (2002).
## Reads the project's source, so it is skipped inside an exported build.
extends TestCase

## The code that decides, hashes or uploads a run or a battle. Presentation and dev tooling (game/dev, game/tools, game/ui, game/fx,
## game/view) never reach a hash and are left out.
const ROOTS: Array[String] = ["res://combat/", "res://game/"]
const SKIPPED: Array[String] = ["res://game/dev/", "res://game/tools/", "res://game/ui/", "res://game/fx/", "res://game/view/"]
## A declaration whose type can only hold text or numbers: sorting it is safe.
const SAFE_TYPES := "(PackedStringArray|PackedInt32Array|PackedInt64Array|PackedFloat32Array|PackedFloat64Array|Array\\[(String|int|float)\\])"


func test_no_pointer_ordered_sorts() -> void:
	if skip_in_export():
		return
	var offenders := PackedStringArray()
	var checked := 0
	for path in _scripts():
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for index in lines.size():
			var line: String = lines[index]
			if line.strip_edges().begins_with("#"):
				continue
			var risky := risky_order(lines, index)
			if risky == "":
				continue
			checked += 1
			if not line.contains("# sort-ok:"):
				offenders.append("%s:%d  %s  (%s)" % [path, index + 1, line.strip_edges(), risky])
	check(checked > 5, "the guard sees the code's sorts (%d)" % checked)
	eq(offenders, PackedStringArray(), "a plain .sort() on an array that may hold StringNames orders them by pointer: sort by "
		+ "String(a) < String(b), type the array as strings or numbers, or mark the line `# sort-ok: <why>`")


## Why line `at` may order StringNames by pointer ("" when it cannot): a plain .sort(), .min() or .max() on an array not typed as
## text or numbers, a chained `...).sort()`, or a sort_custom comparing raw values with < or > (not String(), str(), int(), float()
## or another call).
static func risky_order(lines: PackedStringArray, at: int) -> String:
	var line: String = lines[at]
	var call := RegEx.create_from_string("([A-Za-z_][A-Za-z0-9_]*)\\.(sort|min|max)\\(\\)")
	var found := call.search(line)
	if found != null and not _declared_safe(lines, at, found.get_string(1)):
		return "plain %s() on an array that may hold StringNames" % found.get_string(2)
	if RegEx.create_from_string("\\)\\.(sort|min|max)\\(\\)").search(line) != null:
		return "a chained sort, min or max"
	if line.contains("sort_custom") and RegEx.create_from_string("return\\s+[A-Za-z_][A-Za-z0-9_.]*(\\[[^\\]]*\\])?\\s*[<>]").search(line) != null:
		return "a sort_custom comparing raw values"
	return ""


## The guard catches the B24 shapes and lets the safe ones through (the rule itself, on code written here).
func test_the_guard_tells_the_shapes_apart() -> void:
	var cases := {
		"var gear: Array = member[\"equipment\"].keys()\ngear.sort()": true,
		"var names: Array[String] = []\nnames.sort()": false,
		"var lines := PackedStringArray()\nlines.sort()": false,
		"var x = 1\nvar first = tags.min()": true,
		"var x = 1\nids.keys().sort()": true,
		"var x = 1\nids.sort_custom(func(a, b) -> bool: return a < b)": true,
		"var x = 1\nids.sort_custom(func(a, b) -> bool: return String(a) < String(b))": false,
		"var x = 1\nunits.sort_custom(func(a, b) -> bool: return _hp(a) < _hp(b))": false,
	}
	for code in cases:
		var lines := PackedStringArray(String(code).split("\n"))
		eq(risky_order(lines, 1) != "", cases[code], "%s is %s" % [lines[1], "flagged" if cases[code] else "allowed"])


## True when `name` is declared (above `at`, nearest first) with a type that holds only text or numbers.
static func _declared_safe(lines: PackedStringArray, at: int, name: String) -> bool:
	var typed := RegEx.create_from_string("var %s\\s*:\\s*%s" % [name, SAFE_TYPES])
	var made := RegEx.create_from_string("var %s\\s*:?=\\s*%s\\(" % [name, SAFE_TYPES])
	var any := RegEx.create_from_string("var %s\\b" % name)
	for index in range(at, -1, -1):
		var line: String = lines[index]
		if any.search(line) == null:
			continue
		return typed.search(line) != null or made.search(line) != null
	return false  # declared elsewhere (a member or a parameter): not provably safe


func _scripts() -> PackedStringArray:
	var found := PackedStringArray()
	for root in ROOTS:
		_collect(root, found)
	return found


func _collect(directory: String, found: PackedStringArray) -> void:
	for skipped in SKIPPED:
		if directory.begins_with(skipped):
			return
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd"):
			found.append(directory.path_join(file))
	for sub in DirAccess.get_directories_at(directory):
		_collect(directory.path_join(sub) + "/", found)
