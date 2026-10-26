## Demo map (placeholder): Isaac visibility (visited rooms and their neighbours), role marks, click to move.
## Spec playable-demo 3.6/3.8: a floor title card on each new floor; at a choice of stairs, one button per route.
extends Control

const CELL: Vector2 = Vector2(40, 32)
const CARD_SECONDS: float = 2.0

var _main: GameMain
## Counts title cards, so an older card's timer never hides a newer one.
var _card_serial: int = 0

@onready var _grid: GridContainer = %Grid
@onready var _title: Label = %Title
@onready var _next_floor: Button = %NextFloor
@onready var _routes: VBoxContainer = %Routes
@onready var _card: Label = %FloorCard


func setup(main: GameMain) -> void:
	_main = main
	_next_floor.pressed.connect(func(): _main.run.next_floor())
	main.mode_changed.connect(_on_mode)
	main.run_changed.connect(_bind)
	visible = false


## "Floor 9 · The Silent Cathedral" over the map for two seconds (real time: the battle speed never shortens it).
func _show_card(floor_index: int) -> void:
	var chapter := _main.run.chapter()
	_card.text = "Floor %d  ·  %s" % [floor_index + 1, chapter.display_name if chapter != null else ""]
	_card.visible = true
	_card_serial += 1
	var serial := _card_serial
	await get_tree().create_timer(CARD_SECONDS, true, false, true).timeout
	if serial == _card_serial:
		_card.visible = false


func _on_mode(mode: String) -> void:
	visible = mode == "run"
	_refresh()


func _bind(run: RunController) -> void:
	for changed in [run.floor_entered, run.room_entered, run.room_cleared, run.battle_finished, run.party_changed,
			run.map_revealed, run.event_page_shown]:
		changed.connect(func(_a = null, _b = null): _refresh())
	run.floor_entered.connect(_show_card)


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
	# The stairs: closed while the rest stop between floors is open; a choice of routes shows one button per chapter.
	if not run.state.event.is_empty():
		_card.visible = false  # an event panel (the rest stop too) takes the screen
	var stairs: bool = run.state.boss_cleared and not run.is_last_floor() and run.state.event.is_empty() \
		and run.state.status == RunState.ACTIVE
	var choices: Array = run.next_floor_choices() if stairs else []
	_next_floor.visible = stairs and choices.is_empty()
	for child in _routes.get_children():
		child.queue_free()
	_routes.visible = not choices.is_empty()
	for route in choices:
		var button := Button.new()
		button.text = "%s stairs: %s" % [_route_name(route), route.display_name]
		button.pressed.connect(func(): _main.run.next_floor(route.id))
		_routes.add_child(button)
	# One grid slot per map cell; unknown cells are empty spacers so the layout keeps the floor's shape.
	_grid.columns = map.size.x
	for index in map.size.x * map.size.y:
		var data: Dictionary = map.cells.get(index, {})
		var known: bool = not data.is_empty() and (run.state.revealed or data["visited"]
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


## "Light" for Route.Light, "Dark" for Route.Dark; "Take the" without a route tag.
static func _route_name(chapter: ChapterDefinition) -> String:
	return String(chapter.route_tag).get_slice(".", 1) if chapter.route_tag != &"" else "Take the"


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
