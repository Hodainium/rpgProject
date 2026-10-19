## A Slay the Spire-style event (spec game-skeleton, section 3.1): pages of text with choices.
@tool
class_name EventDefinition
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var tags: Array[StringName] = []
## Page 0 is shown first.
@export var pages: Array[EventPage] = []

## Pick weight as typed. Editor-only view of weight_x100.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR) var weight: float:
	get:
		return Fixed.to_display(weight_x100)
	set(typed):
		weight_x100 = Fixed.from_typed(typed)

@export_storage var weight_x100: int = 100
