## HUD panel (UI.Slot.Hud.Bottom while UI.State.Run.Battle): HP/MP/ult charge, toughness, affinities and statuses
## of every unit; the acting unit's abilities and usable items (disabled when their cost or tags fail), then targets
## (dead allies for revives); a row of ult buttons for every party member, pressable at any time (spec ult-interrupts:
## the press fires at the next ult window); Skip animations, Auto and the battle speed (presentation only: the gate
## still waits on each animation's execute keys, so replay is unaffected). Buttons are action_button entries.
## Defaults for speed and skip come from the Settings screen (user://game_main.cfg, [settings]).
extends UIScreen

## The speeds the speed button cycles through.
@export var speeds: Array[float] = [1.0, 2.0]
@export var speed_format: String = "%d×"
@export var target_format: String = "-> %s%s"
@export var dead_suffix: String = " (dead)"
@export var item_suffix: String = " [item]"
@export var ult_format: String = "ULT %s: %s"
@export var back_text: String = "Back"

var _recorder: ActionRecorder
var _gate: ViewGate
var _battle: Battle
## The party unit waiting for the player's pick, or null.
var _waiting: BattleUnit
## The ult whose target is being picked, or null.
var _aiming: BattleAbility
var _speed_index: int = 0


func bind(context: UIContext) -> void:
	%Skip.toggled.connect(func(on):
		if _gate != null:
			_gate.skip_all = on)
	%Auto.toggled.connect(_on_auto_toggled)
	%Speed.pressed.connect(_on_speed_pressed)
	context.main.battle_prepared.connect(_on_battle_prepared)
	context.on_run(self, &"battle_started", _on_battle_started)
	context.on_run(self, &"battle_finished", _on_battle_finished)
	%Skip.button_pressed = GameMain.load_setting("settings", "skip_animations", false)
	_speed_index = maxi(speeds.find(float(GameMain.load_setting("settings", "battle_speed", speeds[0]))), 0)
	_show_speed()
	# The panel is created after battle_prepared fired for this battle: take the battle's recorder and gate now.
	if context.main.recorder != null and context.main.gate != null:
		_on_battle_prepared(context.main.recorder, context.main.gate)


func on_deactivated() -> void:
	Engine.time_scale = 1.0


func _on_battle_prepared(recorder: ActionRecorder, gate: ViewGate) -> void:
	if recorder == _recorder:
		return
	_recorder = recorder
	_gate = gate
	if %Skip.button_pressed:
		_gate.skip_all = true  # never turns off a skip GameMain set (the script runner)
	_recorder.action_requested.connect(_on_action_requested)
	_recorder.action_rejected.connect(_on_action_rejected)
	if _recorder.waiting_for != &"" and _battle != null:
		_on_action_requested(_recorder.waiting_for, 0)


func _on_speed_pressed() -> void:
	_speed_index = (_speed_index + 1) % speeds.size()
	_show_speed()


func _show_speed() -> void:
	%Speed.text = speed_format % int(speeds[_speed_index])
	if _battle != null:
		Engine.time_scale = speeds[_speed_index]


## The battle refused the pick and waits for another one: show the choices again.
func _on_action_rejected(unit_id: StringName, reason: String, detail: String) -> void:
	ctx.main.refuse("%s: %s" % [reason, detail], unit_id, {"reason": reason, "detail": detail})
	_waiting = _battle.unit_by_id(unit_id)
	_show_abilities(_waiting)


## Turning Auto on also acts for the unit that is already waiting.
func _on_auto_toggled(on: bool) -> void:
	if on and _waiting != null and _battle != null:
		_auto_pick(_waiting)


func _on_battle_started(battle: Battle) -> void:
	_battle = battle
	Engine.time_scale = speeds[_speed_index]
	battle.execution_resolved.connect(func(_u, _r, _t): _refresh_stats())
	battle.turn_started.connect(func(_u, _t): _refresh_stats())
	# Spec item-pass: hit marks (crit / weak / break), Broken and recovery, One More.
	battle.damage_dealt.connect(_on_damage_dealt)
	battle.unit_broken.connect(func(_u, _by): _refresh_stats())
	battle.unit_recovered.connect(func(_u): _refresh_stats())
	battle.interrupt_started.connect(func(_u, _ability): _refresh_stats())
	# Spec content-pass: drains, delays, knock-downs. Call-outs (BROKEN!, ONE MORE!, phases…) are battle_callouts'.
	battle.damage_drained.connect(func(_source, target_id, amount):
		%Turn.text = "%s  drains %d" % [_name(_battle.unit_by_id(target_id)), amount / 100]
		_refresh_stats())
	battle.action_delayed.connect(func(_u, _p): _refresh_stats())
	battle.unit_downed.connect(func(_u, _by): _refresh_stats())
	_refresh_stats()


func _on_damage_dealt(_source: StringName, target_id: StringName, amount: int, hit_tags: Array[StringName]) -> void:
	var marks := PackedStringArray()
	for tag in [&"Hit.Critical", &"Hit.Weakness", &"Hit.Resisted", &"Hit.FollowUp"]:
		if hit_tags.has(tag):
			marks.append(String(tag).get_slice(".", 1).to_upper())
	if not marks.is_empty():
		%Turn.text = "%s  %d  %s" % [_name(_battle.unit_by_id(target_id)), amount / 100, " ".join(marks)]


func _on_battle_finished(_outcome: String) -> void:
	_battle = null
	_waiting = null
	_aiming = null
	Engine.time_scale = 1.0


func _on_action_requested(unit_id: StringName, turn: int) -> void:
	var unit := _battle.unit_by_id(unit_id)
	_waiting = unit
	if turn > 0:
		%Turn.text = "Turn %d: %s" % [turn, _name(unit)]
	_refresh_stats()
	if %Auto.button_pressed:
		_auto_pick.call_deferred(unit)
		return
	_show_abilities(unit)


func _show_abilities(unit: BattleUnit) -> void:
	var items: Array = []
	for ability in unit.action_abilities():
		items.append({"text": _short(ability.ability_tag) + (item_suffix if unit.item_abilities.has(ability.ability_tag) else ""),
			"disabled": not unit.asc.can_activate_ability(ability), "action": _on_ability_pressed.bind(unit, ability)})
	%Actions.set_items(items)


func _on_ability_pressed(unit: BattleUnit, ability: BattleAbility) -> void:
	if not ability.needs_target():
		_submit(ability, &"")
		return
	var items: Array = _battle.target_candidates(unit, ability).map(func(target: BattleUnit) -> Dictionary:
		return {"text": target_format % [_name(target), dead_suffix if not target.alive else ""],
			"action": _submit.bind(ability, target.unit_id)})
	items.append({"text": back_text, "sound": "back", "action": _show_abilities.bind(unit)})
	%Actions.set_items(items)


func _submit(ability: BattleAbility, target_id: StringName) -> void:
	_waiting = null
	%Actions.set_items([])
	_recorder.submit_action(ability.ability_tag, target_id)


## Auto: every ready ult first (they fire at once and the unit is asked again), then the first usable ability on the
## first valid target (for watching several battles in a row).
func _auto_pick(unit: BattleUnit) -> void:
	if _recorder == null or _recorder.waiting_for != unit.unit_id:
		return
	for member in _battle.units():
		if not member.is_party() or not member.alive:
			continue
		for ult in member.ultimate_abilities():
			var targets := _battle.target_candidates(member, ult)
			if member.asc.can_activate_ability(ult) and (not ult.needs_target() or not targets.is_empty()):
				_recorder.submit_ult(member.unit_id, ult.ability_tag, targets[0].unit_id if ult.needs_target() else &"")
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
	%Stats.text = "\n".join(lines)
	_refresh_ults()


## One button per party member's ult, lit when it can fire now. Pressing one queues it for the next ult window
## (single-target ults ask for a target first; the battle retargets if that target is gone by then).
func _refresh_ults() -> void:
	if _aiming != null:
		return
	var items: Array = []
	if _battle != null and _recorder != null:
		for unit in _battle.units():
			if not unit.is_party():
				continue
			for ult in unit.ultimate_abilities():
				items.append({"text": ult_format % [_name(unit), _short(ult.ability_tag)],
					"disabled": not unit.alive or not unit.asc.can_activate_ability(ult),
					"action": _on_ult_pressed.bind(unit, ult)})
	%Ults.set_items(items)


func _on_ult_pressed(unit: BattleUnit, ult: BattleAbility) -> void:
	if not ult.needs_target():
		_press_ult(unit, ult, &"")
		return
	_aiming = ult
	var items: Array = _battle.target_candidates(unit, ult).map(func(target: BattleUnit) -> Dictionary:
		return {"text": target_format % [_name(target), dead_suffix if not target.alive else ""],
			"action": _press_ult.bind(unit, ult, target.unit_id)})
	items.append({"text": back_text, "sound": "back", "action": func():
		_aiming = null
		_refresh_ults()})
	%Ults.set_items(items)


func _press_ult(unit: BattleUnit, ult: BattleAbility, target_id: StringName) -> void:
	_aiming = null
	_recorder.submit_ult(unit.unit_id, ult.ability_tag, target_id)
	if _recorder.pending_interrupts() > 0:
		ctx.main.show_message("%s: %s at the next chance" % [_name(unit), _short(ult.ability_tag)])
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


## The last segment of a tag: Ability.Ult.Execute → Execute.
static func _short(tag: StringName) -> String:
	return String(tag).get_slice(".", String(tag).get_slice_count(".") - 1)


func _name(unit: BattleUnit) -> String:
	if unit == null or unit.definition == null:
		return "?"
	return unit.definition.display_name if unit.definition.display_name != "" else String(unit.definition.id)
