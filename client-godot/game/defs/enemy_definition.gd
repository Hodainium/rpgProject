## An enemy (spec game-skeleton, section 3.1). A UnitDefinition, so encounters and battles use it directly.
## A boss is an ordinary enemy tagged Enemy.Boss; boss rooms pick boss encounters by tag.
@tool
class_name EnemyDefinition
extends UnitDefinition

## Elite variants this enemy can roll (chance from the chapter's ScalingRules).
@export var variants: Array[EnemyVariant] = []
## Spec content-pass H5: boss phases, in order of strictly decreasing hp_below. Empty for ordinary enemies.
@export var phases: Array[BossPhase] = []
## Spec playable-demo 3.8 H9: also granted the passives (grants) of every item and armor piece the party holds, read
## from the battle snapshot (run battles only). Party-wide items then apply to the enemies' side.
@export var mirror_party_items: bool = false
## Spec playable-demo 3.8 H10: applied once per item and armor piece the party holds, after floor scaling (run battles
## only). It must stack (FREE stacking policy).
@export var per_item_effect: GameplayEffect
## Spec playable-demo 3.11 (D31, Castlevania style): an item this enemy may drop when beaten (food), at drop_chance.
@export var drop_item: ItemDefinition
## The drop chance as typed (3 = 3%). Editor-only view of drop_chance_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var drop_chance: float:
	get:
		return Fixed.to_display(drop_chance_x100)
	set(typed):
		drop_chance_x100 = Fixed.from_typed(typed)

@export_storage var drop_chance_x100: int = 0
