## Spec content-pass H5: one boss phase. When the enemy's HP falls below `hp_below` (% of max HP), the battle grants
## `ability_set` (abilities, effects and tags such as State.Phase.Two) and sends Event.Unit.PhaseChanged. Phase-specific
## behaviour comes from activation queries on those tags, never from code.
@tool
class_name BossPhase
extends Resource

## HP threshold as typed (50 = below 50% of max HP). Editor-only view of hp_below_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var hp_below: float:
	get:
		return Fixed.to_display(hp_below_x100)
	set(typed):
		hp_below_x100 = Fixed.from_typed(typed)

## Granted when the phase starts, through the same path as items and variants.
@export var ability_set: AbilitySet
## Removes the unit's debuffs (effects granting a Status.Debuff tag) as the phase starts.
@export var clear_debuffs: bool = false

@export_storage var hp_below_x100: int = 0


## True when `hp` (stored ×100) is below this phase's share of `max_hp`. Integer math only.
func reached(hp: int, max_hp: int) -> bool:
	return hp * Fixed.ONE_HUNDRED_PERCENT < hp_below_x100 * max_hp
