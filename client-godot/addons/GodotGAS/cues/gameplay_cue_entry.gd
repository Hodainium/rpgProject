## Maps a specific gameplay tag to a visual/audio cue scene.
##
## Used by the GameplayCueRegistry to define which PackedScene should be
## instantiated or pooled when a specific cue tag is executed.
##
## @meta_addon: GodotGAS
## @meta_author: YulRun (https://YulRun.Dev)
## @meta_license: MIT

@tool
@icon("res://addons/GodotGAS/icons/godot_gas_asc.svg")
class_name GameplayCueEntry extends Resource

## The gameplay tag associated with this cue. 
## Note: The GameplayTag inspector plugin automatically detects the variable name "tag".
@export var tag: StringName

## rpgProject patch (client-godot/CLAUDE.md section 0, tested by test_godotgas_patches): the scene is stored as a UID (or a
## path) and loaded on first use, never when the registry loads. A PackedScene exported as a resource loads, with all it
## references (effects, shaders, textures, sounds), the moment its registry does; this is Unreal's soft object path.
## The saved registry holds only this string.
@export_storage var scene_ref: String = ""

## The PackedScene containing the visual or audio effects to trigger. A property over `scene_ref`: reading it loads the
## scene (the dashboard and the inspector use it), writing it records the scene's UID or path. Not stored in the file, but
## an older registry that stored it still loads (the loader calls this setter) and is saved in the new form next time.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackedScene", PROPERTY_USAGE_EDITOR) var scene: PackedScene:
	get:
		var path := scene_path()
		return load(path) as PackedScene if path != "" else null
	set(value):
		scene_ref = _ref_of(value)


## The scene's res:// path ("" when none or when its UID no longer resolves), without loading it.
func scene_path() -> String:
	if scene_ref.begins_with("uid://"):
		var id := ResourceUID.text_to_id(scene_ref)
		return ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	return scene_ref


static func _ref_of(value: PackedScene) -> String:
	if value == null or value.resource_path == "":
		return ""
	var id := ResourceLoader.get_resource_uid(value.resource_path)
	return ResourceUID.id_to_text(id) if id != ResourceUID.INVALID_ID else value.resource_path
