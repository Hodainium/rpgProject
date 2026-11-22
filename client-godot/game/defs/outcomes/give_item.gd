## Gives a fixed item, or one picked from a pool (seeded), to a character, or else to the member `recipient` names.
## Spec floor-chests: in a chest the item lands on the floor beside it, whatever recipient and character say.
@tool
class_name GiveItem
extends RunOutcome

enum Recipient {
	FIRST,  ## The first living member who can hold it.
	RANDOM,  ## A seeded pick among the living members who can hold it.
	CHOOSE,  ## The player picks (a logged give_to); only in an event choice (an encounter reward's or a chest's item lands on the floor).
}

@export var item: ItemDefinition
@export var item_query: GameplayTagQuery
@export var character: CharacterDefinition
@export var recipient: Recipient = Recipient.FIRST


func apply(run: Object) -> void:
	run.give_item(item, item_query, character, recipient)
