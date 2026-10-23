## Test-only party controller: a fixed policy standing in for the player, recording the action log like
## ActionRecorder does. It never touches the battle RNG (the player's choices are inputs, not simulation).
##
## Policy: each unit rotates through its own abilities in grant order (so every ability gets used), skipping ones
## that can't activate; the target is picked by turn number among the valid candidates (slot order).
## Ults (spec ult-interrupts): a party unit whose ult can activate casts it, units in odd slots at the BETWEEN window and
## units in even slots at a DECISION window (any member's), so one battle covers both; each unit cycles its ults.
class_name ScriptedController
extends RefCounted

var entries: Array[Dictionary] = []
var _uses: Dictionary = {}  # unit id -> actions taken
var _ult_uses: Dictionary = {}  # unit id -> ults cast


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	var ult := _ready_ult(battle, 0)
	if not ult.is_empty():
		return ult
	var abilities := unit.action_abilities()
	var used: int = _uses.get(unit.unit_id, 0)
	_uses[unit.unit_id] = used + 1
	for offset in abilities.size():
		var ability := abilities[(used + offset) % abilities.size()]
		if not unit.asc.can_activate_ability(ability):
			continue
		var target: StringName = &""
		if ability.needs_target():
			var candidates := battle.target_candidates(unit, ability)
			if candidates.is_empty():
				continue
			target = candidates[battle.turn % candidates.size()].unit_id
		return {"ability": ability.ability_tag, "target": target}
	return {"ability": &"", "target": &""}


func on_invalid(_battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	push_error("ScriptedController chose an invalid action for %s: %s %s" % [unit.unit_id, reason, detail])
	return false


func after_party_turn(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, battle.extra_action))


func interrupt(battle: Battle) -> Dictionary:
	return _ready_ult(battle, 1)


func after_interrupt(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, false, true))


## The first living party unit (slot order, slot % 2 == parity) with an ult that can fire now, as an interrupt choice.
func _ready_ult(battle: Battle, parity: int) -> Dictionary:
	var party: Array[BattleUnit] = []
	for unit in battle.units():
		if unit.is_party() and unit.alive and unit.slot % 2 == parity:
			party.append(unit)
	party.sort_custom(func(a: BattleUnit, b: BattleUnit) -> bool: return a.slot < b.slot)
	for unit in party:
		var ults := unit.ultimate_abilities()
		var used: int = _ult_uses.get(unit.unit_id, 0)
		for offset in ults.size():
			var ability := ults[(used + offset) % ults.size()]
			if not unit.asc.can_activate_ability(ability):
				continue
			var target: StringName = &""
			if ability.needs_target():
				var candidates := battle.target_candidates(unit, ability)
				if candidates.is_empty():
					continue
				target = candidates[battle.turn % candidates.size()].unit_id
			_ult_uses[unit.unit_id] = used + 1
			return {"interrupt": true, "unit": unit.unit_id, "ability": ability.ability_tag, "target": target}
	return {}
