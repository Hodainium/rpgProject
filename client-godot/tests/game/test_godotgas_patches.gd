## The approved on-disk patches to the vendored GodotGAS addon (client-godot/CLAUDE.md section 0). Each test fails
## when a GodotGAS update brings the bug back, naming the file and line, so the patch is re-applied (or dropped once
## upstream fixed it). They read the addon's source: skipped inside an exported build, which test_cue_manager_loaded
## covers instead.
extends TestCase

const ADDON: String = "res://addons/GodotGAS/"
## Editor-only classes: a runtime script that names one fails to parse in export templates (no editor classes there).
const EDITOR_CLASSES: String = r"\bEditor(Interface|Plugin|Settings|FileSystem|UndoRedoManager|Inspector\w*|Property|ExportPlugin)\b"


## Patch 1: runtime scripts reach EditorInterface through Engine.get_singleton, never by its class name (the
## GameplayCueManager autoload and project_settings.gd it depends on failed to load in every export).
func test_no_editor_classes_in_runtime_scripts() -> void:
	if skip_in_export():
		return
	var pattern := RegEx.create_from_string(EDITOR_CLASSES)
	var found := PackedStringArray()
	for path in _scripts(ADDON):
		var text := FileAccess.get_file_as_string(path)
		if _editor_only(path, text):
			continue
		var lines := text.split("\n")
		for index in lines.size():
			var code := _code(lines[index])
			if pattern.search(code) != null:
				found.append("%s:%d: %s" % [path, index + 1, lines[index].strip_edges()])
	eq(Array(found), [], "editor class names in GodotGAS runtime scripts (use Engine.get_singleton(&\"EditorInterface\"))")


## Patch 2: no script @exports a typed array of its own class (Godot 4.7.2 leaks that script at exit; GameplayEffect's
## overflow_effects did). Also checks our own code.
func test_no_self_typed_exports() -> void:
	if skip_in_export():
		return
	var found := PackedStringArray()
	for root in [ADDON, "res://combat/", "res://game/", "res://godot_gas/"]:
		for path in _scripts(root):
			var text := FileAccess.get_file_as_string(path)
			var own := RegEx.create_from_string(r"(?m)^class_name\s+(\w+)").search(text)
			if own == null:
				continue
			var pattern := RegEx.create_from_string(r"(?m)^@export[^\n]*:\s*Array\[%s\]" % own.get_string(1))
			for hit in pattern.search_all(text):
				found.append("%s: %s" % [path, hit.get_string()])
	eq(Array(found), [], "exported arrays of the script's own class")


## What patch 1 is for, checked in any build (in the exported full build too): the cue manager autoload is loaded.
func test_cue_manager_loaded() -> void:
	var manager := host.get_node_or_null("/root/GameplayCueManager")
	check(manager != null, "the GameplayCueManager autoload exists")
	check(manager != null and manager.get_script() != null, "and its script loaded")


## Editor-only: under editor/, or the script extends an editor class (plugins, inspector properties).
func _editor_only(path: String, text: String) -> bool:
	if path.contains("/editor/"):
		return true
	var base := RegEx.create_from_string(r"(?m)^(?:class_name\s+\w+\s+)?extends\s+(\w+)").search(text)
	return base != null and base.get_string(1).begins_with("Editor")


## The line without its comment and string literals (&"EditorInterface" in a lookup is fine).
func _code(line: String) -> String:
	var code := RegEx.create_from_string(r'&?"(?:[^"\\]|\\.)*"').sub(line, '""', true)
	var hash_at := code.find("#")
	return code.substr(0, hash_at) if hash_at >= 0 else code


func _scripts(directory: String) -> PackedStringArray:
	var found := PackedStringArray()
	for name in DirAccess.get_directories_at(directory):
		found.append_array(_scripts(directory + name + "/"))
	for name in DirAccess.get_files_at(directory):
		if name.ends_with(".gd"):
			found.append(directory + name)
	return found
