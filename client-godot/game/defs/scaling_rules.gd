## Enemy scaling and drops for a chapter (spec game-skeleton, section 3.1).
@tool
class_name ScalingRules
extends Resource

@export var id: StringName = &""
## One infinite effect per floor depth (index 0 = first floor), applied to every enemy. Past the end, the last one
## applies; empty means no scaling. Must be saved .tres files.
@export var enemy_effects_by_depth: Array[GameplayEffect] = []
@export var coin_drop_min: int = 1
@export var coin_drop_max: int = 3

## Typed percentages (5 = 5%). Editor-only views of the ×100 fields.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var elite_chance: float:
	get:
		return Fixed.to_display(elite_chance_x100)
	set(typed):
		elite_chance_x100 = Fixed.from_typed(typed)
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var coin_drop_chance: float:
	get:
		return Fixed.to_display(coin_drop_chance_x100)
	set(typed):
		coin_drop_chance_x100 = Fixed.from_typed(typed)

@export_storage var elite_chance_x100: int = 0
@export_storage var coin_drop_chance_x100: int = 5000


func effect_for_depth(depth: int) -> GameplayEffect:
	if enemy_effects_by_depth.is_empty():
		return null
	return enemy_effects_by_depth[clampi(depth, 0, enemy_effects_by_depth.size() - 1)]
