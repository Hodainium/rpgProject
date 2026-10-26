## Demo party panel (placeholder): each member's HP/MP/ult charge, dead marker, items, use slots with cooldowns,
## equipment, and the field abilities (spells and usable items) that work on the map right now.
extends Control

var _main: GameMain
var _busy: bool = false
var _battle: Battle
## Spec playable-demo 3.11: each member's level when the party last entered a room (slot -> level); a higher level
## now shows LEVEL UP! until the next room.
var _seen_levels: Dictionary = {}

@onready var _members: VBoxContainer = %Members
@onready var _field: HFlowContainer = %Field


func setup(main: GameMain) -> void:
	_main = main
	main.run_changed.connect(_bind)
	main.mode_changed.connect(func(_mode): _refresh())
	visible = false


func _bind(run: RunController) -> void:
	for changed in [run.party_changed, run.floor_entered, run.room_entered, run.room_cleared, run.battle_requested,
			run.battle_finished, run.event_page_shown]:
		changed.connect(func(_a = null, _b = null): _refresh.call_deferred())
	run.battle_started.connect(_on_battle_started)
	run.battle_finished.connect(func(_outcome): _battle = null)
	_seen_levels.clear()
	for changed in [run.room_entered, run.floor_entered]:
		changed.connect(func(_a = null): _see_levels())


func _see_levels() -> void:
	for member in _main.run.state.party:
		_seen_levels[member["slot"]] = int(member["level"])


## "  Lv 3 · XP 180/270" (just "Lv 3" without an XP curve, "XP 2700 (max)" at the top level); "LEVEL UP!" after a rise.
func _level_text(run: RunController, member: Dictionary) -> String:
	var level := int(member["level"])
	if not _seen_levels.has(member["slot"]):
		_seen_levels[member["slot"]] = level
	var text := "  Lv %d" % level
	var curve: Array[int] = run.structure.xp_to_level if run.structure != null else []
	if not curve.is_empty():
		text += " · XP %d/%d" % [member.get("xp", 0), curve[level - 1]] if level - 1 < curve.size() \
			else " · XP %d (max)" % member.get("xp", 0)
	if level > _seen_levels[member["slot"]]:
		text += "  LEVEL UP!"
	return text


## During a battle the panel shows the fighting units' live values, updated after every action.
func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	battle.turn_started.connect(func(_unit, _turn): _refresh.call_deferred())
	battle.execution_resolved.connect(func(_unit, _row, _targets): _refresh.call_deferred())
	_refresh.call_deferred()


func _refresh() -> void:
	var run := _main.run
	visible = run != null and run.state != null and _main.mode != "menu"
	if not visible:
		return
	for child in _members.get_children() + _field.get_children():
		child.queue_free()
	var battle := _battle if is_instance_valid(_battle) else null
	var stats := run.party_stats() if battle == null else {}
	for member in run.state.party:
		var character: UnitDefinition = run.content.units.get(member["character"])
		var unit := battle.unit_by_id(StringName("P%d" % member["slot"])) if battle != null else null
		var values: Dictionary = RunController.unit_stats(unit) if unit != null else stats.get(member["slot"], {})
		var alive: bool = unit.alive if unit != null else member["alive"]
		var label := Label.new()
		var lines := PackedStringArray()
		lines.append("%d. %s%s%s" % [member["slot"], character.display_name if character != null else member["character"],
			_level_text(run, member), "  [DEAD]" if not alive else ""])
		var bars := "%s%s%s" % [_pair("HP", values, BattleUnit.HP, BattleUnit.MAX_HP),
			_pair("  MP", values, BattleUnit.MP, BattleUnit.MAX_MP),
			_pair("  Ult", values, BattleUnit.ENERGY, BattleUnit.MAX_ENERGY)]
		if bars != "":
			lines.append("    " + bars)
		var held := PackedStringArray()
		var tips := PackedStringArray()
		for item_id in member["items"]:
			held.append(_item_name(item_id))
			tips.append(_item_tip(item_id))
		for use_slot in member["use_slots"]:
			held.append("[%s%s]" % [_item_name(use_slot["item"]),
				" cd %d" % use_slot["cooldown"] if use_slot["cooldown"] > 0 else ""])
			tips.append(_item_tip(use_slot["item"]))
		if not held.is_empty():
			lines.append("    " + ", ".join(held))
		# Spec item-pass 3.5: every equipment slot of the run, filled or empty.
		var gear := PackedStringArray()
		for slot_tag in run.equipment_slots():
			var piece: EquipmentDefinition = run.content.equipment.get(member["equipment"].get(slot_tag, &""))
			gear.append("%s: %s" % [String(slot_tag).get_slice(".", 2), piece.display_name if piece != null else "-"])
			if piece != null and piece.description != "":
				tips.append("%s: %s" % [piece.display_name, piece.description])
		if not gear.is_empty():
			lines.append("    " + ", ".join(gear))
		label.text = "\n".join(lines)
		label.tooltip_text = "\n".join(tips)
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		_members.add_child(label)
	if _busy or not run.pending_battle.is_empty() or not run.state.event.is_empty() or _main.mode != "run":
		return  # armor and field actions only on the map, never on the end screen
	_armor_controls(run)
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


## "HP 669/1000" (values are ×100); just the current value when the set has no maximum; "" when absent.
static func _pair(title: String, values: Dictionary, current: String, maximum: String) -> String:
	if not values.has(current):
		return ""
	if not values.has(maximum):
		return "%s %d" % [title, values[current] / 100]
	return "%s %d/%d" % [title, values[current] / 100, values[maximum] / 100]


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


func _item_tip(item_id: StringName) -> String:
	var item: ItemDefinition = _main.run.content.items.get(item_id)
	return "%s: %s" % [item.display_name, item.description] if item != null and item.description != "" else ""


## Map only (spec item-pass 3.5): Unequip per worn piece, and the armor inventory with a member picker and Equip.
## Same calls as the console's `unwear` / `wear`.
func _armor_controls(run: RunController) -> void:
	var worn := HFlowContainer.new()
	for member in run.state.party:
		for slot_tag in run.equipment_slots():
			var piece: EquipmentDefinition = run.content.equipment.get(member["equipment"].get(slot_tag, &""))
			if piece == null:
				continue
			var off := Button.new()
			off.text = "%d: take off %s" % [member["slot"], piece.display_name]
			off.pressed.connect(func(): _after_armor(run.unequip(member["slot"], slot_tag)))
			worn.add_child(off)
	if worn.get_child_count() > 0:
		_members.add_child(worn)
	else:
		worn.free()
	if not run.state.armor.is_empty():
		var heading := Label.new()
		heading.text = "Armor bag (not worn):"
		_members.add_child(heading)
	for piece_id in run.state.armor:
		var piece: EquipmentDefinition = run.content.equipment.get(piece_id)
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "Armor: %s (%s)" % [piece.display_name if piece != null else String(piece_id),
			String(piece.slot).get_slice(".", 2) if piece != null else "?"]
		label.tooltip_text = piece.description if piece != null else ""
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		row.add_child(label)
		var picker := OptionButton.new()
		for member in run.state.party:
			var character: UnitDefinition = run.content.units.get(member["character"])
			picker.add_item(character.display_name if character != null else String(member["character"]), member["slot"])
		row.add_child(picker)
		var wear := Button.new()
		wear.text = "Equip"
		wear.pressed.connect(func(): _after_armor(run.equip(picker.get_item_id(picker.selected), piece_id)))
		row.add_child(wear)
		_members.add_child(row)


func _after_armor(problem: String) -> void:
	if problem != "":
		_main.show_message(problem)
	get_tree().call_group("sound_board", "play", "Refused" if problem != "" else "Item")
	_refresh()
