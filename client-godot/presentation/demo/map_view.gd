## Demo map (placeholder): Isaac visibility (visited rooms and their neighbours), role marks, click to move.
extends Control

const CELL: Vector2 = Vector2(34, 26)

var _main: GameMain
var _grid: Control
var _title: Label
var _next_floor: Button


func setup(main: GameMain) -> void:
	_main = main
	set_anchors_and_offsets_preset(PRESET_TOP_RIGHT)
	position = Vector2(-330, 8)
	custom_minimum_size = Vector2(320, 260)
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	box.add_child(_title)
	_grid = Control.new()
	_grid.custom_minimum_size = Vector2(320, 210)
	box.add_child(_grid)
	_next_floor = Button.new()
	_next_floor.text = "Next floor"
	_next_floor.pressed.connect(func(): _main.run.next_floor())
	box.add_child(_next_floor)
	main.mode_changed.connect(_on_mode)
	main.run_changed.connect(_bind)
	visible = false


func _on_mode(mode: String) -> void:
	visible = mode == "run"
	_refresh()


func _bind(run: RunController) -> void:
	for changed in [run.floor_entered, run.room_entered, run.room_cleared, run.battle_finished, run.party_changed]:
		changed.connect(func(_a = null): _refresh())


func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()
	var run := _main.run
	if run == null or run.state == null or run.state.map == null:
		return
	var map := run.state.map
	var chapter := run.chapter()
	_title.text = "Floor %d - %s   Coins: %d" % [run.state.floor_index + 1,
		chapter.display_name if chapter != null else "", run.state.coins]
	_next_floor.visible = run.state.boss_cleared and not run.is_last_floor()
	for index in map.sorted_indices():
		var data: Dictionary = map.cells[index]
		var known: bool = data["visited"] or map.neighbours(index).any(func(n): return map.cells[n]["visited"])
		if not known:
			continue
		var button := Button.new()
		button.position = Vector2(map.cell_of(index)) * CELL
		button.size = CELL - Vector2(4, 4)
		button.text = _mark(data)
		button.disabled = not run.can_enter(index)
		if index == run.state.current_cell:
			button.modulate = Color.GOLD
		elif data["cleared"]:
			button.modulate = Color(0.7, 0.9, 0.7)
		button.pressed.connect(func(): run.enter_room(index))
		_grid.add_child(button)


func _mark(data: Dictionary) -> String:
	match data["role"]:
		FloorMap.ROLE_START:
			return "S"
		FloorMap.ROLE_BOSS:
			return "B"
		FloorMap.ROLE_SPECIAL:
			return "$" if String(data["special_tag"]).ends_with("Shop") else "*"
	if not data["visited"]:
		return "?"
	return "." if data["cleared"] else "!"
