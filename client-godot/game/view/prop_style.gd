## Spec cube-style 6a Set K: the looks of the pickups on the floor: the shop key, an armor piece by its slot tag (tinted in its rarity's
## colour), and each chest's three states. Held by a StyleRegistry (`props`); each field is resolved through the registry's base chain
## on its own, so a variant can change only the armor icons. Presentation only. Items and event "?" props keep today's look.
class_name PropStyle
extends Resource

## A key for sale (a shop slot that sells keys); null = the base's, else today's cube.
@export var key: PropLook
## Equipment.Slot.* tag -> the icon of a piece in that slot.
@export var armor_by_slot: Dictionary[StringName, PropLook] = {}
## The icon of a piece whose slot has none above (a loot bag for every piece when the map is empty).
@export var armor_default: PropLook
## Item.Rarity.* tag -> its colour (the UI's rarity colours, ui_theme.tres); a piece's first rarity tag picks it.
@export var rarity_colors: Dictionary[StringName, Color] = {}
## Spec item-cards: how items look on the floor (null = the base's, else today's cube).
@export var item: ItemCardLook
## Chest definition id -> its look.
@export var chests: Dictionary[StringName, ChestLook] = {}
## A chest with no look above.
@export var chest_default: ChestLook
