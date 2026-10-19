## Something placed on a room's 13 × 7 grid (spec game-skeleton, section 3.1).
@tool
class_name RoomPlacement
extends Resource

enum Kind {
	PLAYER_SPAWN,   ## Where party slot `slot` stands.
	ENEMY_SPAWN,    ## Where encounter slot `slot` stands; may override its loadout.
	EVENT_PROP,     ## The event's object (visual only).
	ITEM_PEDESTAL,  ## A free item (treasure, boss reward); unlocked when the room is cleared.
	SHOP_SLOT,      ## An item for sale.
}

@export var cell: Vector2i = Vector2i.ZERO
@export var kind: Kind = Kind.PLAYER_SPAWN
## Party slot or encounter slot, 1-based.
@export var slot: int = 1
## ENEMY_SPAWN: optional loadout override (a file, or inline: referenced as "<roomId>#<placement number>").
@export var loadout: Loadout
## ITEM_PEDESTAL / SHOP_SLOT: a fixed item, or a pool to pick from.
@export var item: ItemDefinition
@export var item_query: GameplayTagQuery
## SHOP_SLOT: price override; -1 uses the item's price.
@export var price: int = -1
