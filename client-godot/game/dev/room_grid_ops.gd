## Room grid operations (spec dev-tools 3.8), shared by the inspector's room grid, the console's `grid` and the tests.
## The *_result() functions return the new value without touching the room, so the editor can wrap them in undo/redo;
## paint() / erase() / toggle_door() apply them. One placement per cell: painting replaces.
class_name RoomGridOps
extends RefCounted

## Palette names → placement kinds.
const KINDS: Dictionary = {"player": RoomPlacement.Kind.PLAYER_SPAWN, "enemy": RoomPlacement.Kind.ENEMY_SPAWN,
	"prop": RoomPlacement.Kind.EVENT_PROP, "pedestal": RoomPlacement.Kind.ITEM_PEDESTAL, "shop": RoomPlacement.Kind.SHOP_SLOT}
## Door side names → bits.
const SIDES: Dictionary = {"n": RoomDefinition.DOOR_N, "e": RoomDefinition.DOOR_E, "s": RoomDefinition.DOOR_S,
	"w": RoomDefinition.DOOR_W}
## Two characters per kind in text().
const SYMBOLS: Dictionary = {RoomPlacement.Kind.PLAYER_SPAWN: "P", RoomPlacement.Kind.ENEMY_SPAWN: "E",
	RoomPlacement.Kind.EVENT_PROP: "?", RoomPlacement.Kind.ITEM_PEDESTAL: "I", RoomPlacement.Kind.SHOP_SLOT: "$"}


static func inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < RoomDefinition.GRID.x and cell.y < RoomDefinition.GRID.y


## Index of the placement on `cell`, or -1.
static func placement_at(room: RoomDefinition, cell: Vector2i) -> int:
	for index in room.placements.size():
		if room.placements[index] != null and room.placements[index].cell == cell:
			return index
	return -1


## The placements after painting `kind` (with `slot`) on `cell`. The same kind keeps its other fields (item, loadout,
## price) and only changes slot; another kind replaces the placement. Outside the grid → unchanged.
static func paint_result(room: RoomDefinition, cell: Vector2i, kind: RoomPlacement.Kind, slot: int) -> Array[RoomPlacement]:
	var placements: Array[RoomPlacement] = room.placements.duplicate()
	if not inside(cell):
		return placements
	var index := placement_at(room, cell)
	var placement: RoomPlacement
	if index >= 0 and placements[index].kind == kind:
		placement = placements[index].duplicate()
	else:
		placement = RoomPlacement.new()
		placement.cell = cell
		placement.kind = kind
	placement.slot = maxi(slot, 1)
	if index >= 0:
		placements[index] = placement
	else:
		placements.append(placement)
	return placements


static func erase_result(room: RoomDefinition, cell: Vector2i) -> Array[RoomPlacement]:
	var placements: Array[RoomPlacement] = room.placements.duplicate()
	var index := placement_at(room, cell)
	if index >= 0:
		placements.remove_at(index)
	return placements


static func toggle_door_result(room: RoomDefinition, side: int) -> int:
	return room.doors ^ side


static func paint(room: RoomDefinition, cell: Vector2i, kind: RoomPlacement.Kind, slot: int) -> void:
	room.placements = paint_result(room, cell, kind, slot)


static func erase(room: RoomDefinition, cell: Vector2i) -> void:
	room.placements = erase_result(room, cell)


static func toggle_door(room: RoomDefinition, side: int) -> void:
	room.doors = toggle_door_result(room, side)


## Short label for a cell ("P1", "E2", "I", "$", "?"), "" when empty.
static func label(placement: RoomPlacement) -> String:
	if placement == null:
		return ""
	var symbol: String = SYMBOLS.get(placement.kind, "#")
	if placement.kind in [RoomPlacement.Kind.PLAYER_SPAWN, RoomPlacement.Kind.ENEMY_SPAWN]:
		return symbol + str(placement.slot)
	return symbol


## The room as text, for the console's `grid show`: two characters per cell, doors as gaps in the wall.
@warning_ignore("integer_division")
static func text(room: RoomDefinition) -> String:
	var width := RoomDefinition.GRID.x
	var lines := PackedStringArray()
	var middle := width / 2
	var wall := func(has_door: bool) -> String:
		var row := "+"
		for x in width:
			row += "  " if has_door and x == middle else "--"
		return row + "+"
	lines.append(wall.call(room.doors & RoomDefinition.DOOR_N != 0))
	for y in RoomDefinition.GRID.y:
		var door_row := y == RoomDefinition.GRID.y / 2
		var row := " " if door_row and room.doors & RoomDefinition.DOOR_W != 0 else "|"
		for x in width:
			var index := placement_at(room, Vector2i(x, y))
			row += (label(room.placements[index]) + " ").substr(0, 2) if index >= 0 else ". "
		row += " " if door_row and room.doors & RoomDefinition.DOOR_E != 0 else "|"
		lines.append(row)
	lines.append(wall.call(room.doors & RoomDefinition.DOOR_S != 0))
	return "\n".join(lines)
