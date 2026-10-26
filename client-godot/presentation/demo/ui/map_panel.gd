## HUD panel (UI.Slot.Hud.Right while UI.State.Run): the floor's title and coins, and the map with Isaac visibility
## (visited rooms and their neighbours); click a room to move. Cells are action_button entries of %Cells.
extends UIScreen

@export var title_format: String = "Floor %d - %s   Coins: %d"
## The mark of each room kind; "cleared" and "unvisited" are for normal rooms.
@export var marks: Dictionary = {"start": "S", "boss": "B", "shop": "$", "special": "*", "unvisited": "?",
	"cleared": ".", "open": "!"}


func bind(context: UIContext) -> void:
	for signal_name in [&"floor_entered", &"room_entered", &"room_cleared", &"battle_finished", &"party_changed",
			&"map_revealed"]:
		context.on_run(self, signal_name, func(_a = null): refresh())


func refresh() -> void:
	var run := ctx.run
	if run == null or run.state == null or run.state.map == null:
		return
	var map := run.state.map
	var chapter := run.chapter()
	%Title.text = title_format % [run.state.floor_index + 1, chapter.display_name if chapter != null else "",
		run.state.coins]
	%Cells.columns = map.size.x
	var items: Array = []
	for index in map.size.x * map.size.y:
		var data: Dictionary = map.cells.get(index, {})
		var known: bool = not data.is_empty() and (run.state.revealed or data["visited"]
			or map.neighbours(index).any(func(n): return map.cells[n]["visited"]))
		if not known:
			items.append({"hidden": true})
			continue
		items.append({
			"text": _mark(data),
			"disabled": not run.can_enter(index),
			"variation": "MapCellCurrent" if index == run.state.current_cell else "MapCellCleared" if data["cleared"] else "",
			"action": func(): run.enter_room(index),
		})
	%Cells.set_items(items)


func _mark(data: Dictionary) -> String:
	match data["role"]:
		FloorMap.ROLE_START:
			return marks["start"]
		FloorMap.ROLE_BOSS:
			return marks["boss"]
		FloorMap.ROLE_SPECIAL:
			return marks["shop"] if String(data["special_tag"]).ends_with("Shop") else marks["special"]
	if not data["visited"]:
		return marks["unvisited"]
	return marks["cleared"] if data["cleared"] else marks["open"]
