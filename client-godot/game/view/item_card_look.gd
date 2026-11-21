## Spec item-cards 3.1: how items look on the floor (item-room pedestals, shop shelves, an open chest's items): the item's card
## (concept D, picked at gate 1), turning and bobbing. On PropStyle.item, resolved through the style registry's base chain
## (StyleRegistry.item_look). The rim and the aura take the item's rarity colour (PropStyle.rarity_colors, the same map as the armor
## icons) and a tier from its rarity tag; a corrupted item is magenta at the top tier. Presentation only.
class_name ItemCardLook
extends Resource

## The demo's look (made by game/tools/build_item_cards.tscn; the main registry names it).
const DEFAULT_PATH: String = "res://presentation/demo/style/items/item_card_look.tres"

## What the floating label says.
enum LabelMode { NAME_AND_PRICE, PRICE_ONLY, NONE }
const LABEL_NAMES: PackedStringArray = ["name", "price", "none"]
const LABEL_TITLES: PackedStringArray = ["Name and price", "Price only", "No label"]

## The card's height in world units (gate 1: 0.7).
@export var size: float = 0.7
## Where the card's centre floats above the floor's top.
@export var offset: Vector3 = Vector3(0, 0.735, 0)
## Turns a second; with 0 and sway_degrees > 0 the card sways instead.
@export var spin_speed: float = 0.2
@export var sway_degrees: float = 0.0
@export var bob_amount: float = 0.06
@export var bob_speed: float = 0.5
## The rim's brightness per tier (above 1 blooms with the room's glow).
@export var rim_energy_by_tier: PackedFloat32Array = [1.0, 1.8, 2.0, 2.4]
## The rim's width in design pixels of the 300 x 420 face.
@export var card_rim: float = 7.0
## The face's render scale (pixels per design pixel).
@export var card_render_scale: float = 1.0
## The aura (item_aura.tres: parameters color and tier).
@export var aura: FxDefinition
## Item.Rarity.* -> tier 0..3; an unlisted rarity is tier 0.
@export var tier_by_rarity: Dictionary[StringName, int] = {
	&"Item.Rarity.Common": 0, &"Item.Rarity.Rare": 1, &"Item.Rarity.Epic": 2, &"Item.Rarity.Legendary": 3}
## RoR's void tier: an item with this tag takes void_color and void_tier whatever its rarity.
@export_custom(PROPERTY_HINT_NONE, "gas::tag") var void_tag: StringName = &"Item.Corrupted"
@export var void_color: Color = Color(1.0, 0.25, 0.85)
@export var void_tier: int = 3
## The floating label and its height above the floor.
@export var label: LabelMode = LabelMode.NAME_AND_PRICE
@export var label_height: float = 1.6


## The tier of an item with `tags` (a corrupted item: void_tier).
func tier_of(tags: Array) -> int:
	if void_tag != &"" and TagMatch.has(tags, void_tag):
		return void_tier
	for tag in tags:
		if tier_by_rarity.has(StringName(tag)):
			return tier_by_rarity[StringName(tag)]
	return 0


func rim_energy(tier: int) -> float:
	return rim_energy_by_tier[clampi(tier, 0, rim_energy_by_tier.size() - 1)] if not rim_energy_by_tier.is_empty() else 1.0


## The label's text for an item named `item_name` at `price` (0 = not for sale) under `mode`.
static func label_text(mode: int, item_name: String, price: int) -> String:
	match mode:
		LabelMode.NAME_AND_PRICE:
			return item_name + (" (%d)" % price if price > 0 else "")
		LabelMode.PRICE_ONLY:
			return "%d Gold" % price if price > 0 else ""
	return ""
