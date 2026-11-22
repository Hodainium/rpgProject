## Removes an item from whoever holds it. Its grants are gone from the next battle.
## Left empty inside an item's own run hook (on_pickup, on_floor_start, on_room_cleared), it removes that item, e.g. a
## Mystery Box that turns into a random item (spec item-pass 3.6).
@tool
class_name RemoveItem
extends RunOutcome

@export var item: ItemDefinition
## Spec event-pass 2.2: with no `item`, one held item matching this query is removed instead, from the member `from`
## names (ANY: the first holder by slot; SLOT: the member at `slot`; RANDOM: a seeded pick among the matching held items).
## Nothing matches: nothing happens.
@export var item_query: GameplayTagQuery
enum From { ANY, SLOT, RANDOM }
@export var from: From = From.ANY
@export_range(1, 4) var slot: int = 1


func apply(run: Object) -> void:
	if item == null and item_query != null:
		run.remove_item_matching(item_query, from, slot)
		return
	run.remove_item(item if item != null else run.hook_item)
