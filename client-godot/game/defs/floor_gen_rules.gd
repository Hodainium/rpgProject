## How a chapter's floors are generated (spec game-skeleton, sections 3.1 and 3.2). The room-type tags are data here,
## so the generator has no tag names in code.
@tool
class_name FloorGenRules
extends Resource

@export var id: StringName = &""
@export var grid_size: Vector2i = Vector2i(9, 8)
@export var base_rooms: int = 6
@export var rooms_per_depth: int = 2
@export var random_extra_rooms: int = 2
@export var max_rooms: int = 20
@export var max_attempts: int = 100
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var start_room_tag: StringName = &"Room.Type.Start"
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var normal_room_tag: StringName = &"Room.Type.Normal"
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var boss_room_tag: StringName = &"Room.Type.Boss"
## One dead end each, in this order (e.g. Room.Type.Treasure, Room.Type.Shop).
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var special_room_tags: Array[StringName] = []

## Chance (typed %) that the generator branches into a free neighbour. Editor-only view of branch_chance_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var branch_chance: float:
	get:
		return Fixed.to_display(branch_chance_x100)
	set(typed):
		branch_chance_x100 = Fixed.from_typed(typed)

@export_storage var branch_chance_x100: int = 5000
