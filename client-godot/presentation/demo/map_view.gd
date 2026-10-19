## Demo map (placeholder): Isaac visibility (visited rooms and their neighbours), role marks, click to move.
extends Control

const CELL: Vector2 = Vector2(40, 32)

var _main: GameMain

@onready var _grid: GridContainer = %Grid
@onready var _title: Label = %Title
@onready var _next_floor: Button = %NextFloor


func setup(main: GameMain) -> void:
	_main = main
	_next_floor.pressed.connect(func(): _main.run.next_floor())
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
	# One grid slot per map cell; unknown cells are empty spacers so the layout keeps the floor's shape.
	_grid.columns = map.size.x
	for index in map.size.x * map.size.y:
		var data: Dictionary = map.cells.get(index, {})
		var known: bool = not data.is_empty() and (data["visited"]
			or map.neighbours(index).any(func(n): return map.cells[n]["visited"]))
		if not known:
			var spacer := Control.new()
			spacer.custom_minimum_size = CELL
			spacer.mouse_filter = MOUSE_FILTER_IGNORE
			_grid.add_child(spacer)
			continue
		var button := Button.new()
		button.custom_minimum_size = CELL
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
