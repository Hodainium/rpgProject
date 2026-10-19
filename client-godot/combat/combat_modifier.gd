## GameplayEffectModifier with decimal authoring (Lyra-style extension, spec "Number format").
##
## Designers type `value` as they mean it; it is saved ×100 as a whole number in `value_x100`.
## - ADD / OVERRIDE: an attribute amount (typed 50 → +50.00, stored 5000, which matches attributes stored ×100).
## - PERCENT_ADD: a percentage (typed 20 → +20%).
## - MULTIPLY / DIVIDE: a factor (typed 1.5 → ×1.5).
## The inherited `magnitude` field is ignored for STATIC calculation.
@tool
class_name CombatModifier
extends GameplayEffectModifier

## The value as typed, with up to 2 decimals. Editor-only view of value_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var value: float:
	get:
		return Fixed.to_display(value_x100)
	set(typed):
		if Fixed.has_extra_decimals(typed):
			push_warning("CombatModifier: only 2 decimals are kept (%s)." % typed)
		value_x100 = Fixed.from_typed(typed)

## Saved form of `value`: ×100 whole number.
@export_storage var value_x100: int = 0


func calculate_magnitude(level: float = 1.0) -> float:
	var magnitude_value: float
	match operation:
		Operation.PERCENT_ADD:
			magnitude_value = value_x100 / float(Fixed.ONE_HUNDRED_PERCENT)
		Operation.MULTIPLY, Operation.DIVIDE:
			magnitude_value = value_x100 / 100.0
		_:
			magnitude_value = float(value_x100)
	if scaling_curve:
		return scaling_curve.sample(level) * magnitude_value
	return magnitude_value
