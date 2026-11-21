## HUD panel (UI.Slot.Hud.Right on the map): the minimap (spec ff7-ui 2.11, F16, F17). Visited rooms and the rooms
## touching them (MapCells), white room-type icons, your room a gold tile. View only: a click opens the big map, where
## travel happens. While Tab (show_floor_info) is held the map grows in place with the chapter and floor in its title.
extends UIScreen

@export var big_map: PackedScene = preload("res://presentation/demo/ui/big_map.tscn")
@export var cell_size: float = 22.0
@export var held_cell_size: float = 44.0
@export var title_text: String = "MAP"
@export var held_title_format: String = "MAP · %s · FLOOR %d"
@export var hold_action: StringName = &"show_floor_info"

var _held: bool = false
## The key's last state, so a press from the console (set_held) isn't undone the next frame.
var _key_held: bool = false


func bind(context: UIContext) -> void:
	for signal_name in [&"floor_entered", &"room_entered", &"room_cleared", &"battle_finished", &"party_changed",
			&"map_revealed"]:
		context.on_run(self, signal_name, func(_a = null): refresh())
	UIFlash.listen(self, func(data: Dictionary) -> Array:  # spec ui-feedback: the room's tile on the minimap
		if data.get(UIRefusal.TARGET) in [UIRefusal.ROOM, UIRefusal.LOCK] and data.has("cell"):
			var tile := UIFlash.entry(%Cells, int(data["cell"]))
			return [tile] if tile != null else []
		return [])


func _process(_delta: float) -> void:
	var held := _key_state()
	if held != _key_held:
		_key_held = held
		set_held(held)


## Playtest-fixes B28: Tab toggles (UIToggles: one press grows the map, the next shrinks it); an action that is not a toggle
## still grows it while held.
func _key_state() -> bool:
	if UIToggles.is_toggle(hold_action):
		return UIToggles.is_on(hold_action)
	return InputMap.has_action(hold_action) and Input.is_action_pressed(hold_action)


## Grows (or shrinks back) the map: Tab, or the console and tests.
func set_held(held: bool) -> void:
	_held = held
	if UIToggles.is_toggle(hold_action):
		UIToggles.set_on(hold_action, held)
		_key_held = held
	refresh()


func refresh() -> void:
	var run := ctx.run if ctx != null else null
	if run == null or run.state == null or run.state.map == null:
		return
	var chapter := run.chapter()
	%Title.text = held_title_format % [chapter.display_name.to_upper() if chapter != null else "",
		run.state.floor_index + 1] if _held else title_text
	%Cells.columns = run.state.map.size.x
	var side := held_cell_size if _held else cell_size
	%Cells.set_items(MapCells.of(run).map(func(cell: Dictionary) -> Dictionary:
		return DemoMapIcons.item(cell, side, false, _open_big_map)))


func _open_big_map() -> void:
	if ctx != null and ctx.ui != null and big_map != null:
		ctx.ui.push(&"UI.Layer.GameMenu", big_map)
