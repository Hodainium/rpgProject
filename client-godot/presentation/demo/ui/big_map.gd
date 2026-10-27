## Spec ff7-ui 2.11 (F16, Enter the Gungeon's map): the whole floor on a menu screen. Drag or the mouse wheel moves it,
## RECENTER (and opening it) centres your room. Hover a room for its description; click one you can reach to travel
## there (RunController.enter_room: any visited room or a room touching one); the map closes and the room plays as
## usual. A drag never counts as a click. HELP opens the legend (map_legend.tscn, Modal layer).
extends DemoMenuFrame

@export var legend: PackedScene = preload("res://presentation/demo/ui/map_legend.tscn")
@export var cell_size: float = 96.0
@export var wheel_step: float = 48.0
@export var drag_threshold: float = 6.0
@export var here_text: String = "You are here"
@export var travel_text: String = "Click to travel here"
@export var here_help: String = "Drag or scroll to look around; hover a room for what it is."
@export var visited_text: String = "A room you have been in."
@export var unexplored_text: String = "Next to a room you have been in."

var _pan := Vector2.ZERO
var _drag_from: Variant = null
var _pan_from := Vector2.ZERO
var _dragged: bool = false


func bind(context: UIContext) -> void:
	%Recenter.pressed.connect(recenter)
	%Help.pressed.connect(func(): ctx.ui.push(&"UI.Layer.Modal", legend))
	for signal_name in [&"room_entered", &"room_cleared", &"map_revealed"]:
		context.on_run(self, signal_name, func(_a = null): refresh())


func on_activated() -> void:
	refresh()
	recenter.call_deferred()


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null or run.state.map == null:
		return
	%Grid.columns = run.state.map.size.x
	var cells := MapCells.of(run)
	%Grid.set_items(cells.map(func(cell: Dictionary) -> Dictionary:
		var travel := Callable() if not cell["shown"] or cell["here"] else _travel.bind(cell["index"])
		return DemoMapIcons.item(cell, cell_size, true, travel, _describe_cell.bind(cell))))
	%Grid.reset_size()
	for cell in cells:
		if cell["here"]:
			_describe_cell(cell)


## Centres your room in the view.
func recenter() -> void:
	await get_tree().process_frame
	var here := -1
	if ctx.run != null and ctx.run.state != null:
		here = ctx.run.state.current_cell
	var children := %Grid.get_children()
	if here < 0 or here >= children.size():
		return
	var tile: Control = children[here]
	_pan = %Viewport.size / 2.0 - tile.position - tile.size / 2.0
	%Grid.position = _pan


func _describe_cell(cell: Dictionary) -> void:
	var kind: String = cell["kind"]
	var info := {"name": DemoMapIcons.LONG_NAMES.get(kind, "Room"), "kind": "VISITED" if cell["visited"] else "UNEXPLORED"}
	if cell["here"]:
		info["name"] = "%s · %s" % [here_text, info["name"]]
		info["text"] = here_help
	else:
		info["text"] = visited_text if cell["visited"] else unexplored_text
		info["extra"] = travel_text if cell["enterable"] else ""
	describe(info)


func _travel(index: int) -> void:
	if _dragged or ctx.run == null:
		return
	if not ctx.run.can_enter(index):
		ctx.main.refuse("can't enter that room now")
		return
	var run := ctx.run
	ctx.ui.remove(self)  # close first: the room may start a battle or an event
	var problem := run.enter_room(index)
	if problem != "":
		ctx.main.refuse(problem)


func _input(event: InputEvent) -> void:
	if not active or not is_visible_in_tree():
		return
	var view: Control = %Viewport
	if event is InputEventMouseButton:
		var inside := view.get_global_rect().has_point(event.position)
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and inside:
				_drag_from = event.position
				_pan_from = _pan
				_dragged = false
			elif not event.pressed:
				_drag_from = null
		elif inside and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
				MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			var step := wheel_step if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else -wheel_step
			var horizontal: bool = event.shift_pressed or event.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]
			_pan += Vector2(step, 0) if horizontal else Vector2(0, step)
			%Grid.position = _pan
	elif event is InputEventMouseMotion and _drag_from != null:
		var delta: Vector2 = event.position - _drag_from
		if delta.length() > drag_threshold:
			_dragged = true
		if _dragged:
			_pan = _pan_from + delta
			%Grid.position = _pan
