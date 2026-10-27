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
## Spec skill-points D14: a mirror boss doesn't copy a piece whose grants carry one of these tags or a tag under one
## (its set's tags or its effects' granted tags; "Drain" skips Drain.Physical). The piece still counts for
## per_item_effect. Empty: every piece is copied, as before.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var mirror_skip_tags: Array[StringName] = []
## Spec playable-demo 3.8 H10: applied once per item and armor piece the party holds, after floor scaling (run battles
## only). It must stack (FREE stacking policy).
@export var per_item_effect: GameplayEffect
## Spec skill-points (the stall traces): a soft enrage. From battle turn `overtime_turn` on (0 = never), at each of
## this enemy's turn starts it gets `overtime_effect` (a stacking effect, e.g. +10% ATK per stack), so a fight that
## drags on (a lone tank the boss can't kill) ends. Run and test battles alike; no effect = nothing happens.
@export var overtime_turn: int = 0
@export var overtime_effect: GameplayEffect
## Also from `overtime_turn`, at each of this enemy's turn starts: applied to every living party unit (e.g. lose 5% of
## max HP, which no affinity stops), so a party the enemy can't hurt (a lone tank that drains its damage) still falls.
@export var overtime_party_effect: GameplayEffect
## Spec playable-demo 3.11 (D31, Castlevania style): an item this enemy may drop when beaten (food), at drop_chance.
@export var drop_item: ItemDefinition
## The drop chance as typed (3 = 3%). Editor-only view of drop_chance_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var drop_chance: float:
	get:
		return Fixed.to_display(drop_chance_x100)
	set(typed):
		drop_chance_x100 = Fixed.from_typed(typed)

@export_storage var drop_chance_x100: int = 0
