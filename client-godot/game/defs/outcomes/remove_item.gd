## Removes an item from whoever holds it. Its grants are gone from the next battle.
@tool
class_name RemoveItem
extends RunOutcome

@export var item: ItemDefinition


func apply(run: Object) -> void:
	run.remove_item(item)
