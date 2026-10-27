## Frozen fixture copy of the content's SP cost (spec skill-points 3.3): attribute −= whole(amount × caster.sp_cost),
## with cost_of(caster) for CostReader. The same integer math as ExecCalcCost; system tests never load content.
class_name FixtureSpCost
extends GameplayExecutionCalculation

@export var attribute: String = "mp"
@export var amount_x100: int = 0
@export var source_bonus: String = "sp_cost"


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	return {attribute: float(-cost_of(BattleContext.source_asc(spec))[attribute])}


func cost_of(caster: AbilitySystemComponent) -> Dictionary:
	var value := amount_x100
	if source_bonus != "" and caster != null:
		var data := caster.get_attribute(source_bonus)
		if data != null:
			value = Fixed.pct(value, maxi(int(data.current_value), 0))
	return {attribute: maxi(value, 0) / 100 * 100}
