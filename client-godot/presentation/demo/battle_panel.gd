## Demo battle panel (placeholder): HP/MP/ult charge of every unit, the acting unit's abilities and usable items
## (disabled when their cost or tags fail), target buttons (dead allies for revives), Skip and Auto toggles.
extends Control

var _main: GameMain
var _recorder: ActionRecorder
var _gate: ViewGate
var _battle: Battle
## The party unit waiting for the player's pick, or null.
var _waiting: BattleUnit

@onready var _stats: Label = %Stats
@onready var _turn: Label = %Turn
@onready var _actions: HFlowContainer = %Actions
@onready var _skip: CheckBox = %Skip
@onready var _auto: CheckBox = %Auto


func setup(main: GameMain) -> void:
	_main = main
	_skip.toggled.connect(_on_skip_toggled)
	_auto.toggled.connect(_on_auto_toggled)
	main.run_changed.connect(_bind)
	main.battle_prepared.connect(_on_battle_prepared)
	main.mode_changed.connect(func(_mode): _update_visible())
	visible = false


## The battle refused the pick and waits for another one: show the choices again.
func _on_action_rejected(unit_id: StringName, reason: String, detail: String) -> void:
	_main.show_message("%s: %s" % [reason, detail])
	_waiting = _battle.unit_by_id(unit_id)
	_show_abilities(_waiting)


## Turning Auto on also acts for the unit that is already waiting.
func _on_auto_toggled(on: bool) -> void:
	if on and _waiting != null and _battle != null:
		_auto_pick(_waiting)


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
	_recorder.action_rejected.connect(_on_action_rejected)


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	battle.execution_resolved.connect(func(_u, _r, _t): _refresh_stats())
	battle.turn_started.connect(func(_u, _t): _refresh_stats())
	_refresh_stats()
	_update_visible()


func _on_battle_finished(outcome: String) -> void:
	_battle = null
	_waiting = null
	_clear_actions()
	_main.show_message("Battle: " + outcome)
	_update_visible()


func _update_visible() -> void:
	visible = _battle != null and _main.mode == "run"


func _on_action_requested(unit_id: StringName, turn: int) -> void:
	var unit := _battle.unit_by_id(unit_id)
	_waiting = unit
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
	_waiting = null
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
