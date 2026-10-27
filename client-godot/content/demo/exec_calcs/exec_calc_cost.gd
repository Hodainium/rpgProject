## Spec skill-points: an ability's SP cost (its cost_effect), scaled by the caster's cost multiplier and truncated to a
## whole SP in the caster's favour: attribute −= whole(amount × source.<source_bonus>). GodotGAS's can_afford_cost
## runs it on a mock spec, so a move the unit can't pay for is refused as before. Values ×100; 100% = 10000.
@tool
class_name ExecCalcCost
extends GameplayExecutionCalculation

@export var attribute: String = "mp"
## The cost as typed (37 = 37 SP). Editor-only view of amount_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var amount: float:
	get:
		return Fixed.to_display(amount_x100)
	set(typed):
		amount_x100 = Fixed.from_typed(typed)

@export_storage var amount_x100: int = 0
## Multiplier attribute read from the caster ("" = none, 100%).
@export var source_bonus: String = "sp_cost"


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	return {attribute: float(-cost_of(BattleContext.source_asc(spec))[attribute])}


## {attribute: the cost as a positive whole number ×100}: amount × the caster's bonus (never below 0%), truncated to
## whole SP. CostReader (the cost hint, the bots) calls it on any cost ExecCalc that has it.
func cost_of(caster: AbilitySystemComponent) -> Dictionary:
	var value := amount_x100
	if source_bonus != "" and caster != null:
		var data := caster.get_attribute(source_bonus)
		if data != null:
			value = Fixed.pct(value, maxi(int(data.current_value), 0))
	return {attribute: maxi(value, 0) / 100 * 100}
