## Adds a flat amount to an attribute, on x100 whole numbers, scaled by up to two multiplier attributes:
##   attribute += amount x source.<source_bonus> x target.<target_bonus>
## Heals: attribute "hp", source_bonus "heal_mult", target_bonus "heal_taken". Ult charge: attribute "energy",
## target_bonus "energy_regen". An empty bonus name (or a unit without that attribute) counts as 100%.
@tool
class_name ExecCalcRestore
extends GameplayExecutionCalculation

@export var attribute: String = "hp"
## The amount as typed (300 = +300). Editor-only view of amount_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var amount: float:
	get:
		return Fixed.to_display(amount_x100)
	set(typed):
		amount_x100 = Fixed.from_typed(typed)

@export_storage var amount_x100: int = 0
## Multiplier attribute read from the unit that applied the effect ("" = none).
@export var source_bonus: String = ""
## Multiplier attribute read from the unit receiving it ("" = none).
@export var target_bonus: String = ""


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	return {attribute: float(scaled(amount_x100, spec, target_asc, source_bonus, target_bonus))}


## amount x source.<source_bonus> x target.<target_bonus>; each multiplier never below 0%.
static func scaled(value: int, spec: GameplayEffectSpec, target_asc: AbilitySystemComponent, source_name: String,
		target_name: String) -> int:
	if source_name != "":
		value = Fixed.pct(value, _multiplier(BattleContext.source_asc(spec), source_name))
	if target_name != "":
		value = Fixed.pct(value, _multiplier(target_asc, target_name))
	return value


static func _multiplier(asc: AbilitySystemComponent, attribute_name: String) -> int:
	var data := asc.get_attribute(attribute_name) if asc != null else null
	return maxi(int(data.current_value), 0) if data != null else Fixed.ONE_HUNDRED_PERCENT
