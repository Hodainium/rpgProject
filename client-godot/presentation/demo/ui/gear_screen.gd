## Spec ff7-ui 2.8 (F11, F12): the Equipment and Armor screens, one screen with a GearSet (equipment.tres: Weapon,
## Item Slot, Item Slot 2; armor.tres: Head, Body, Arms, Legs, Accessory). Characters at the bottom, one button per
## slot; hover previews a slot (the list above shows what fits it), click selects it. Item Slot 2 shows only while
## someone has two use slots, LOCKED for the others. A piece in the list opens the middle menu: EQUIP (from the bag),
## SWAP (worn by someone else: one logged swap_gear), TAKE OFF, CANCEL. Another member's use item: MOVE HERE (a free
## slot) or SWAP, one logged move_item (spec keys-and-gear 2.4, 2.5).
extends DemoMenuFrame

@export var gear_set: GearSet
@export var empty_text: String = "—"
@export var locked_text: String = "LOCKED"
@export var equipped_mark: String = "E"
@export var choose_name: String = "Choose a slot"
@export var choose_text: String = "Hover or click any character's slot. The list at the top shows what fits it."
@export var empty_slot_format: String = "Empty %s"
@export var locked_name: String = "Item slot %d · locked"
@export var locked_format: String = "%s has %d item slot(s). Items that add an item slot unlock this one."
@export var preview_suffix: String = " · PREVIEW (CLICK TO SELECT)"
@export var equipped_format: String = "Equipped by: %s"
@export var item_slot_suffix: String = " (item slot %d)"
@export var bag_text: String = "In the bag"
@export var mine_text: String = "%s already has this here."
@export var swap_format: String = "Swap: %s gets %s in return."
@export var nothing_text: String = "nothing"
@export var to_bag_format: String = "%s goes back to the bag."
@export var empty_slot_text: String = "The slot is empty."
@export var move_text: String = "MOVE HERE"

## {"member": slot, "column": GearColumn} or null.
var _selected: Variant = null
var _preview: Variant = null
## The list entry the middle menu is open for, or {}.
var _picked: Dictionary = {}
var _buttons: Array = []  # [{"member", "column", "button"}]


func on_pushed(payload: Dictionary) -> void:
	if payload.get("set") is GearSet:
		gear_set = payload["set"]


func bind(context: UIContext) -> void:
	context.on_run(self, &"party_changed", func(): refresh.call_deferred())
	%Equip.pressed.connect(_on_equip)
	%TakeOff.pressed.connect(_on_take_off)
	%Cancel.pressed.connect(_close_menu)


func handles_back() -> bool:
	if %Menu.visible:
		_close_menu()
		return true
	return false


func refresh() -> void:
	if ctx == null or ctx.run == null or ctx.run.state == null or gear_set == null:
		return
	_build_rows()
	_redraw()


# --- Columns and rows -----------------------------------------------------------------------------------------------

func _columns() -> Array[GearColumn]:
	var run := ctx.run
	var most := 0
	for member in run.state.party:
		most = maxi(most, run.use_capacity(member["slot"]))
	var shown: Array[GearColumn] = []
	for column in gear_set.columns:
		if column != null and (not column.is_use_slot() or most >= column.use_slot):
			shown.append(column)
	return shown


func _build_rows() -> void:
	for child in %Header.get_children():
		child.queue_free()
	for child in %Rows.get_children():
		child.queue_free()
	_buttons.clear()
	var columns := _columns()
	%Header.add_child(_label(gear_set.title, &"Caption", 150))
	for column in columns:
		var title := _label(column.title, &"Caption", 0)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		%Header.add_child(title)
	for member in ctx.run.state.party:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.add_child(_label(_member_name(member), &"RowName", 150))
		for column in columns:
			var button := Button.new()
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.custom_minimum_size = Vector2(0, 46)
			button.clip_text = true
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			var slot: int = member["slot"]
			button.mouse_entered.connect(_set_preview.bind({"member": slot, "column": column}))
			button.focus_entered.connect(_set_preview.bind({"member": slot, "column": column}))
			button.mouse_exited.connect(_set_preview.bind(null))
			button.pressed.connect(_select.bind({"member": slot, "column": column}))
			row.add_child(button)
			_buttons.append({"member": slot, "column": column, "button": button})
		%Rows.add_child(row)


func _label(text: String, variation: StringName, width: float) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.custom_minimum_size = Vector2(width, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _set_preview(slot: Variant) -> void:
	_preview = slot
	_redraw()


func _select(slot: Dictionary) -> void:
	if _locked(slot):
		return
	_selected = slot
	_redraw()


func _same(a: Variant, b: Variant) -> bool:
	return a != null and b != null and a["member"] == b["member"] and a["column"] == b["column"]


# --- Drawing --------------------------------------------------------------------------------------------------------

func _redraw() -> void:
	for entry in _buttons:
		var slot := {"member": entry["member"], "column": entry["column"]}
		var button: Button = entry["button"]
		var id := _piece_in(slot)
		var locked := _locked(slot)
		button.text = locked_text if locked else (_display_name(id) if id != &"" else empty_text)
		button.disabled = locked
		button.set_meta("ui_text", "%s %s" % [_member_name(ctx.run.state.member(slot["member"])), slot["column"].title])
		if locked:
			button.theme_type_variation = &"SlotButtonLocked"
		elif _same(slot, _selected):
			button.theme_type_variation = &"SlotButtonSelected"
		elif _same(slot, _preview):
			button.theme_type_variation = &"SlotButtonPreview"
		else:
			button.theme_type_variation = &"SlotButton"
	var view: Variant = _preview if _preview != null else _selected
	_draw_pool(view)
	if _picked.is_empty():
		_describe_slot(view)


func _draw_pool(view: Variant) -> void:
	var entries: Array = []
	var title := gear_set.title
	if view != null and not _locked(view):
		var column: GearColumn = view["column"]
		for piece in _pool(column):
			entries.append({"text": _display_name(piece["id"]), "detail": equipped_mark if piece["holder"] > 0 else "",
				"hover": _describe_piece.bind(piece), "action": _open_menu.bind(piece)})
		title = "%s · %d · %s" % [column.title, entries.size(), _member_name(ctx.run.state.member(view["member"])).to_upper()]
		if not _same(view, _selected):
			title += preview_suffix
	%ListTitle.text = title
	%Pool.set_items(entries)
	%Empty.visible = entries.is_empty()


## Every piece that fits `column`: worn ones (holder = member slot, index = use slot) and the bag's (holder 0).
func _pool(column: GearColumn) -> Array:
	var run := ctx.run
	var pieces: Array = []
	for member in run.state.party:
		if column.is_use_slot():
			for index in member["use_slots"].size():
				pieces.append({"id": member["use_slots"][index]["item"], "holder": member["slot"], "index": index + 1,
					"use": true})
		elif member["equipment"].has(column.slot):
			pieces.append({"id": member["equipment"][column.slot], "holder": member["slot"], "index": 0, "use": false})
	if not column.is_use_slot():
		for piece_id in run.state.armor:
			var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
			if piece != null and piece.slot == column.slot:
				pieces.append({"id": piece_id, "holder": 0, "index": 0, "use": false})
	return pieces


func _describe_slot(view: Variant) -> void:
	if view == null:
		describe({"name": choose_name, "text": choose_text})
		return
	var member := ctx.run.state.member(view["member"])
	if _locked(view):
		describe({"name": locked_name % view["column"].use_slot,
			"text": locked_format % [_member_name(member), ctx.run.use_capacity(view["member"])]})
		return
	var id := _piece_in(view)
	if id == &"":
		describe({"name": empty_slot_format % view["column"].title.to_lower(), "text": choose_text})
		return
	var holder := {"id": id, "holder": view["member"], "index": view["column"].use_slot, "use": view["column"].is_use_slot()}
	_describe_piece(holder)


func _describe_piece(piece: Dictionary) -> void:
	var definition: Resource = _definition(piece["id"])
	var extra := bag_text
	if piece["holder"] > 0:
		extra = equipped_format % _member_name(ctx.run.state.member(piece["holder"]))
		if piece["use"] and ctx.run.use_capacity(piece["holder"]) > 1:
			extra += item_slot_suffix % piece["index"]
	describe({"name": _display_name(piece["id"]), "kind": _kind_text(piece, definition),
		"text": definition.description if definition != null else "", "extra": extra})


func _kind_text(piece: Dictionary, definition: Resource) -> String:
	var kind := "USE ITEM"
	if not piece["use"] and definition is EquipmentDefinition:
		kind = String(definition.slot).get_slice(".", 2).to_upper()
	var rarity := _rarity(definition)
	return kind + (" · " + rarity.to_upper() if rarity != "" else "")


# --- Middle menu ----------------------------------------------------------------------------------------------------

func _open_menu(piece: Dictionary) -> void:
	if _selected == null:
		return
	_picked = piece
	_describe_piece(piece)
	var me: int = _selected["member"]
	var column: GearColumn = _selected["column"]
	var mine: bool = piece["holder"] == me and (not piece["use"] or piece["index"] == column.use_slot)
	var current := _piece_in(_selected)
	%Where.text = "%s · %s" % [_member_name(ctx.run.state.member(me)).to_upper(), column.title]
	%PieceName.text = _display_name(piece["id"])
	if piece["use"]:
		# Spec keys-and-gear 2.5: another member's use item moves here (MOVE HERE) or trades places (SWAP).
		var other: bool = piece["holder"] > 0 and piece["holder"] != me
		if other:
			%Effect.text = swap_format % [_member_name(ctx.run.state.member(piece["holder"])),
				_display_name(current) if current != &"" else nothing_text]
		else:
			%Effect.text = mine_text % _member_name(ctx.run.state.member(me))
		%Equip.text = "SWAP" if current != &"" else move_text
		%Equip.disabled = not other
		%TakeOff.visible = false
	elif mine:
		%Effect.text = mine_text % _member_name(ctx.run.state.member(me))
		%Equip.text = "EQUIP"
		%Equip.disabled = true
		%TakeOff.visible = true
	elif piece["holder"] > 0:
		%Effect.text = swap_format % [_member_name(ctx.run.state.member(piece["holder"])),
			_display_name(current) if current != &"" else nothing_text]
		%Equip.text = "SWAP"
		%Equip.disabled = false
		%TakeOff.visible = false
	else:
		%Effect.text = to_bag_format % _display_name(current) if current != &"" else empty_slot_text
		%Equip.text = "EQUIP"
		%Equip.disabled = false
		%TakeOff.visible = false
	%Dim.visible = true
	%Menu.visible = true


func _close_menu() -> void:
	_picked = {}
	%Dim.visible = false
	%Menu.visible = false
	_redraw()


func _on_equip() -> void:
	if _picked.is_empty() or _selected == null:
		return
	var run := ctx.run
	var me: int = _selected["member"]
	var problem := ""
	if _picked["use"]:
		# Spec keys-and-gear 2.5: one logged move (or swap with what this slot holds), checked before anything changes.
		problem = run.move_item(_picked["holder"], _picked["id"], me, _piece_in(_selected))
	elif _picked["holder"] > 0:
		# Spec keys-and-gear 2.4: one logged swap; the wearer gets my old piece (or nothing) back.
		problem = run.swap_gear(me, _picked["id"])
	else:
		problem = run.equip(me, _picked["id"])
	_after(problem)


func _on_take_off() -> void:
	if _selected == null:
		return
	_after(ctx.run.unequip(_selected["member"], _selected["column"].slot))


func _after(problem: String) -> void:
	if problem != "":
		ctx.main.refuse(problem)
	else:
		get_tree().call_group("sound_board", "play", "Item")
	_close_menu()
	refresh()


# --- Data -----------------------------------------------------------------------------------------------------------

func _piece_in(slot: Variant) -> StringName:
	if slot == null:
		return &""
	var member := ctx.run.state.member(slot["member"])
	if member.is_empty():
		return &""
	var column: GearColumn = slot["column"]
	if column.is_use_slot():
		var index := column.use_slot - 1
		return member["use_slots"][index]["item"] if index < member["use_slots"].size() else &""
	return member["equipment"].get(column.slot, &"")


func _locked(slot: Variant) -> bool:
	return slot != null and slot["column"].is_use_slot() and ctx.run.use_capacity(slot["member"]) < slot["column"].use_slot


func _definition(id: StringName) -> Resource:
	var piece: Resource = ctx.run.content.equipment.get(id)
	return piece if piece != null else ctx.run.content.items.get(id)


func _display_name(id: StringName) -> String:
	var definition := _definition(id)
	return definition.display_name if definition != null else String(id)


func _rarity(definition: Resource) -> String:
	if definition == null:
		return ""
	for tag in definition.tags:
		if String(tag).begins_with("Item.Rarity."):
			return String(tag).trim_prefix("Item.Rarity.")
	return ""


func _member_name(member: Dictionary) -> String:
	if member.is_empty():
		return "?"
	var character: UnitDefinition = ctx.run.content.units.get(member["character"])
	return character.display_name if character != null else String(member["character"])
