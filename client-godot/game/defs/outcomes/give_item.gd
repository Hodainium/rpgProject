## Gives a fixed item, or one picked from a pool (seeded), to a character, or else to the member `recipient` names.
## Spec floor-chests: in a chest the item lands on the floor beside it, whatever recipient and character say.
@tool
class_name GiveItem
extends RunOutcome

enum Recipient {
	FIRST,  ## The first living member who can hold it.
	RANDOM,  ## A seeded pick among the living members who can hold it.
	CHOOSE,  ## The player picks (a logged give_to); only in an event choice (an encounter reward's or a chest's item lands on the floor).
	SLOT,  ## Spec event-pass 2.1: the member at party position `slot`; the first who can hold it when that one cannot.
	LOWEST_HP,  ## Spec event-pass 2.1: the living member with the lowest HP share who can hold it (ties: the lowest slot).
	FLOOR,  ## Spec event-pass 2.1: a free pickup on the event room's floor, taken with take() (outside a room: FIRST).
}

@export var item: ItemDefinition
@export var item_query: GameplayTagQuery
@export var character: CharacterDefinition
@export var recipient: Recipient = Recipient.FIRST
## Spec event-pass 2.1: the party position (1-4) SLOT names.
@export_range(1, 4) var slot: int = 1


func apply(run: Object) -> void:
	run.give_item(item, item_query, character, recipient, slot)
