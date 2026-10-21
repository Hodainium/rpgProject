## Restores a share of the target's maximum, on x100 whole numbers: attribute += max_attribute x percent.
## Hourglass (5% max HP each turn), Hearty Stew (30% at floor start), Smelling Salts (revive at 20%).
## A revive is just this on a dead unit: its HP rises above 0 and the battle brings it back.
@tool
class_name ExecCalcPercentOfMax
extends GameplayExecutionCalculation

@export var attribute: String = "hp"
@export var max_attribute: String = "max_hp"
## The share as typed (5 = 5%). Editor-only view of percent_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var percent: float:
	get:
		return Fixed.to_display(percent_x100)
	set(typed):
		percent_x100 = Fixed.from_typed(typed)

@export_storage var percent_x100: int = 0


func execute(_spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	var maximum := target_asc.get_attribute(max_attribute)
	if maximum == null or not target_asc.has_attribute(attribute):
		return {}
	return {attribute: float(Fixed.pct(int(maximum.current_value), percent_x100))}
