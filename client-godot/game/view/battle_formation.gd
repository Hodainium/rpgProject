## Spec cube-style 3.10: where one side's units stand in a battle (presentation only; the battle itself has no positions). Rows are
## filled front first: the front row is nearest the room's centre line, each next row further back, and a row's units are centred
## along Z. The last row size repeats for big groups. Unset in a registry = the rooms' own spawn cells (today's layout).
class_name BattleFormation
extends Resource

## Units per row, front row first (enemies: 2 then 3).
@export var row_sizes: PackedInt32Array = PackedInt32Array([2, 3])
## Distance from the room's centre line (x = 0) to the front row, in world units.
@export var front_x: float = 2.6
## Distance between rows, away from the centre.
@export var row_spacing: float = 1.8
## Distance between the units of a row, along Z.
@export var lane_spacing: float = 1.8
## Per row, front first, a lane spacing of its own (the last repeats); empty = lane_spacing for every row. A wider back row
## staggers it against the front one (the party: 2.0 then 4.0, like the rooms' old spawn cells).
@export var row_lane_spacing: PackedFloat32Array = PackedFloat32Array()
## The Z every row is centred on (the camera looks from +Z: a little behind 0 keeps units clear of the battle HUD).
@export var center_z: float = -0.4


## The positions of `count` units on one side: `side` -1 = the party (left, -X), +1 = the enemies (right, +X).
func positions(count: int, side: int) -> Array[Vector3]:
	var placed: Array[Vector3] = []
	var remaining := count
	var row := 0
	while remaining > 0:
		var size := 3
		if not row_sizes.is_empty():
			size = maxi(1, row_sizes[mini(row, row_sizes.size() - 1)])
		var in_row := mini(size, remaining)
		var x := float(side) * (front_x + row * row_spacing)
		var lanes := lane_spacing if row_lane_spacing.is_empty() else row_lane_spacing[mini(row, row_lane_spacing.size() - 1)]
		for i in in_row:
			placed.append(Vector3(x, 0, center_z + (i - (in_row - 1) / 2.0) * lanes))
		remaining -= in_row
		row += 1
	return placed
