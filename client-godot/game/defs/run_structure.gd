## The shape of a run (spec game-skeleton, section 3.1): its floors in order.
@tool
class_name RunStructure
extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var floors: Array[FloorSlot] = []
## Given when an item pool has nothing left (Isaac's Breakfast).
@export var fallback_item: ItemDefinition
## The equipment slots characters have in this run, in display order (spec item-pass 3.5): tags such as
## Equipment.Slot.Weapon, Equipment.Slot.Head. A new slot is one more tag here; no code.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var equipment_slots: Array[StringName] = []
## Spec playable-demo 2.2: started when the content root holds several runs and none is named (menu, `new`).
@export var default_run: bool = false
