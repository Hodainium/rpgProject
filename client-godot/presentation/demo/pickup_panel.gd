## Demo pickup / shop panel (placeholder): the room's pedestal and shop items, a "give to" picker, Take / Buy.
extends Control

var _main: GameMain

@onready var _rows: VBoxContainer = %Rows


func setup(main: GameMain) -> void:
	_main = main
	main.run_changed.connect(_bind)
	main.mode_changed.connect(func(_mode): _refresh())
	visible = false


func _bind(run: RunController) -> void:
	for changed in [run.pickups_shown, run.room_entered, run.room_cleared, run.party_changed, run.battle_requested]:
		changed.connect(func(_a = null): _refresh.call_deferred())


func _refresh() -> void:
	for child in _rows.get_children():
		child.queue_free()
	var run := _main.run
	visible = false
	if run == null or run.state == null or run.state.map == null or _main.mode != "run" or not run.pending_battle.is_empty():
		return
	var data: Dictionary = run.state.map.cells[run.state.current_cell]
	if not data["cleared"]:
		return
	for pickup in data["pickups"]:
		if pickup["taken"]:
			continue
		if pickup.get("kind", "") == FloorGenerator.EQUIPMENT_KIND:
			_armor_row(run, pickup)
			continue
		var item: ItemDefinition = run.content.items.get(pickup["item"])
		if item == null:
			continue
		visible = true
		var row := HBoxContainer.new()
		row.tooltip_text = item.description
		if item.icon != null:
			var icon := TextureRect.new()
			icon.texture = item.icon
			icon.custom_minimum_size = Vector2(24, 24)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			row.add_child(icon)
		var label := Label.new()
		label.text = "%s%s%s" % [item.display_name, " (use)" if item.is_usable() else "", _price(run, pickup)]
		_mark_rarity(label, item.tags)
		label.tooltip_text = item.description
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(label)
		var picker := OptionButton.new()
		for member in run.state.party:
			var character: UnitDefinition = run.content.units.get(member["character"])
			picker.add_item(character.display_name if character != null else String(member["character"]), member["slot"])
			if run.can_hold(member["slot"], item) != "":
				picker.set_item_disabled(picker.item_count - 1, true)
		row.add_child(picker)
		var take := Button.new()
		take.text = "Buy" if pickup["price"] > 0 or pickup.has("priceItem") else "Take"
		take.pressed.connect(_take.bind(pickup["placement"], picker))
		row.add_child(take)
		_rows.add_child(row)
		_add_description(item.description)


## Armor (spec item-pass 3.5): always taken into the armor inventory, so no "give to" picker; shows its slot.
func _armor_row(run: RunController, pickup: Dictionary) -> void:
	var piece: EquipmentDefinition = run.content.equipment.get(pickup["item"])
	if piece == null:
		return
	visible = true
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "%s (%s)%s" % [piece.display_name, String(piece.slot).get_slice(".", 2), _price(run, pickup)]
	_mark_rarity(label, piece.tags)
	label.tooltip_text = piece.description
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.size_flags_horizontal = SIZE_EXPAND_FILL
	row.add_child(label)
	var take := Button.new()
	take.text = "Buy" if pickup["price"] > 0 or pickup.has("priceItem") else "Take"
	take.pressed.connect(_take.bind(pickup["placement"], null))
	row.add_child(take)
	_rows.add_child(row)
	_add_description(piece.description)


## Spec playable-demo 3.6/3.8: "  12 coins", or what an altar costs instead ("  costs a Void Scar: -10% max HP").
static func _price(run: RunController, pickup: Dictionary) -> String:
	if pickup.has("priceItem"):
		var curse: ItemDefinition = run.content.items.get(StringName(str(pickup["priceItem"])))
		if curse == null:
			return "  costs %s" % pickup["priceItem"]
		return "  costs a %s%s" % [curse.display_name, ": " + curse.description if curse.description != "" else ""]
	return "  %d coins" % pickup["price"] if pickup["price"] > 0 else ""


const RARITY_COLORS: Dictionary = {
	"Common": Color(0.9, 0.9, 0.9), "Rare": Color(0.45, 0.7, 1.0), "Epic": Color(0.8, 0.5, 1.0),
	"Legendary": Color(1.0, 0.75, 0.3),
}


## "[Epic] " before the name, in the tier's color, from the Item.Rarity.* tag.
static func _mark_rarity(label: Label, tags: Array[StringName]) -> void:
	for tag in tags:
		if String(tag).begins_with("Item.Rarity."):
			var tier := String(tag).get_slice(".", 2)
			label.text = "[%s] %s" % [tier, label.text]
			label.add_theme_color_override("font_color", RARITY_COLORS.get(tier, Color.WHITE))
			return


## The description in small grey type under its row.
func _add_description(text: String) -> void:
	if text == "":
		return
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = Color(0.75, 0.75, 0.75)
	label.add_theme_font_size_override("font_size", 13)
	_rows.add_child(label)


func _take(placement: int, picker: OptionButton) -> void:
	var problem := _main.run.take(placement, picker.get_item_id(picker.selected) if picker != null else 0)
	if problem != "":
		_main.show_message(problem)
	get_tree().call_group("sound_board", "play", "Refused" if problem != "" else "Item")
	_refresh()
