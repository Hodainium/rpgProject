## Frozen fixture copy of the content's heal ExecCalcs (spec auto-support 3.2): attribute += (amount, or percent of the
## target's max_attribute when percent_x100 is set) × source.<source_bonus> × target.<target_bonus>, each multiplier never
## below 0% (a missing attribute counts as 100%), with restore_of(source_asc, target_asc) for RestoreReader. The same
## integer math as ExecCalcRestore / ExecCalcPercentOfMax (no echo); system tests never load content.
class_name FixtureRestore
extends GameplayExecutionCalculation

@export var attribute: String = "hp"
@export var amount_x100: int = 0
## When above 0: restore this share of the target's max_attribute instead of amount_x100.
@export var percent_x100: int = 0
@export var max_attribute: String = "max_hp"
@export var source_bonus: String = ""
@export var target_bonus: String = ""


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	var restored := restore_of(BattleContext.source_asc(spec), target_asc)
	return {attribute: float(restored[attribute])} if restored.has(attribute) else {}


func restore_of(source_asc: AbilitySystemComponent, target_asc: AbilitySystemComponent) -> Dictionary:
	if target_asc == null or not target_asc.has_attribute(attribute):
		return {}
	var value := amount_x100
	if percent_x100 > 0:
		var maximum := target_asc.get_attribute(max_attribute)
		if maximum == null:
			return {}
		value = Fixed.pct(int(maximum.current_value), percent_x100)
	if source_bonus != "":
		value = Fixed.pct(value, _multiplier(source_asc, source_bonus))
	if target_bonus != "":
		value = Fixed.pct(value, _multiplier(target_asc, target_bonus))
	return {attribute: value}


static func _multiplier(asc: AbilitySystemComponent, attribute_name: String) -> int:
	var data := asc.get_attribute(attribute_name) if asc != null else null
	return maxi(int(data.current_value), 0) if data != null else Fixed.ONE_HUNDRED_PERCENT
