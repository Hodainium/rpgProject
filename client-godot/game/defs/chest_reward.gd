## Spec keys-and-gear 2.3: one row of a chest's table. Picked by weight; its outcomes run rolls_min..rolls_max times
## (Isaac's "2-6 pickups"), in order.
@tool
class_name ChestReward
extends Resource

@export var outcomes: Array[RunOutcome] = []
@export var rolls_min: int = 1
@export var rolls_max: int = 1
## Pick weight as typed. Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100
