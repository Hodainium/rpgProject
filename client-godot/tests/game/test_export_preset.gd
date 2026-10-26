## Spec playable-demo 3.12 (D5, D33): the export presets player / dev / full (export_presets.cfg). A shipped script or
## scene that names an excluded class, preloads an excluded file or loads it as an ext_resource would fail to parse in
## that build only, so these tests catch it here instead of in the build. They read project source: skipped inside an
## exported build.
extends TestCase

const PRESETS: String = "res://export_presets.cfg"
## Scanned for references; the vendored addon never names our classes.
const SKIP_DIRS: Array[String] = ["res://.godot/", "res://addons/GodotGAS/"]
## preset name -> [export path]
const LEVELS: Dictionary = {
	"Windows Desktop": ["../build/demo/rpgDemo.exe"],
	"Windows Desktop Dev": ["../build/dev/rpgDemo.exe"],
	"Windows Desktop Full": ["../build/full/rpgDemo.exe"],
}


func test_export_presets() -> void:
	if skip_in_export():
		return
	var presets := _presets()
	eq(presets.keys(), LEVELS.keys(), "one preset per level, in order")
	for name in presets:
		var preset: Dictionary = presets[name]
		eq(preset["export_path"], LEVELS[name][0], "%s exports to its build folder" % name)
	var player: Dictionary = presets["Windows Desktop"]
	for path in ["res://tests/run_tests.gd", "res://game/tools/dev_run.gd", "res://game/dev/commands/give.gd",
			"res://game/dev/content/items", "res://addons/rpg_dev/plugin.gd", "res://combat/headless/replay_main.gd",
			"res://game/dev/run_player.gd"]:
		check(_excluded(player["excludes"], path), "%s stays out of the player build" % path)
	var dev: Dictionary = presets["Windows Desktop Dev"]
	for path in ["res://game/tools/dev_run.tscn", "res://game/dev/commands/give.gd", "res://game/dev/content/items",
			"res://game/dev/run_player.gd"]:
		check(not _excluded(dev["excludes"], path), "%s ships in the dev build" % path)
	check(_excluded(dev["excludes"], "res://tests/run_tests.gd"), "the dev build has no tests")
	# Templates take no scene on the command line: dev and full start build_entry.tscn (feature dev_build).
	eq(player["features"], "", "the player build has no dev_build feature")
	check(_excluded(player["excludes"], "res://game/dev/build_entry.tscn"), "nor the build launcher")
	eq(dev["features"], "dev_build", "the dev build starts the build launcher")
	eq(presets["Windows Desktop Full"]["features"], "dev_build", "so does the full build")
	eq(ProjectSettings.get_setting("application/run/main_scene.dev_build", ""), "res://game/dev/build_entry.tscn",
		"main_scene.dev_build names the launcher")
	eq(presets["Windows Desktop Full"]["excludes"], PackedStringArray(), "the full build ships everything")


## Per preset: autoloads, the main scene and everything shipped files need ship.
func test_export_keeps_what_runs() -> void:
	if skip_in_export():
		return
	var needed: Array[String] = [str(ProjectSettings.get_setting("application/run/main_scene"))]
	for property in ProjectSettings.get_property_list():
		var name: String = property["name"]
		if name.begins_with("autoload/"):
			needed.append(str(ProjectSettings.get_setting(name)).trim_prefix("*"))
	var files: Array[String] = []
	_walk("res://", files)
	var presets := _presets()
	for preset_name in presets:
		var excludes: PackedStringArray = presets[preset_name]["excludes"]
		for path in needed:
			check(not _excluded(excludes, path), "%s: %s ships" % [preset_name, path])
		eq(Array(_broken_references(excludes, files)), [], "%s: no shipped file depends on an excluded one" % preset_name)


## The title menu offers only the content roots the build has (the export leaves tests/fixtures out).
func test_content_roots() -> void:
	if skip_in_export():
		return
	eq(GameMain.content_roots(), GameMain.CONTENT_ROOTS, "both roots exist in the project")


## preset name -> {export_path, features, excludes}
func _presets() -> Dictionary:
	var file := ConfigFile.new()
	var result := {}
	if file.load(PRESETS) != OK:
		failures.append("export_presets.cfg does not load")
		return result
	for section in file.get_sections():
		if section.contains(".options"):
			continue
		var excludes := PackedStringArray()
		for part in str(file.get_value(section, "exclude_filter", "")).split(","):
			if part.strip_edges() != "":
				excludes.append(part.strip_edges())
		result[file.get_value(section, "name", "")] = {
			"export_path": file.get_value(section, "export_path", ""),
			"features": file.get_value(section, "custom_features", ""),
			"excludes": excludes,
		}
	return result


func _broken_references(excludes: PackedStringArray, files: Array[String]) -> PackedStringArray:
	var problems := PackedStringArray()
	var excluded_classes := {}  # class_name -> file
	for path in files:
		if _excluded(excludes, path) and path.ends_with(".gd"):
			var found := RegEx.create_from_string("(?m)^class_name\\s+(\\w+)").search(FileAccess.get_file_as_string(path))
			if found != null:
				excluded_classes[found.get_string(1)] = path
	var names := RegEx.create_from_string("\\b(%s)\\b" % "|".join(excluded_classes.keys())) if not excluded_classes.is_empty() else null
	var paths := RegEx.create_from_string("(?:preload\\(|ext_resource[^\\n]*path=)\"(res://[^\"]+)\"")
	var comments := RegEx.create_from_string("#[^\\n]*")
	for path in files:
		if _excluded(excludes, path) or not (path.ends_with(".gd") or path.ends_with(".tscn") or path.ends_with(".tres")):
			continue
		var text := FileAccess.get_file_as_string(path)
		if path.ends_with(".gd"):
			text = comments.sub(text, "", true)  # comments may name dev tools
			if names != null:
				for found in names.search_all(text):
					problems.append("%s names %s (%s)" % [path, found.get_string(1), excluded_classes[found.get_string(1)]])
		for found in paths.search_all(text):
			if _excluded(excludes, found.get_string(1)):
				problems.append("%s loads %s" % [path, found.get_string(1)])
	return problems


func _excluded(excludes: PackedStringArray, path: String) -> bool:
	for pattern in excludes:
		if path.matchn(pattern) or (path + "/").matchn(pattern):
			return true
	return false


func _walk(directory: String, out: Array[String]) -> void:
	if directory in SKIP_DIRS:
		return
	for name in DirAccess.get_directories_at(directory):
		_walk(directory + name + "/", out)
	for name in DirAccess.get_files_at(directory):
		out.append(directory + name)
