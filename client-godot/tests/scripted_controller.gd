## Test-only party controller: a fixed policy standing in for the player, recording the action log like
## ActionRecorder does. It never touches the battle RNG (the player's choices are inputs, not simulation).
##
## Policy: each unit rotates through its own abilities in grant order (so every ability gets used), skipping ones
## that can't activate; the target is picked by turn number among the valid candidates (slot order).
class_name ScriptedController
extends RefCounted

var entries: Array[Dictionary] = []
var _uses: Dictionary = {}  # unit id -> actions taken


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	var abilities := unit.abilities()
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


func after_party_turn(battle: Battle, unit: BattleUnit, action: Dictionary, checkpoint: String) -> void:
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, checkpoint))
