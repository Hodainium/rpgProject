## An elite/champion variant of an enemy (spec game-skeleton, section 3.1). Rolled when the floor is generated.
@tool
class_name EnemyVariant
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var grants: AbilitySet
## Recolour in the placeholder screens (the variant's look; presentation can use its own skin later).
@export var display_color: Color = Color.WHITE
## Extra coins when a room with this enemy is cleared.
@export var coin_bonus: int = 0
