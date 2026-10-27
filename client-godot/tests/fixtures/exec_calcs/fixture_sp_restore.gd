## Frozen fixture copy of the content's SP gain (spec skill-points 3.3): attribute += whole(target.<amount_attribute> ×
## target.<target_bonus>). The same integer math as ExecCalcRestore with amount_attribute and whole; system tests
## never load content.
class_name FixtureSpRestore
extends GameplayExecutionCalculation

@export var attribute: String = "mp"
@export var amount_attribute: String = "sp_basic"
@export var target_bonus: String = "sp_gain"


func execute(_spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	var data := target_asc.get_attribute(amount_attribute)
	var value := int(data.current_value) if data != null else 0
	var bonus := target_asc.get_attribute(target_bonus)
	if bonus != null:
		value = Fixed.pct(value, maxi(int(bonus.current_value), 0))
	return {attribute: float(value / 100 * 100)}
