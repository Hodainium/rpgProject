## Spec item-power (Executioner's Greatsword): an enemy below `below` % of its max HP loses all of it; any other target, any
## unit with a spared tag (bosses) and every party unit (a mirror boss copies the sword) is untouched. Whole numbers ×100.
@tool
class_name ExecCalcFinish
extends GameplayExecutionCalculation

## The HP share as typed (25 = below 25%). Editor-only view of below_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var below: float:
	get:
		return Fixed.to_display(below_x100)
	set(typed):
		below_x100 = Fixed.from_typed(typed)

@export_storage var below_x100: int = 2500
## Units with this tag are never finished.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var spared_tag: StringName = &"Enemy.Boss"


func execute(_spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	var hp := target_asc.get_attribute("hp")
	var max_hp := target_asc.get_attribute("max_hp")
	if hp == null or max_hp == null or target_asc.has_tag_exact(spared_tag):
		return {}
	var unit := target_asc.get_parent() as BattleUnit
	if unit != null and unit.is_party():
		return {}
	if int(hp.current_value) <= 0 or int(hp.current_value) >= Fixed.pct(int(max_hp.current_value), below_x100):
		return {}
	return {"hp": float(-int(hp.current_value))}
