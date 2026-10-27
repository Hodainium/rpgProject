## A generated (or hand-made) floor (spec game-skeleton 3.2). Plain data, so it hashes and serializes easily.
##
## cells: index (y * width + x) → {
##   "cell": Vector2i, "role": "start" | "normal" | "boss" | "special", "special_tag": StringName,
##   "room": StringName, "doors": int (RoomDefinition.DOOR_* bits),
##   "content": {"kind": "none" | "encounter" | "event", "encounter": StringName, "event": StringName,
##               "enemies": Array of EnemySnapshot dictionaries},
##   "pickups": Array of {"placement": int (1-based), "item": StringName, "price": int, "taken": bool},
##   "visited": bool, "cleared": bool,
##   "opened": true (spec keys-and-gear 2.2: only on a locked room a key opened) }
class_name FloorMap
extends RefCounted

const ROLE_START: String = "start"
const ROLE_NORMAL: String = "normal"
const ROLE_BOSS: String = "boss"
const ROLE_SPECIAL: String = "special"
## N, E, S, W, matching RoomDefinition.DOOR_* bits.
const DIRECTIONS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const DOOR_BITS: Array[int] = [1, 2, 4, 8]

var size: Vector2i
var start: int = -1
var boss: int = -1
var cells: Dictionary = {}
## Generation attempts used (for the log and tests).
var attempts: int = 0


func _init(grid_size: Vector2i = Vector2i(9, 8)) -> void:
	size = grid_size


func index_of(cell: Vector2i) -> int:
	return cell.y * size.x + cell.x


@warning_ignore("integer_division")
func cell_of(index: int) -> Vector2i:
	return Vector2i(index % size.x, index / size.x)


func inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < size.x and cell.y < size.y


## Filled neighbour indices in N, E, S, W order.
func neighbours(index: int) -> Array[int]:
	var result: Array[int] = []
	var cell := cell_of(index)
	for direction in DIRECTIONS:
		var next := cell + direction
		if inside(next) and cells.has(index_of(next)):
			result.append(index_of(next))
	return result


## Door bits towards filled neighbours.
func door_mask(index: int) -> int:
	var mask := 0
	var cell := cell_of(index)
	for i in DIRECTIONS.size():
		var next := cell + DIRECTIONS[i]
		if inside(next) and cells.has(index_of(next)):
			mask |= DOOR_BITS[i]
	return mask


func sorted_indices() -> Array[int]:
	var result: Array[int] = []
	result.assign(cells.keys())
	result.sort()
	return result


## Breadth-first distance from the start to every filled cell.
func distances() -> Dictionary:
	var result := {start: 0}
	var queue: Array[int] = [start]
	while not queue.is_empty():
		var current: int = queue.pop_front()
		for next in neighbours(current):
			if not result.has(next):
				result[next] = result[current] + 1
				queue.append(next)
	return result


## Canonical text lines for hashing (stable order, integers and ids only).
func canonical_lines() -> PackedStringArray:
	var lines := PackedStringArray(["map=%dx%d|start=%d|boss=%d" % [size.x, size.y, start, boss]])
	for index in sorted_indices():
		var data: Dictionary = cells[index]
		var content: Dictionary = data["content"]
		var enemies := PackedStringArray()
		for enemy in content.get("enemies", []):
			enemies.append("%d:%s:%s:%s" % [enemy["slot"], enemy["unitDefId"], enemy["loadoutRef"], enemy["variantId"]])
		var pickups := PackedStringArray()
		for pickup in data["pickups"]:
			var line := "%d:%s:%d:%d" % [pickup["placement"], pickup["item"], pickup["price"], 1 if pickup["taken"] else 0]
			if pickup.has("priceItem"):
				line += ":%s" % pickup["priceItem"]  # spec playable-demo 3.8; absent on every older pickup
			pickups.append(line)
		lines.append("cell=%d|%s|%s|%s|%d|%s|%s|%s|%s|%s|%d|%d" % [index, data["role"], data["special_tag"], data["room"],
			data["doors"], content["kind"], content.get("encounter", ""), content.get("event", ""), ",".join(enemies),
			",".join(pickups), 1 if data["visited"] else 0, 1 if data["cleared"] else 0]
			+ ("|opened" if data.get("opened", false) else ""))
	return lines
