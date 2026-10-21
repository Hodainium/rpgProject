## Client-mode controller: waits for the player's decisions from presentation and records the action log
## (spec "Client mode (record)").
##
## Presentation calls submit_action(ability_tag, target_id) when the player picks; an illegal pick emits
## action_rejected and the battle waits for another. After the battle, action_log() is the ActionLog JSON shape
## to submit for verification.
class_name ActionRecorder
extends RefCounted

signal action_requested(unit_id: StringName, turn: int)
signal action_rejected(unit_id: StringName, reason: String, detail: String)
signal _submitted

var entries: Array[Dictionary] = []
## The unit whose decision is awaited (&"" while no party decision is pending).
var waiting_for: StringName = &""
var _pending: Dictionary = {}
var _dev: Array[Dictionary] = []


## Called by presentation with the player's choice. target_id is &"" for SELF / ALL_* abilities.
func submit_action(ability_tag: StringName, target_id: StringName = &"") -> void:
	_pending = {"ability": ability_tag, "target": target_id}
	_submitted.emit()


## A dev decision (spec dev-tools 3.6): `name` is Dev.Kill or Dev.Heal, `effect` the GameplayEffect to apply, `targets`
## "enemies", "party" or a party slot. Taken at the next party decision; Battle applies it only with allow_dev.
func submit_dev(name: StringName, effect: GameplayEffect, targets: String) -> void:
	_dev.append({"dev": name, "effect": effect, "targets": targets})
	_submitted.emit()


## Dev decisions not taken yet (dropped by the caller when the battle ends first).
func pending_dev() -> int:
	return _dev.size()


func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	_pending = {}
	if not _dev.is_empty():
		return _dev.pop_front()
	waiting_for = unit.unit_id
	action_requested.emit(unit.unit_id, battle.turn)
	while _pending.is_empty() and _dev.is_empty():
		await _submitted
	waiting_for = &""
	return _pending if not _pending.is_empty() else _dev.pop_front()


func on_invalid(_battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	action_rejected.emit(unit.unit_id, reason, detail)
	return true


func after_party_turn(battle: Battle, unit: BattleUnit, action: Dictionary, checkpoint: String) -> void:
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, checkpoint, battle.extra_action))


## The ActionLog JSON shape (Rpg.Contracts.Battle.ActionLog), field order matching the C# record.
func action_log(battle: Battle) -> Dictionary:
	return ActionRecorder.build_log(entries, battle.outcome, battle.final_hash)


## `extra`: a One More action (spec item-pass 3.2). The key is written only then, so other logs are unchanged.
static func entry(turn: int, unit_id: StringName, action: Dictionary, checkpoint: String, extra: bool = false) -> Dictionary:
	var target := StringName(str(action.get("target", "")))
	var result := {
		"turn": turn,
		"actor": String(unit_id),
		"ability": String(action["ability"]),
		"target": null if target == &"" else String(target),
		"checkpoint": checkpoint,
	}
	if extra:
		result["extra"] = true
	return result


static func build_log(log_entries: Array[Dictionary], outcome: String, final_hash: String) -> Dictionary:
	return {
		"schemaVersion": 1,
		"actions": log_entries,
		"claimedOutcome": outcome,
		"claimedFinalHash": final_hash,
	}
