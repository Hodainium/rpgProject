## The shape of a run (spec game-skeleton, section 3.1): its floors in order.
@tool
class_name RunStructure
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var floors: Array[FloorSlot] = []
## Given when an item pool has nothing left (Isaac's Breakfast).
@export var fallback_item: ItemDefinition
