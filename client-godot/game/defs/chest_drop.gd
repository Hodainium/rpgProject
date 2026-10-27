## Spec keys-and-gear 2.1: one entry of RunStructure.chest_drops: which chest a chest drop is, by weight.
@tool
class_name ChestDrop
extends Resource

@export var chest: ChestDefinition
## Pick weight as typed. Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100
