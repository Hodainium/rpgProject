## Spec card-ui 2.3a: one pack type on sale in the Shop (the prototype's offer): the pack art, its name in the card font, what
## it holds, the Rare guarantee, how many the account owns, Buy 1 and Buy 5 with their prices, and the odds per card.
## Hover previews it in the description window; a Buy button asks the screen (`buy_requested`).
extends PanelContainer

signal buy_requested(pack_id: String, count: int)
signal hovered(offer: Dictionary)

@export var holds_text: String = "%d cards. Packs you buy wait in Open packs."
@export var guarantee_text: String = "At least one %s or better in every pack."
@export var owned_text: String = "You own %d unopened."
@export var owned_unknown_text: String = ""
@export var buy_text: String = "Buy %d · %d gems"
@export var odds_title: String = "Odds per card (before the guarantee and pity)"
@export var name_size: int = 26

var offer: Dictionary = {}
var _gems: int = -1
var _locked: bool = false


func _ready() -> void:
	mouse_entered.connect(func(): hovered.emit(offer))
	%Buy1.pressed.connect(func(): buy_requested.emit(str(offer.get("packId", "")), ShopModel.BUY_COUNTS[0]))
	%Buy5.pressed.connect(func(): buy_requested.emit(str(offer.get("packId", "")), ShopModel.BUY_COUNTS[1]))
	for button: Button in [%Buy1, %Buy5]:
		button.focus_entered.connect(func(): hovered.emit(offer))
		button.mouse_entered.connect(func(): hovered.emit(offer))


func set_item(item: Variant, _context: UIContext) -> void:
	offer = item
	var style := CardStyle.current()
	var look := style.pack(str(offer["packId"]))
	%Pack.look = look
	%Pack.name_font = style.name_font
	%Pack.label = look.label if look.label != "" else str(offer["name"])
	%Name.text = str(offer["name"])
	if style.name_font != null:
		%Name.add_theme_font_override(&"font", style.name_font)
	%Name.add_theme_font_size_override(&"font_size", name_size)
	%Holds.text = holds_text % int(offer["cardCount"])
	var min_rarity := str(offer["minRarity"])
	%Guarantee.visible = min_rarity != ""
	%Guarantee.text = guarantee_text % min_rarity.capitalize() if min_rarity != "" else ""
	var owned := int(offer["owned"])
	%Owned.text = owned_text % owned if owned >= 0 else owned_unknown_text
	%Owned.visible = %Owned.text != ""
	%OddsTitle.text = odds_title
	for child in %Odds.get_children():
		%Odds.remove_child(child)
		child.queue_free()
	for row in offer["odds"]:
		var rarity := Label.new()
		rarity.text = str(row["rarity"]).capitalize()
		rarity.add_theme_color_override(&"font_color", style.rarity(str(row["rarity"])).color)
		var value := Label.new()
		value.text = ShopModel.percent(int(row["per10000"]))
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		%Odds.add_child(rarity)
		%Odds.add_child(value)
	_update_buttons()


## The account's gems (-1 unknown) and whether an account action is busy: the Buy buttons follow.
func set_state(gems: int, locked: bool) -> void:
	_gems = gems
	_locked = locked
	_update_buttons()


func _update_buttons() -> void:
	if offer.is_empty():
		return
	var buttons: Array[Button] = [%Buy1, %Buy5]
	for index in buttons.size():
		var count: int = ShopModel.BUY_COUNTS[index]
		buttons[index].text = buy_text % [count, int(offer["price"]) * count]
		buttons[index].disabled = _locked or not ShopModel.affordable(offer, count, _gems)
