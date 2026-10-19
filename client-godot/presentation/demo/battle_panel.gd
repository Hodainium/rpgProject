## Demo battle panel (placeholder): HP/MP/ult charge of every unit, the acting unit's abilities and usable items
## (disabled when their cost or tags fail), target buttons (dead allies for revives), Skip and Auto toggles.
extends Control

var _main: GameMain
var _recorder: ActionRecorder
var _gate: ViewGate
var _battle: Battle
var _stats: Label
var _turn: Label
var _actions: HFlowContainer
var _skip: CheckBox
var _auto: CheckBox


func setup(main: GameMain) -> void:
	_main = main
	set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	offset_top = -220
	offset_bottom = -32
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(panel)
	var columns := HBoxContainer.new()
	panel.add_child(columns)
	_stats = Label.new()
	_stats.custom_minimum_size = Vector2(380, 0)
	columns.add_child(_stats)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	columns.add_child(right)
	var toggles := HBoxContainer.new()
	_turn = Label.new()
	_turn.size_flags_horizontal = SIZE_EXPAND_FILL
	toggles.add_child(_turn)
	_skip = CheckBox.new()
	_skip.text = "Skip animations"
	_skip.toggled.connect(_on_skip_toggled)
	toggles.add_child(_skip)
	_auto = CheckBox.new()
	_auto.text = "Auto"
	toggles.add_child(_auto)
	right.add_child(toggles)
	_actions = HFlowContainer.new()
	_actions.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(_actions)
	main.run_changed.connect(_bind)
	main.battle_prepared.connect(_on_battle_prepared)
	main.mode_changed.connect(func(_mode): _update_visible())
	visible = false


func _on_skip_toggled(on: bool) -> void:
	if _gate != null:
		_gate.skip_all = on


func _bind(run: RunController) -> void:
	run.battle_started.connect(_on_battle_started)
	run.battle_finished.connect(_on_battle_finished)


func _on_battle_prepared(recorder: ActionRecorder, gate: ViewGate) -> void:
	_recorder = recorder
	_gate = gate
	_gate.skip_all = _skip.button_pressed
	_recorder.action_requested.connect(_on_action_requested)
	_recorder.action_rejected.connect(func(_id, reason, detail): _main.show_message("%s: %s" % [reason, detail]))


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	battle.execution_resolved.connect(func(_u, _r, _t): _refresh_stats())
	battle.turn_started.connect(func(_u, _t): _refresh_stats())
	_refresh_stats()
	_update_visible()


func _on_battle_finished(outcome: String) -> void:
	_battle = null
	_clear_actions()
	_main.show_message("Battle: " + outcome)
	_update_visible()


func _update_visible() -> void:
	visible = _battle != null and _main.mode == "run"


func _on_action_requested(unit_id: StringName, turn: int) -> void:
	var unit := _battle.unit_by_id(unit_id)
	_turn.text = "Turn %d: %s" % [turn, _name(unit)]
	_refresh_stats()
	if _auto.button_pressed:
		_auto_pick.call_deferred(unit)
		return
	_show_abilities(unit)


func _show_abilities(unit: BattleUnit) -> void:
	_clear_actions()
	for ability in unit.action_abilities():
		var button := Button.new()
		var label := String(ability.ability_tag).get_slice(".", String(ability.ability_tag).get_slice_count(".") - 1)
		if unit.item_abilities.has(ability.ability_tag):
			label += " [item]"
		button.text = label
		button.disabled = not unit.asc.can_activate_ability(ability)
		button.pressed.connect(_on_ability_pressed.bind(unit, ability))
		_actions.add_child(button)


func _on_ability_pressed(unit: BattleUnit, ability: BattleAbility) -> void:
	if not ability.needs_target():
		_submit(ability, &"")
		return
	_clear_actions()
	for target in _battle.target_candidates(unit, ability):
		var button := Button.new()
		button.text = "-> " + _name(target) + (" (dead)" if not target.alive else "")
		button.pressed.connect(_submit.bind(ability, target.unit_id))
		_actions.add_child(button)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_abilities.bind(unit))
	_actions.add_child(back)


func _submit(ability: BattleAbility, target_id: StringName) -> void:
	_clear_actions()
	_recorder.submit_action(ability.ability_tag, target_id)


## Auto: the first usable ability on the first valid target (for watching several battles in a row).
func _auto_pick(unit: BattleUnit) -> void:
	for ability in unit.action_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		if not ability.needs_target():
			_submit(ability, &"")
			return
		var targets := _battle.target_candidates(unit, ability)
		if not targets.is_empty():
			_submit(ability, targets[0].unit_id)
			return
	_show_abilities(unit)


func _refresh_stats() -> void:
	if _battle == null:
		return
	var lines := PackedStringArray()
	for unit in _battle.units():
		var line := "%s %-10s HP %d/%d" % [unit.unit_id, _name(unit), unit.stat(BattleUnit.HP) / 100,
			unit.stat(BattleUnit.MAX_HP) / 100]
		if unit.asc.has_attribute(BattleUnit.MP):
			line += "  MP %d" % (unit.stat(BattleUnit.MP) / 100)
		if unit.asc.has_attribute(BattleUnit.ENERGY):
			line += "  Ult %d" % (unit.stat(BattleUnit.ENERGY) / 100)
		if not unit.alive:
			line += "  (dead)"
		lines.append(line)
	_stats.text = "\n".join(lines)


func _clear_actions() -> void:
	for child in _actions.get_children():
		child.queue_free()


func _name(unit: BattleUnit) -> String:
	if unit == null or unit.definition == null:
		return "?"
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
