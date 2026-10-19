## An enemy wave (spec section 3.1). Enemies get unit ids E1, E2... in this order.
@tool
class_name EncounterDefinition
extends Resource

@export var id: StringName = &""
@export var enemies: Array[UnitDefinition] = []
