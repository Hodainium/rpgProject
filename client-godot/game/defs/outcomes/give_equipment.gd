## Equips a piece on a character (empty: the first living member), replacing what is in that slot.
@tool
class_name GiveEquipment
extends RunOutcome

@export var equipment: EquipmentDefinition
@export var character: CharacterDefinition


func apply(run: Object) -> void:
	run.give_equipment(equipment, character)
