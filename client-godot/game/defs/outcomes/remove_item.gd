## Removes an item from whoever holds it. Its grants are gone from the next battle.
## Left empty inside an item's own run hook (on_pickup, on_floor_start, on_room_cleared), it removes that item, e.g. a
## Mystery Box that turns into a random item (spec item-pass 3.6).
@tool
class_name RemoveItem
extends RunOutcome

@export var item: ItemDefinition


func apply(run: Object) -> void:
	run.remove_item(item if item != null else run.hook_item)
