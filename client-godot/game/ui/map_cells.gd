## Spec ff7-ui 2.11: what each cell of the floor shows, shared by the minimap, the Tab view and the big map (one rule,
## three sizes). Read-only. Shown rooms are the visited ones and the rooms touching them (all of them once the map is
## revealed); a room's type (its icon) shows only when RunController.room_type_known says so.
class_name MapCells
extends RefCounted


## One Dictionary per grid cell in index order: {"index", "shown", "here", "visited", "kind", "enterable"}. "kind" is
## the room type the map may show: "boss", "event", the special room's tag end ("Treasure", "Shop", "Altar"), or ""
## (a plain room, the start room, or a type not known yet).
static func of(run: RunController) -> Array[Dictionary]:
	var cells: Array[Dictionary] = []
	if run == null or run.state == null or run.state.map == null:
		return cells
	var map: FloorMap = run.state.map
	for index in map.size.x * map.size.y:
		var data: Dictionary = map.cells.get(index, {})
		var shown: bool = not data.is_empty() and (run.state.revealed or data["visited"]
			or map.neighbours(index).any(func(n: int) -> bool: return map.cells[n]["visited"]))
		var cell := {"index": index, "shown": shown, "here": index == run.state.current_cell,
			"visited": shown and data["visited"], "kind": "", "enterable": shown and run.can_enter(index)}
		if shown and run.room_type_known(index):
			cell["kind"] = _kind(data)
		cells.append(cell)
	return cells


static func _kind(data: Dictionary) -> String:
	match data["role"]:
		FloorMap.ROLE_BOSS:
			return "boss"
		FloorMap.ROLE_SPECIAL:
			var tag := String(data["special_tag"])
			return tag.get_slice(".", tag.get_slice_count(".") - 1)
	if str(data["content"].get("kind", "")) == "event":
		return "event"
	return ""
