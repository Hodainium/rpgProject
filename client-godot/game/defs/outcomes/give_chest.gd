## Spec keys-and-gear 3.2: puts a chest in the party's chest inventory (opened later, on the map).
@tool
class_name GiveChest
extends RunOutcome

@export var chest: ChestDefinition


func apply(run: Object) -> void:
	run.give_chest(chest)
