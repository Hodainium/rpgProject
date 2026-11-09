## Global Autoload for managing and spawning visual/audio cues.
##
## Utilizes an object pooling system to efficiently reuse GameplayCueNotify 
## nodes, preventing performance hitches during rapid cue instantiation.
##
## @meta_addon: GodotGAS
## @meta_author: YulRun (https://YulRun.Dev)
## @meta_license: MIT

@icon("res://addons/GodotGAS/icons/godot_gas_asc.svg")
extends Node

## Addon project settings.
const GodotGasProjectSettings: = preload("res://addons/GodotGAS/utilities/project_settings.gd")

## Internal dictionary holding the object pool. Format: { "tag": [GameplayCueNotify, ...] }
var _pool: Dictionary = {}

## Internal dictionary holding the cached PackedScenes. Format: { "tag": PackedScene }
## rpgProject patch (client-godot/CLAUDE.md section 0): filled on a cue's first use, not when the registry loads.
var _cue_scenes: Dictionary = {}

## rpgProject patch: the registry's entries by tag. An entry only names its scene; the scene loads when the cue first runs.
var _entries: Dictionary = {}

## rpgProject patch (Unreal's ShouldSuppressGameplayCues): when true, execute_cue does nothing and add_persistent_cue
## returns null. A process that draws and plays nothing (the headless verifier) sets it, so no cue scene is ever loaded
## and no cue node is made per hit.
var suppress_cues: bool = false


#region Initialization
## Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_load_registry()


## Loads the cue registry from disk and prepares the object pool.
func _load_registry() -> void:
	var cue_registry_path: = GodotGasProjectSettings.get_registry_cue_path()
	if not ResourceLoader.exists(cue_registry_path):
		# rpgProject patch (client-godot/CLAUDE.md section 0): EditorInterface through Engine.get_singleton. A bare
		# editor class name fails to parse in export templates, so this autoload would not load in any export.
		if not Engine.is_editor_hint() or Engine.get_singleton(&"EditorInterface").is_plugin_enabled("GodotGAS"):
			push_warning("GodotGAS: No cue registry found at " + cue_registry_path)
		return
		
	var registry = load(cue_registry_path) as GameplayCueRegistry
	if not registry:
		return
		
	# Register everything found in the resource. rpgProject patch: an entry only names its scene (scene_path); the scene
	# is loaded by _scene_for the first time the cue runs.
	for entry in registry.entries:
		if entry.tag and entry.scene_path() != "":
			_entries[entry.tag] = entry
			_pool[entry.tag] = []


## rpgProject patch: true when `tag` has a cue scene (registered by the registry or by register_cue).
func has_cue(tag: StringName) -> bool:
	return _cue_scenes.has(tag) or _entries.has(tag)


## rpgProject patch: adds (or replaces) a cue at run time, like Unreal's runtime cue registration. Tests and mods use it.
func register_cue(tag: StringName, scene: PackedScene) -> void:
	unregister_cue(tag)  # frees the pooled nodes of the cue being replaced
	_cue_scenes[tag] = scene
	_pool[tag] = []


## rpgProject patch: removes a cue; pooled instances are freed.
func unregister_cue(tag: StringName) -> void:
	_cue_scenes.erase(tag)
	_entries.erase(tag)
	for pooled in _pool.get(tag, []):
		if is_instance_valid(pooled):
			pooled.free()
	_pool.erase(tag)


## rpgProject patch: starts loading a cue's scene in the background (Unreal's async load), so its first use does not
## wait. Call it for the cues a floor will need. Does nothing for a cue that is loaded or unknown.
func preload_cue(tag: StringName) -> void:
	if _cue_scenes.has(tag) or not _entries.has(tag):
		return
	var path: String = _entries[tag].scene_path()
	if path != "" and not ResourceLoader.has_cached(path):
		ResourceLoader.load_threaded_request(path)


## rpgProject patch: the cue's scene, loaded the first time it is asked for (null when unknown or it fails to load).
func _scene_for(tag: StringName) -> PackedScene:
	if _cue_scenes.has(tag):
		return _cue_scenes[tag]
	if not _entries.has(tag):
		return null
	var path: String = _entries[tag].scene_path()
	var scene: PackedScene = null
	if path != "" and ResourceLoader.exists(path):  # a missing file is one warning below, not engine load errors
		if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			scene = ResourceLoader.load_threaded_get(path) as PackedScene
		if scene == null:
			scene = load(path) as PackedScene
	if scene == null:
		push_warning("GodotGAS: cue '%s' could not load its scene %s" % [tag, path])
		_entries.erase(tag)  # remembered: the warning and the file read happen once, not on every hit
		return null
	_cue_scenes[tag] = scene
	return scene
#endregion


#region Cue Execution
## The main public API called by the ASC to spawn a one-off burst effect.
func execute_cue(tag: StringName, target: Node, payload: Dictionary = {}) -> void:
	if suppress_cues or not has_cue(tag):  # rpgProject patch: suppression, lazy scenes
		return
		
	var cue_instance: GameplayCueNotify = _get_or_create_cue(tag)
	if not cue_instance:
		return
	
	if cue_instance.get_parent():
		cue_instance.get_parent().remove_child(cue_instance)
		
	target.add_child(cue_instance)
	cue_instance.execute_cue(target, payload)


## Adds a persistent cue that will not automatically destroy itself.
## Returns the live node so the ASC can track and suppress it later.
func add_persistent_cue(tag: StringName, target: Node, payload: Dictionary = {}) -> GameplayCueNotify:
	if suppress_cues or not has_cue(tag):  # rpgProject patch: suppression, lazy scenes
		return null
		
	var cue_instance: GameplayCueNotify = _get_or_create_cue(tag)
	if not cue_instance:
		return null
	
	# Override auto-destroy for persistent lifecycle mapping
	cue_instance.auto_destroy = false
	
	if cue_instance.get_parent():
		cue_instance.get_parent().remove_child(cue_instance)
		
	target.add_child(cue_instance)
	cue_instance.execute_cue(target, payload)
	
	return cue_instance


## Manually concludes a persistent cue and triggers its fade-out phase.
func remove_persistent_cue(cue_node: GameplayCueNotify) -> void:
	if is_instance_valid(cue_node):
		cue_node.end_cue()
#endregion


#region Object Pooling
## Internal pooling logic to retrieve an inactive cue or instantiate a new one.
func _get_or_create_cue(tag: StringName) -> GameplayCueNotify:
	# 1. Try to grab an existing dormant cue from the pool
	if _pool.has(tag) and _pool[tag].size() > 0:
		var pooled_cue = _pool[tag].pop_back()
		set_cue_state(pooled_cue, true) # WAKE THE CUE UP!
		return pooled_cue
		
	# 2. If the pool is empty, instance a brand new one
	var scene := _scene_for(tag)  # rpgProject patch: loaded on first use
	if scene == null:
		return null
	var raw_instance = scene.instantiate()
	
	# TYPE CHECK: Is this scene actually a GameplayCueNotify?
	if not raw_instance is GameplayCueNotify:
		push_error("GodotGAS: Failed to load cue '%s'. The root node of this scene must extend 'GameplayCueNotify'." % tag)
		raw_instance.free() # Clean up the invalid node
		return null
	
	var new_cue: GameplayCueNotify = raw_instance
	new_cue.gameplay_cue_tag = tag
	new_cue.cue_finished.connect(_on_cue_finished)
	
	set_cue_state(new_cue, true) # Initialize as Active
	return new_cue


## Called automatically when a cue calls finish_cue().
func _on_cue_finished(cue_node: GameplayCueNotify, tag: StringName) -> void:
	if cue_node.get_parent():
		cue_node.get_parent().remove_child(cue_node)
	
	set_cue_state(cue_node, false) # Put to sleep
	add_child(cue_node)
	
	if not _pool.has(tag):
		_pool[tag] = []
		
	_pool[tag].append(cue_node)


## Centralized lifecycle state manager.
## Handles enabling/disabling logic and visual toggling for any node structure.
func set_cue_state(cue: GameplayCueNotify, active: bool) -> void:
	# 1. Toggle Logic
	cue.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	
	# 2. Toggle Visuals
	# We loop immediate children. If they are visual nodes, they are toggled.
	# Because visibility propagates, hiding children effectively hides the whole subtree.
	for child in cue.get_children():
		if "visible" in child:
			child.visible = active
#endregion
