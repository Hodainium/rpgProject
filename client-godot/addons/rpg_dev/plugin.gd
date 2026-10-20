## The project's own editor plugin (spec dev-tools 3.8): the "RPG Content" dock, plus the room grid and Play buttons in
## the inspector. Only reads and writes content resources; never runs GAS in the editor. GodotGAS's plugin is untouched.
@tool
extends EditorPlugin

const ContentDock := preload("res://addons/rpg_dev/content_dock.gd")
const RpgInspector := preload("res://addons/rpg_dev/rpg_inspector.gd")

var _dock: Control
var _inspector: EditorInspectorPlugin


func _enter_tree() -> void:
	_dock = ContentDock.new()
	_dock.name = "RPG Content"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	_inspector = RpgInspector.new()
	_inspector.undo_redo = get_undo_redo()
	add_inspector_plugin(_inspector)


func _exit_tree() -> void:
	remove_inspector_plugin(_inspector)
	remove_control_from_docks(_dock)
	_dock.queue_free()


## Saves the asset and starts the game in play_main.tscn with it (spec dev-tools 2.4).
static func play(kind: String, resource: Resource) -> void:
	if resource.resource_path == "" or resource.resource_path.contains("::"):
		push_warning("RPG Dev Tools: save %s to its own file before playing it." % kind)
		return
	ResourceSaver.save(resource, resource.resource_path)
	PlayRequest.write(kind, resource.resource_path)
	EditorInterface.play_custom_scene("res://game/dev/play_main.tscn")
