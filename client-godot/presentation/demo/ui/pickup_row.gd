## UIList entry of the pickup panel: one pedestal or shop slot. Item: {"run", "pickup", "thing" (the item or armor
## piece), "equipment"}. The name takes the theme variation `rarity_variation_prefix` + the tier of its
## Item.Rarity.* tag (RarityEpic…); armor needs no "give to" picker (it goes to the armor bag).
extends VBoxContainer

## Take or Buy was pressed: "" or why it was refused.
signal taken(problem: String)

@export var rarity_tag_prefix: String = "Item.Rarity."
@export var rarity_variation_prefix: String = "Rarity"
@export var rarity_format: String = "[%s] "
@export var usable_suffix: String = " (use)"
@export var slot_format: String = " (%s)"
@export var coins_format: String = "  %d coins"
## An altar's price: the curse item's name and description.
@export var price_item_format: String = "  costs a %s: %s"
@export var take_text: String = "Take"
@export var buy_text: String = "Buy"

var _run: RunController
var _placement: int = 0


func _ready() -> void:
	%Take.pressed.connect(_take)


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	_run = item["run"]
	var pickup: Dictionary = item["pickup"]
	var thing: Resource = item["thing"]
	_placement = pickup["placement"]
	var name_text: String = thing.display_name
	if item["equipment"]:
		name_text += slot_format % String(thing.slot).get_slice(".", 2)
	elif thing.is_usable():
		name_text += usable_suffix
	%Name.theme_type_variation = &""
	for tag in thing.tags:
		if String(tag).begins_with(rarity_tag_prefix):
			var tier := String(tag).trim_prefix(rarity_tag_prefix)
			name_text = rarity_format % tier + name_text
			%Name.theme_type_variation = StringName(rarity_variation_prefix + tier)
			break
	%Name.text = name_text + _price(pickup)
	%Name.tooltip_text = thing.description
	%Description.text = thing.description
	%Description.visible = thing.description != ""
	var paid: bool = pickup["price"] > 0 or pickup.has("priceItem")
	%Take.text = buy_text if paid else take_text
	%GiveTo.visible = not item["equipment"]
	%GiveTo.clear()
	if not item["equipment"]:
		for member in _run.state.party:
			var character: UnitDefinition = _run.content.units.get(member["character"])
			%GiveTo.add_item(character.display_name if character != null else String(member["character"]), member["slot"])
			if _run.can_hold(member["slot"], thing) != "":
				%GiveTo.set_item_disabled(%GiveTo.item_count - 1, true)


func _price(pickup: Dictionary) -> String:
	if pickup.has("priceItem"):
		var curse: ItemDefinition = _run.content.items.get(StringName(str(pickup["priceItem"])))
		return price_item_format % [curse.display_name, curse.description] if curse != null \
			else price_item_format % [str(pickup["priceItem"]), ""]
	return coins_format % pickup["price"] if pickup["price"] > 0 else ""


func _take() -> void:
	var slot: int = %GiveTo.get_item_id(%GiveTo.selected) if %GiveTo.visible and %GiveTo.selected >= 0 else 0
	taken.emit(_run.take(_placement, slot))
