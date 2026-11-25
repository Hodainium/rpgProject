## Spec item-power K6: changes an attribute by the amount an EVENT_AMOUNT row read from its triggering event
## (Data.Event.Amount, ×100), on whole numbers: attribute += amount, or −= amount with `loss`.
## Bloodthirst Blade heals by a share of the damage dealt (target_bonus "heal_taken"); Thornheart Plate takes a share of
## the damage taken from the attacker, with no defence, weakness or crit on top.
@tool
class_name ExecCalcEventAmount
extends GameplayExecutionCalculation

@export var attribute: String = "hp"
## Take the amount away instead of adding it.
@export var loss: bool = false
## Optional multiplier attribute of the unit receiving it, as in ExecCalcRestore ("heal_taken"; "" = none).
@export var target_bonus: String = ""


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	var amount := int(spec.get_set_by_caller_magnitude(ExecutionRow.EVENT_AMOUNT_TAG))
	if target_bonus != "":
		var data := target_asc.get_attribute(target_bonus)
		amount = Fixed.pct(amount, maxi(int(data.current_value), 0)) if data != null else amount
	return {attribute: float(-amount if loss else amount)}
