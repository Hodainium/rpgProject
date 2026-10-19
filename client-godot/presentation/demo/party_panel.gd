## Demo party panel (placeholder): each member's HP/MP/ult charge, dead marker, items, use slots with cooldowns,
## equipment, and the field abilities (spells and usable items) that work on the map right now.
extends Control

var _main: GameMain
var _members: VBoxContainer
var _field: HFlowContainer
var _busy: bool = false


func setup(main: GameMain) -> void:
	_main = main
	set_anchors_and_offsets_preset(PRESET_TOP_LEFT)
	position = Vector2(8, 8)
	var panel := PanelContainer.new()
	add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	panel.add_child(box)
	_members = VBoxContainer.new()
	box.add_child(_members)
	var field_title := Label.new()
	field_title.text = "On the map:"
	box.add_child(field_title)
	_field = HFlowContainer.new()
	box.add_child(_field)
	main.run_changed.connect(_bind)
	main.mode_changed.connect(func(_mode): _refresh())
	visible = false


func _bind(run: RunController) -> void:
	for changed in [run.party_changed, run.floor_entered, run.room_entered, run.room_cleared, run.battle_requested,
			run.battle_finished, run.event_page_shown]:
		changed.connect(func(_a = null, _b = null): _refresh.call_deferred())


func _refresh() -> void:
	var run := _main.run
	visible = run != null and run.state != null and _main.mode != "menu"
	if not visible:
		return
	for child in _members.get_children() + _field.get_children():
		child.queue_free()
	for member in run.state.party:
		var character: UnitDefinition = run.content.units.get(member["character"])
		var label := Label.new()
		var lines := PackedStringArray()
		lines.append("%d. %s%s   HP %d%s%s" % [member["slot"], character.display_name if character != null else member["character"],
			"  [DEAD]" if not member["alive"] else "", member["hp"] / 100,
			"  MP %d" % (member["mp"] / 100) if member["mp"] != null else "",
			"  Ult %d" % (member["energy"] / 100) if member["energy"] != null else ""])
		var held := PackedStringArray()
		for item_id in member["items"]:
			held.append(_item_name(item_id))
		for use_slot in member["use_slots"]:
			held.append("[%s%s]" % [_item_name(use_slot["item"]),
				" cd %d" % use_slot["cooldown"] if use_slot["cooldown"] > 0 else ""])
		for slot_tag in member["equipment"]:
			var piece: EquipmentDefinition = run.content.equipment.get(member["equipment"][slot_tag])
			held.append("<%s>" % (piece.display_name if piece != null else member["equipment"][slot_tag]))
		if not held.is_empty():
			lines.append("    " + ", ".join(held))
		label.text = "\n".join(lines)
		_members.add_child(label)
	if _busy or not run.pending_battle.is_empty() or not run.state.event.is_empty():
		return
	for option in run.field_options():
		var tag := String(option["ability"])
		var title := "%d: %s" % [option["slot"], tag.get_slice(".", tag.get_slice_count(".") - 1)]
		if option["item"] != &"":
			title += " [item]"
		if option["targets"].is_empty():
			_field.add_child(_button(title, option["slot"], option["ability"], 0))
		else:
			for target in option["targets"]:
				_field.add_child(_button("%s -> %d" % [title, target], option["slot"], option["ability"], target))


func _button(text: String, slot: int, ability: StringName, target: int) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(_use.bind(slot, ability, target))
	return button


func _use(slot: int, ability: StringName, target: int) -> void:
	_busy = true
	var problem: Array = await _main.run.use_field(slot, ability, target)
	_busy = false
	if not problem.is_empty():
		_main.show_message("%s: %s" % problem)
	_refresh()


func _item_name(item_id: StringName) -> String:
	var item: ItemDefinition = _main.run.content.items.get(item_id)
	return item.display_name if item != null else String(item_id)
