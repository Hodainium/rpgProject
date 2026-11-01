## The ruleset version a run starts under (spec server-authority 3.5): "<godot version>+<first 16 hex of SHA-256>"
## over the sorted paths and source bytes of the rule roots, minus the dev-only and tool paths the player preset
## excludes (they never affect rules) and Godot's .uid/.import side files.
##
## An exported pack can't recompute it (scripts ship as binary tokens, text resources as binary, and each preset leaves
## out different files), so tools/export.sh stamps it into the pack at export time (STAMP_PATH, through
## game/tools/print_ruleset_version.tscn -- --stamp) and an exported build reads the stamp. The editor and headless
## runs from the project compute it live with the same rules, so every preset of one source tree, and the verifier,
## share one version.
class_name RulesetVersion
extends RefCounted

const ROOTS: Array[String] = ["res://combat/", "res://game/", "res://content/", "res://godot_gas/",
	"res://addons/GodotGAS/"]
const STAMP_PATH: String = "res://game/ruleset_stamp.tres"
const PRESETS_PATH: String = "res://export_presets.cfg"
## The player preset: its exclusions are the dev-only and tool paths.
const PLAYER_PRESET: String = "Windows Desktop"
const SKIPPED_EXTENSIONS: Array[String] = ["uid", "import"]


## The running build's version: the stamp in an exported build, computed live otherwise.
static func current() -> String:
	return stamped() if OS.has_feature("template") else compute()


## The version stamped at export time, or "" when the pack has none.
static func stamped() -> String:
	if not ResourceLoader.exists(STAMP_PATH):
		return ""
	var stamp := load(STAMP_PATH) as RulesetStamp
	return stamp.version if stamp != null else ""


## Computes the version from the project's source files.
static func compute() -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for path in files():
		var bytes := FileAccess.get_file_as_bytes(path)
		# Path, NUL, 8-byte length, bytes: no two file sets can produce the same stream.
		var header := path.to_utf8_buffer()
		header.append(0)
		var size := PackedByteArray()
		size.resize(8)
		size.encode_s64(0, bytes.size())
		header.append_array(size)
		context.update(header)
		if not bytes.is_empty():
			context.update(bytes)
	return "%s+%s" % [engine_version(), context.finish().hex_encode().substr(0, 16)]


## "4.7.2.stable.mono" (".mono" on the .NET build).
static func engine_version() -> String:
	var info := Engine.get_version_info()
	return "%d.%d.%d.%s%s" % [info["major"], info["minor"], info["patch"], info["status"],
		".mono" if ClassDB.class_exists(&"CSharpScript") else ""]


## The hashed files, sorted.
static func files() -> PackedStringArray:
	var excluded := player_exclusions()
	var found := PackedStringArray()
	for root in ROOTS:
		_collect(root, found)
	var result := PackedStringArray()
	for path in found:
		if path == STAMP_PATH or SKIPPED_EXTENSIONS.has(path.get_extension()):
			continue
		if excluded.any(func(pattern: String) -> bool: return path.match(pattern)):
			continue
		result.append(path)
	result.sort()
	return result


## The player preset's exclude_filter patterns (empty when the presets file is missing).
static func player_exclusions() -> Array[String]:
	var presets := ConfigFile.new()
	var patterns: Array[String] = []
	if presets.load(PRESETS_PATH) != OK:
		return patterns
	for section in presets.get_sections():
		if section.count(".") == 1 and presets.get_value(section, "name", "") == PLAYER_PRESET:
			for pattern in str(presets.get_value(section, "exclude_filter", "")).split(",", false):
				patterns.append(pattern.strip_edges())
	return patterns


static func _collect(directory: String, into: PackedStringArray) -> void:
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	# Names starting with "." (.gitkeep, .gitignore, a stray dot-folder) are skipped on every platform: Godot lists them on
	# Windows but treats them as hidden on Linux, which gave the Linux verifier another version than the Windows build
	# for the same tree (found by tools/verifier_image_check.sh). They never affect rules.
	for file in dir.get_files():
		if not file.begins_with("."):
			into.append(directory.path_join(file))
	for sub in dir.get_directories():
		if not sub.begins_with("."):
			_collect(directory.path_join(sub), into)
