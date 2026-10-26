## Demo battle panel (placeholder): HP/MP/ult charge of every unit, the acting unit's abilities and usable items
## (disabled when their cost or tags fail), target buttons (dead allies for revives), Skip and Auto toggles.
## Spec ult-interrupts: a row of ult buttons for every party member, lit when its charge is full and pressable at any
## time (even during enemy turns): the press fires at the next ult window. Auto presses ready ults too.
extends Control

var _main: GameMain
var _recorder: ActionRecorder
var _gate: ViewGate
var _battle: Battle
## The party unit waiting for the player's pick, or null.
var _waiting: BattleUnit
## Ult buttons (built in code, under the action row) and the ult whose target is being picked.
var _ults: HFlowContainer
var _aiming: BattleAbility

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
	_ults = HFlowContainer.new()
	_ults.name = "Ults"
	_actions.add_sibling(_ults)
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
	# Spec item-pass: hit marks (crit / weak / break), Broken and recovery, One More.
	battle.damage_dealt.connect(_on_damage_dealt)
	battle.unit_broken.connect(func(unit_id, _by): _main.show_message("%s is BROKEN!" % _name(_battle.unit_by_id(unit_id))))
	battle.unit_recovered.connect(func(_u): _refresh_stats())
	battle.one_more_started.connect(func(unit_id): _main.show_message("ONE MORE! %s acts again" % _name(_battle.unit_by_id(unit_id))))
	battle.interrupt_started.connect(_on_interrupt_started)
	# Spec content-pass: skipped turns, resisted statuses, drains, boss phases, delays.
	battle.turn_skipped.connect(func(unit_id): _main.show_message("%s can't act and loses the turn" % _name(_battle.unit_by_id(unit_id))))
	battle.status_resisted.connect(func(_source, target_id, effect_path):
		_main.show_message("%s resisted %s" % [_name(_battle.unit_by_id(target_id)), String(effect_path).get_file().get_basename().capitalize()]))
	battle.damage_drained.connect(func(_source, target_id, amount):
		_turn.text = "%s  drains %d" % [_name(_battle.unit_by_id(target_id)), amount / 100]
		_refresh_stats())
	battle.phase_changed.connect(func(unit_id, phase): _main.show_message("%s enters phase %d!" % [_name(_battle.unit_by_id(unit_id)), phase + 1]))
	battle.action_delayed.connect(func(_u, _p): _refresh_stats())
	battle.unit_downed.connect(func(unit_id, _by):
		_main.show_message("%s is KNOCKED DOWN!" % _name(_battle.unit_by_id(unit_id)))
		_refresh_stats())
	_refresh_stats()
	_update_visible()


func _on_interrupt_started(unit_id: StringName, ability_tag: StringName) -> void:
	_main.show_message("%s unleashes %s!" % [_name(_battle.unit_by_id(unit_id)), _short(ability_tag)])
	_refresh_stats()


func _on_damage_dealt(_source: StringName, target_id: StringName, amount: int, hit_tags: Array[StringName]) -> void:
	var marks := PackedStringArray()
	for tag in [&"Hit.Critical", &"Hit.Weakness", &"Hit.Resisted", &"Hit.FollowUp"]:
		if hit_tags.has(tag):
			marks.append(String(tag).get_slice(".", 1).to_upper())
	if not marks.is_empty():
		_turn.text = "%s  %d  %s" % [_name(_battle.unit_by_id(target_id)), amount / 100, " ".join(marks)]


func _on_battle_finished(outcome: String) -> void:
	_battle = null
	_waiting = null
	_aiming = null
	_clear_actions()
	_refresh_ults()
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
	back.set_meta("sound", "back")
	back.pressed.connect(_show_abilities.bind(unit))
	_actions.add_child(back)


func _submit(ability: BattleAbility, target_id: StringName) -> void:
	_waiting = null
	_clear_actions()
	_recorder.submit_action(ability.ability_tag, target_id)


## Auto: every ready ult first (they fire at once and the unit is asked again), then the first usable ability on the
## first valid target (for watching several battles in a row).
func _auto_pick(unit: BattleUnit) -> void:
	if _recorder.waiting_for != unit.unit_id:
		return
	var pressed := false
	for member in _battle.units():
		if not member.is_party() or not member.alive:
			continue
		for ult in member.ultimate_abilities():
			var targets := _battle.target_candidates(member, ult)
			if member.asc.can_activate_ability(ult) and (not ult.needs_target() or not targets.is_empty()):
				_recorder.submit_ult(member.unit_id, ult.ability_tag, targets[0].unit_id if ult.needs_target() else &"")
				pressed = true
				break
	if pressed:
		return
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
		line += _toughness_text(unit)
		if not unit.alive:
			line += "  (dead)"
		lines.append(line)
	_stats.text = "\n".join(lines)
	_refresh_ults()


## One button per party member's ult, lit when it can fire now. Pressing one queues it for the next ult window
## (single-target ults ask for a target first; the battle retargets if that target is gone by then).
func _refresh_ults() -> void:
	if _ults == null or _aiming != null:
		return
	for child in _ults.get_children():
		child.queue_free()
	if _battle == null or _recorder == null:
		return
	for unit in _battle.units():
		if not unit.is_party():
			continue
		for ult in unit.ultimate_abilities():
			var button := Button.new()
			button.text = "ULT %s: %s" % [_name(unit), _short(ult.ability_tag)]
			button.disabled = not unit.alive or not unit.asc.can_activate_ability(ult)
			button.pressed.connect(_on_ult_pressed.bind(unit, ult))
			_ults.add_child(button)


func _on_ult_pressed(unit: BattleUnit, ult: BattleAbility) -> void:
	if not ult.needs_target():
		_press_ult(unit, ult, &"")
		return
	_aiming = ult
	for child in _ults.get_children():
		child.queue_free()
	for target in _battle.target_candidates(unit, ult):
		var button := Button.new()
		button.text = "-> " + _name(target) + (" (dead)" if not target.alive else "")
		button.pressed.connect(_press_ult.bind(unit, ult, target.unit_id))
		_ults.add_child(button)
	var back := Button.new()
	back.text = "Back"
	back.set_meta("sound", "back")
	back.pressed.connect(func():
		_aiming = null
		_refresh_ults())
	_ults.add_child(back)


func _press_ult(unit: BattleUnit, ult: BattleAbility, target_id: StringName) -> void:
	_aiming = null
	_recorder.submit_ult(unit.unit_id, ult.ability_tag, target_id)
	if _recorder.pending_interrupts() > 0:
		_main.show_message("%s: %s at the next chance" % [_name(unit), _short(ult.ability_tag)])
	_refresh_ults()


## Toughness bar (hidden when max_toughness is 0), BROKEN, and the unit's current weaknesses (read from its tags, so a
## timed weakness shows and vanishes): "  [####--] 40/60  weak Fire".
func _toughness_text(unit: BattleUnit) -> String:
	var text := ""
	var maximum := unit.stat(Battle.MAX_TOUGHNESS)
	if maximum > 0:
		var filled := unit.stat(Battle.TOUGHNESS) * 6 / maximum
		text += "  [%s%s] %d/%d" % ["#".repeat(filled), "-".repeat(6 - filled), unit.stat(Battle.TOUGHNESS) / 100, maximum / 100]
	if unit.asc.has_tag_exact(Battle.BROKEN_TAG):
		text += "  BROKEN"
	if unit.asc.has_tag_exact(Battle.DOWNED_TAG):
		text += "  KNOCKED DOWN"
	# Spec content-pass: affinities (weak, resist, drain) and active statuses with turns and stacks.
	for affinity in [["Weakness.", "weak"], ["Resist.", "resist"], ["Drain.", "drain"]]:
		var types := PackedStringArray()
		for tag in unit.asc._active_tags:
			if String(tag).begins_with(affinity[0]):
				types.append(String(tag).get_slice(".", 1))
		types.sort()
		if not types.is_empty():
			text += "  %s %s" % [affinity[1], ", ".join(types)]
	var statuses := PackedStringArray()
	for status in unit.statuses():
		var label := _short(StringName(status["tag"]))
		if int(status["stacks"]) > 1:
			label += "×%d" % status["stacks"]
		if int(status["turns"]) >= 0:
			label += " %d" % status["turns"]
		statuses.append(label)
	if not statuses.is_empty():
		text += "  [" + " · ".join(statuses) + "]"
	return text


func _clear_actions() -> void:
	for child in _actions.get_children():
		child.queue_free()


## The last segment of a tag: Ability.Ult.Execute → Execute.
static func _short(tag: StringName) -> String:
	return String(tag).get_slice(".", String(tag).get_slice_count(".") - 1)


func _name(unit: BattleUnit) -> String:
	if unit == null or unit.definition == null:
		return "?"
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
