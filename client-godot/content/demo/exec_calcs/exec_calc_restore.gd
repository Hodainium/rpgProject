## Adds a flat amount to an attribute, on x100 whole numbers, scaled by up to two multiplier attributes:
##   attribute += amount x source.<source_bonus> x target.<target_bonus>
## Heals: attribute "hp", source_bonus "heal_mult", target_bonus "heal_taken". Ult charge: attribute "energy",
## target_bonus "energy_regen". An empty bonus name (or a unit without that attribute) counts as 100%.
## Spec skill-points: SP per basic attack: attribute "mp", amount_attribute "sp_basic", target_bonus "sp_gain", whole.
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
## Spec skill-points: read the amount from this attribute of the unit receiving it instead of `amount` ("" = `amount`).
@export var amount_attribute: String = ""
## Spec skill-points: truncate the result to a whole number (a multiple of 100 ×100), so no fraction is ever shown.
@export var whole: bool = false


func execute(spec: GameplayEffectSpec, target_asc: AbilitySystemComponent) -> Dictionary:
	if not target_asc.has_attribute(attribute):
		return {}
	var value := scaled(_amount(target_asc), spec, target_asc, source_bonus, target_bonus)
	return {attribute: float(_whole(value))}


## Spec auto-support: what execute would restore on `target_asc` if `source_asc` applied it now (no echo), for
## RestoreReader. The same formula as execute; never changes anything.
func restore_of(source_asc: AbilitySystemComponent, target_asc: AbilitySystemComponent) -> Dictionary:
	if target_asc == null or not target_asc.has_attribute(attribute):
		return {}
	return {attribute: _whole(bonused(_amount(target_asc), source_asc, target_asc, source_bonus, target_bonus))}


## amount x source.<source_bonus> x target.<target_bonus>; each multiplier never below 0%.
## Spec item-power K7: an echo's restore is scaled too (Data.Echo.Scale, only set on an echo's specs).
static func scaled(value: int, spec: GameplayEffectSpec, target_asc: AbilitySystemComponent, source_name: String,
		target_name: String) -> int:
	if spec.set_by_caller_magnitudes.has(ExecutionRow.ECHO_SCALE_TAG):
		value = Fixed.pct(value, int(spec.get_set_by_caller_magnitude(ExecutionRow.ECHO_SCALE_TAG)))
	return bonused(value, BattleContext.source_asc(spec), target_asc, source_name, target_name)


## The two bonus multipliers of scaled, without a spec (spec auto-support): value x source.<source_name> x
## target.<target_name>.
static func bonused(value: int, source_asc: AbilitySystemComponent, target_asc: AbilitySystemComponent,
		source_name: String, target_name: String) -> int:
	if source_name != "":
		value = Fixed.pct(value, _multiplier(source_asc, source_name))
		if source_name == "heal_mult":  # Spec second-pack: Martyr's Grace, Martyr's Vial
			value = Fixed.pct(value, Fixed.ONE_HUNDRED_PERCENT + missing_bonus(source_asc, "missing_hp_heal"))
	if target_name != "":
		value = Fixed.pct(value, _multiplier(target_asc, target_name))
	return value


func _amount(target_asc: AbilitySystemComponent) -> int:
	if amount_attribute == "":
		return amount_x100
	var data := target_asc.get_attribute(amount_attribute)
	return int(data.current_value) if data != null else 0


func _whole(value: int) -> int:
	return value / 100 * 100 if whole else value


## Spec second-pack: the bonus (×100 %) `rate_name` gives for the share of `asc`'s max HP missing: rate% per 1% missing
## (rate 0.5 and 40% missing = +20%). 0 without the attribute or at full HP. Whole numbers only.
@warning_ignore("integer_division")
static func missing_bonus(asc: AbilitySystemComponent, rate_name: String) -> int:
	if asc == null:
		return 0
	var rate := asc.get_attribute(rate_name)
	var max_hp := asc.get_attribute("max_hp")
	var hp := asc.get_attribute("hp")
	if rate == null or max_hp == null or hp == null or int(rate.current_value) <= 0 or int(max_hp.current_value) <= 0:
		return 0
	var missing := maxi(int(max_hp.current_value) - int(hp.current_value), 0) * Fixed.ONE_HUNDRED_PERCENT / int(max_hp.current_value)
	return missing * int(rate.current_value) / 100


static func _multiplier(asc: AbilitySystemComponent, attribute_name: String) -> int:
	var data := asc.get_attribute(attribute_name) if asc != null else null
	return maxi(int(data.current_value), 0) if data != null else Fixed.ONE_HUNDRED_PERCENT
