## Spec second-pack B1: an ability's HP cost (its cost_effect): a share of the caster's max HP, scaled by its `hp_cost` multiplier
## (Sanguine Pact, Heart of the Red Moon lower it) and truncated to whole HP in the caster's favour: hp −= whole(max_hp × percent ×
## source.hp_cost). CombatASC refuses a cost at or above the caster's current HP (a move never kills its user); CostReader reads
## cost_of for the hint and the bots. Values ×100; 100% = 10000.
@tool
class_name ExecCalcHpCost
extends GameplayExecutionCalculation

## The cost as typed (12 = 12% of max HP). Editor-only view of percent_x100.
@export_custom(PROPERTY_HINT_NONE, "suffix:%", PROPERTY_USAGE_EDITOR) var percent: float:
	get:
		return Fixed.to_display(percent_x100)
	set(typed):
		percent_x100 = Fixed.from_typed(typed)

@export_storage var percent_x100: int = 0
## Multiplier attribute read from the caster ("" = none, 100%).
@export var source_bonus: String = "hp_cost"
## Always hp: CombatASC reads it to know this cost touches HP (it then refuses a cost at or above the caster's HP).
var attribute: String = "hp"


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute("hp"):
		return {}
	return {"hp": float(-cost_of(BattleContext.source_asc(spec))["hp"])}


## {"hp": the cost as a positive whole number ×100}.
@warning_ignore("integer_division")
func cost_of(caster: AbilitySystemComponent) -> Dictionary:
	if caster == null or caster.get_attribute("max_hp") == null:
		return {"hp": 0}
	var value := Fixed.pct(int(caster.get_attribute("max_hp").current_value), percent_x100)
	if source_bonus != "":
		var data := caster.get_attribute(source_bonus)
		if data != null:
			value = Fixed.pct(value, maxi(int(data.current_value), 0))
	return {"hp": maxi(value, 0) / 100 * 100}
