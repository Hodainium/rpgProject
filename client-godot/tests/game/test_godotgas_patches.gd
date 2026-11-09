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


# --- Patch 3 and 4: lazy cue scenes and suppression (spec vfx-framework; GameplayCueEntry, GameplayCueManager) -------------

const PROBE_SCENE: String = "user://gas_patch_probe_cue.tscn"
const PROBE_REGISTRY: String = "user://gas_patch_probe_registry.tres"


## A scene for the probes, saved to user:// (the cue scenes of the game are presentation, which system tests avoid).
func _probe_scene() -> PackedScene:
	var node := Node.new()
	node.name = "ProbeCue"
	var packed := PackedScene.new()
	packed.pack(node)
	node.free()
	ResourceSaver.save(packed, PROBE_SCENE)
	return load(PROBE_SCENE) as PackedScene


## Patch 3: a saved registry names its scenes (scene_ref) and does not hold them, so loading it loads no cue scene; an
## entry's `scene` still reads and writes like before (the dashboard uses it).
func test_cue_entry_stores_a_reference_not_the_scene() -> void:
	var scene := _probe_scene()
	var entry := GameplayCueEntry.new()
	entry.tag = &"Cue.Test.Probe"
	entry.scene = scene
	eq(entry.scene_ref, PROBE_SCENE, "the setter records the scene's path")
	eq(entry.scene_path(), PROBE_SCENE, "scene_path resolves it without loading")
	var registry := GameplayCueRegistry.new()
	registry.entries.append(entry)
	eq(ResourceSaver.save(registry, PROBE_REGISTRY), OK, "the registry saves")
	var text := FileAccess.get_file_as_string(PROBE_REGISTRY)
	check(not text.contains('type="PackedScene"'), "the file holds no PackedScene reference: %s" % text)
	check(text.contains("scene_ref"), "it holds the scene_ref")
	var loaded := ResourceLoader.load(PROBE_REGISTRY, "", ResourceLoader.CACHE_MODE_IGNORE) as GameplayCueRegistry
	check(loaded != null and loaded.entries.size() == 1, "it loads back")
	eq(loaded.entries[0].scene_path(), PROBE_SCENE, "with its scene path")
	check(loaded.entries[0].scene != null, "and `scene` loads the scene on demand")
	check(loaded.get_scene_for_tag(&"Cue.Test.Probe") != null, "get_scene_for_tag still works")
	var empty := GameplayCueEntry.new()
	eq(empty.scene_path(), "", "an entry with no scene has no path")
	check(empty.scene == null, "and no scene")


## A registry saved before the patch (the scene stored as an ext_resource) still loads, and its entries read as refs.
func test_an_older_registry_that_stored_scenes_still_loads() -> void:
	_probe_scene()
	var legacy := PackedStringArray([
		'[gd_resource type="Resource" script_class="GameplayCueRegistry" format=3]',
		'',
		'[ext_resource type="Script" path="res://addons/GodotGAS/cues/gameplay_cue_entry.gd" id="1"]',
		'[ext_resource type="Script" path="res://addons/GodotGAS/cues/gameplay_cue_registry.gd" id="2"]',
		'[ext_resource type="PackedScene" path="%s" id="3"]' % PROBE_SCENE,
		'',
		'[sub_resource type="Resource" id="Resource_a"]',
		'script = ExtResource("1")',
		'tag = &"Cue.Test.Legacy"',
		'scene = ExtResource("3")',
		'',
		'[resource]',
		'script = ExtResource("2")',
		'entries = Array[ExtResource("1")]([SubResource("Resource_a")])',
		''])
	var file := FileAccess.open("user://gas_patch_legacy_registry.tres", FileAccess.WRITE)
	file.store_string("\n".join(legacy))
	file.close()
	var loaded := ResourceLoader.load("user://gas_patch_legacy_registry.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as GameplayCueRegistry
	check(loaded != null and loaded.entries.size() == 1, "the older registry loads")
	eq(loaded.entries[0].scene_path(), PROBE_SCENE, "its scene is now a reference")


## Patch 4: the manager loads a cue's scene on first use, and suppress_cues turns every cue off (no node, no load).
func test_cue_manager_loads_lazily_and_can_suppress() -> void:
	var scene := _probe_scene()
	var entry := GameplayCueEntry.new()
	entry.tag = &"Cue.Test.Lazy"
	entry.scene = scene
	var manager := GameplayCueManager
	var was_suppressed: bool = manager.suppress_cues
	manager._entries[entry.tag] = entry
	manager._pool[entry.tag] = []
	var target := Node.new()
	host.add_child(target)
	check(manager.has_cue(entry.tag), "the entry's cue is known")
	check(not manager._cue_scenes.has(entry.tag), "but its scene is not loaded yet")
	manager.suppress_cues = true
	manager.execute_cue(entry.tag, target)
	eq(target.get_child_count(), 0, "a suppressed cue spawns nothing")
	check(manager.add_persistent_cue(entry.tag, target) == null, "a suppressed persistent cue returns null")
	check(not manager._cue_scenes.has(entry.tag), "and loaded nothing")
	manager.suppress_cues = false
	var persistent := manager.add_persistent_cue(entry.tag, target)
	check(persistent == null, "the probe is not a GameplayCueNotify, so GodotGAS refuses it (as before)")
	check(manager._cue_scenes.has(entry.tag), "the first real use loaded the scene")
	manager.unregister_cue(entry.tag)
	manager.suppress_cues = was_suppressed
	target.free()


## The project keeps cues off in headless processes (the verifier): FxManager's _ready sets it.
func test_headless_suppresses_cues_by_default() -> void:
	check(GameplayCueManager.suppress_cues == (DisplayServer.get_name() == "headless"), "suppress_cues follows the display server")
