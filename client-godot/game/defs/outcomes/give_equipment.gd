## Puts a piece in the run's armor inventory (spec playable-demo 3.7, D9: armor is never worn on its own; the player
## equips it on the map).
@tool
class_name GiveEquipment
extends RunOutcome

@export var equipment: EquipmentDefinition


func apply(run: Object) -> void:
	run.give_equipment(equipment)
