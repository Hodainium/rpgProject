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
## Spec second-pack (Crimson Signet): scales the amount by this attribute of the effect's source (×100 percent, e.g.
## "lifesteal": a crit heals that share of its damage once more). "" = none.
@export var source_scale: String = ""


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	var amount := amount_for(int(spec.get_set_by_caller_magnitude(ExecutionRow.EVENT_AMOUNT_TAG)), BattleContext.source_asc(spec),
		target_asc)
	return {attribute: float(-amount if loss else amount)}


## The amount `execute` applies for an event amount `amount` (×100), before the sign: scaled by the source's `source_scale` and
## the target's `target_bonus`. The battle reads it to know what a lifesteal heal really restores (the overheal shield).
func amount_for(amount: int, source: AbilitySystemComponent, target_asc: AbilitySystemComponent) -> int:
	if source_scale != "":
		var scale := source.get_attribute(source_scale) if source != null else null
		amount = Fixed.pct(amount, maxi(int(scale.current_value), 0)) if scale != null else 0
	if target_bonus != "":
		var data := target_asc.get_attribute(target_bonus) if target_asc != null else null
		amount = Fixed.pct(amount, maxi(int(data.current_value), 0)) if data != null else amount
	return amount
