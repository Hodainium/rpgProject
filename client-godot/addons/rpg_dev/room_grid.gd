## The room grid in the inspector (spec dev-tools 2.4): a palette, a 13 × 7 grid of cells and the four doors. Every
## click is one RoomGridOps result wrapped in EditorUndoRedoManager, so Ctrl+Z works and Ctrl+S saves as usual.
@tool
extends VBoxContainer

const TOOLS: Array = [["Player", "player"], ["Enemy", "enemy"], ["Prop", "prop"], ["Pedestal", "pedestal"],
	["Shop", "shop"], ["Erase", "erase"], ["Select", "select"]]
const COLORS: Dictionary = {RoomPlacement.Kind.PLAYER_SPAWN: Color(0.35, 0.6, 1.0),
	RoomPlacement.Kind.ENEMY_SPAWN: Color(1.0, 0.4, 0.35), RoomPlacement.Kind.EVENT_PROP: Color(0.4, 0.9, 0.9),
	RoomPlacement.Kind.ITEM_PEDESTAL: Color(1.0, 0.85, 0.3), RoomPlacement.Kind.SHOP_SLOT: Color(0.5, 0.9, 0.4)}

var _room: RoomDefinition
var _undo: EditorUndoRedoManager
var _tool: String = "player"
var _slot: SpinBox
var _cells: Array[Button] = []
var _doors: Dictionary = {}
var _issues: Label


func setup(room: RoomDefinition, undo_redo: EditorUndoRedoManager) -> void:
	_room = room
	_undo = undo_redo
	_build()
	_refresh()
	_room.changed.connect(_refresh)


func _build() -> void:
	var palette := HFlowContainer.new()
	var group := ButtonGroup.new()
	for entry in TOOLS:
		var button := Button.new()
		button.text = entry[0]
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = entry[1] == _tool
		button.pressed.connect(func() -> void: _tool = entry[1])
		palette.add_child(button)
	var slot_label := Label.new()
	slot_label.text = "Slot"
	palette.add_child(slot_label)
	_slot = SpinBox.new()
	_slot.min_value = 1
	_slot.max_value = 8
	_slot.tooltip_text = "Party slot (player spawn) or encounter slot (enemy spawn)."
	palette.add_child(_slot)
	add_child(palette)

	var north := _door_button("n", "North door")
	north.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(north)
	var middle := HBoxContainer.new()
	middle.add_child(_door_button("w", "West door"))
	var grid := GridContainer.new()
	grid.columns = RoomDefinition.GRID.x
	grid.add_theme_constant_override("h_separation", 1)
	grid.add_theme_constant_override("v_separation", 1)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for y in RoomDefinition.GRID.y:
		for x in RoomDefinition.GRID.x:
			var cell := Button.new()
			cell.custom_minimum_size = Vector2(22, 22)
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cell.add_theme_font_size_override("font_size", 10)
			cell.tooltip_text = "(%d, %d)" % [x, y]
			cell.pressed.connect(_on_cell.bind(Vector2i(x, y)))
			grid.add_child(cell)
			_cells.append(cell)
	middle.add_child(grid)
	middle.add_child(_door_button("e", "East door"))
	add_child(middle)
	var south := _door_button("s", "South door")
	south.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(south)

	_issues = Label.new()
	_issues.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_issues.add_theme_font_size_override("font_size", 11)
	add_child(_issues)


func _door_button(side: String, tip: String) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.tooltip_text = tip + " (the generator only uses this room where every neighbour has a door here)"
	button.custom_minimum_size = Vector2(22, 22)
	button.pressed.connect(_on_door.bind(side))
	_doors[side] = button
	return button


func _on_cell(cell: Vector2i) -> void:
	var index := RoomGridOps.placement_at(_room, cell)
	match _tool:
		"select":
			if index >= 0:
				EditorInterface.edit_resource(_room.placements[index])
			return
		"erase":
			if index < 0:
				return
			_commit("Erase room placement", RoomGridOps.erase_result(_room, cell))
		_:
			_commit("Paint room placement", RoomGridOps.paint_result(_room, cell, RoomGridOps.KINDS[_tool], int(_slot.value)))


func _commit(action: String, placements: Array[RoomPlacement]) -> void:
	_undo.create_action(action, UndoRedo.MERGE_DISABLE, _room)
	_undo.add_do_property(_room, "placements", placements)
	_undo.add_undo_property(_room, "placements", _room.placements.duplicate())
	_undo.add_do_method(self, "_refresh")
	_undo.add_undo_method(self, "_refresh")
	_undo.commit_action()


func _on_door(side: String) -> void:
	_undo.create_action("Toggle room door", UndoRedo.MERGE_DISABLE, _room)
	_undo.add_do_property(_room, "doors", RoomGridOps.toggle_door_result(_room, RoomGridOps.SIDES[side]))
	_undo.add_undo_property(_room, "doors", _room.doors)
	_undo.add_do_method(self, "_refresh")
	_undo.add_undo_method(self, "_refresh")
	_undo.commit_action()


@warning_ignore("integer_division")
func _refresh() -> void:
	if not is_instance_valid(_room):
		return
	for index in _cells.size():
		var cell := Vector2i(index % RoomDefinition.GRID.x, index / RoomDefinition.GRID.x)
		var at := RoomGridOps.placement_at(_room, cell)
		var placement: RoomPlacement = _room.placements[at] if at >= 0 else null
		_cells[index].text = RoomGridOps.label(placement)
		_cells[index].modulate = COLORS.get(placement.kind, Color.WHITE) if placement != null else Color(1, 1, 1, 0.55)
	for side in _doors:
		var open: bool = _room.doors & RoomGridOps.SIDES[side] != 0
		_doors[side].set_pressed_no_signal(open)
		_doors[side].text = "door" if open else "wall"
	var issues := ContentValidator.check_room(_room, null)
	_issues.text = "No problems." if issues.is_empty() else "\n".join(issues.map(func(issue): return str(issue)))
