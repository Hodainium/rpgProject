## UIList entry of the pickup panel: one pedestal or shop slot. Item: {"run", "pickup", "thing" (the item or armor
## piece), "equipment"}. The name takes the theme variation `rarity_variation_prefix` + the tier of its
## Item.Rarity.* tag (RarityEpic…); armor needs no "give to" picker (it goes to the armor bag).
extends VBoxContainer

## Take or Buy was pressed: "" or why it was refused (then `refusal` says what about, spec ui-feedback 2.2).
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
## Spec floor-chests 2.6: a closed chest's button, free or for a key.
@export var open_text: String = "Open"
@export var open_key_text: String = "Open · 1 key"
## A chest's item, after its name.
@export var from_chest_format: String = "  from the %s"

var _run: RunController
var _placement: int = 0
var _chest_serial: int = -1
## The last refusal's UIRefusal data ({} = nothing to flash).
var refusal: Dictionary = {}


func _ready() -> void:
	%Take.pressed.connect(_take)


func set_item(item: Dictionary, _ctx: UIContext) -> void:
	_run = item["run"]
	var pickup: Dictionary = item["pickup"]
	var thing: Resource = item["thing"]
	_placement = pickup["placement"]
	_chest_serial = -1
	if item.has("chest"):  # spec floor-chests: a closed chest; Open pays its key
		var chest: Dictionary = item["chest"]
		_chest_serial = chest["serial"]
		%Name.theme_type_variation = &""
		%Name.text = thing.display_name
		%Name.tooltip_text = thing.description
		%Description.text = thing.description
		%Description.visible = thing.description != ""
		%Take.text = open_key_text if chest["needs_key"] and not chest["free"] else open_text
		%Take.disabled = not chest["can_open"]
		%GiveTo.visible = false
		%GiveTo.clear()
		return
	%Take.disabled = false
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
	var chest_name: String = item.get("chest_name", "")
	%Name.text = name_text + _price(pickup) + (from_chest_format % chest_name if chest_name != "" else "")
	%Name.tooltip_text = thing.description
	%Description.text = thing.description
	%Description.visible = thing.description != ""
	var paid: bool = pickup["price"] > 0 or pickup.has("priceItem")
	%Take.text = buy_text if paid else take_text
	var no_holder: bool = item["equipment"] or item.get("keys", false)  # armor and keys go to the party, not a member
	%GiveTo.visible = not no_holder
	%GiveTo.clear()
	if not no_holder:
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
	if _chest_serial >= 0:
		refusal = UIRefusal.for_chest(_run, _chest_serial)  # read before the try: a refusal changes nothing
		taken.emit(_run.open_chest(_chest_serial))
		return
	var slot: int = %GiveTo.get_item_id(%GiveTo.selected) if %GiveTo.visible and %GiveTo.selected >= 0 else 0
	refusal = UIRefusal.for_take(_run, _placement, slot)
	taken.emit(_run.take(_placement, slot))


## Spec ui-feedback: what of this row a refusal flashes: the price (gold), the Open button (a locked chest), the member
## picker (a member who can't hold it).
func refused_controls(data: Dictionary) -> Array:
	var target: String = str(data.get(UIRefusal.TARGET, ""))
	if _chest_serial >= 0:
		return [%Take] if target == UIRefusal.LOCK and int(data.get("chest", -2)) == _chest_serial else []
	if int(data.get("placement", -2)) != _placement:
		return []
	if target == UIRefusal.GOLD:
		return [{"control": %Name, "shake": false}]
	if target in [UIRefusal.MEMBER, UIRefusal.MEMBER_ITEMS] and %GiveTo.visible:
		return [%GiveTo]
	return []
