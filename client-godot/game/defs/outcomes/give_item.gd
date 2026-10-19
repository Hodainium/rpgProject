## Gives a fixed item, or one picked from a pool (seeded), to a character (empty: the first living member who can
## hold it).
@tool
class_name GiveItem
extends RunOutcome

@export var item: ItemDefinition
@export var item_query: GameplayTagQuery
@export var character: CharacterDefinition


func apply(run: Object) -> void:
	run.give_item(item, item_query, character)
