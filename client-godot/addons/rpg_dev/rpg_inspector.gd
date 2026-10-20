## Adds, above the normal inspector fields: the room grid (rooms) and a Play button (rooms, encounters, enemies,
## characters, layouts). Spec dev-tools 2.4.
@tool
extends EditorInspectorPlugin

const RoomGrid := preload("res://addons/rpg_dev/room_grid.gd")
const Plugin := preload("res://addons/rpg_dev/plugin.gd")

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return _kind_of(object) != ""


func _parse_begin(object: Object) -> void:
	var kind := _kind_of(object)
	var box := VBoxContainer.new()
	var play := Button.new()
	play.text = "Play this %s" % kind
	play.tooltip_text = "Saves it, then starts the game straight into it (party, seed and depth from the RPG Content dock)."
	play.pressed.connect(func() -> void: Plugin.play(kind, object))
	box.add_child(play)
	if object is RoomDefinition:
		var grid := RoomGrid.new()
		grid.setup(object, undo_redo)
		box.add_child(grid)
	add_custom_control(box)


static func _kind_of(object: Object) -> String:
	if object is RoomDefinition:
		return "room"
	if object is EncounterDefinition:
		return "encounter"
	if object is CharacterDefinition:
		return "character"
	if object is UnitDefinition:
		return "enemy"
	if object is FloorLayout:
		return "layout"
	return ""
