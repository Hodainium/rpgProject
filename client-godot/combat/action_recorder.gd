## Client-mode controller: waits for the player's decisions from presentation and records the action log
## (spec "Client mode (record)").
##
## Presentation calls submit_action(ability_tag, target_id) when the player picks; an illegal pick emits
## action_rejected and the battle waits for another. After the battle, action_log() is the ActionLog JSON shape
## to submit for verification.
##
## Ults (spec ult-interrupts): presentation calls submit_ult(unit_id, ability_tag, target_id) at any time. The press
## waits in a FIFO queue and fires at the next ult window: at once if a party member is choosing (DECISION), else
## after the current action (BETWEEN). A press whose target is gone by then is retargeted; one that can't fire any
## more (caster dead, charge spent, no target) emits action_rejected and is dropped, never logged.
##
## Auto (spec auto-battle): with an `autopilot` set, the recorder asks it instead of waiting for the player, after any
## queued dev decision or ult press. Its picks are logged like manual ones; `auto_picks` counts them (never logged).
class_name ActionRecorder
extends RefCounted

signal action_requested(unit_id: StringName, turn: int)
signal action_rejected(unit_id: StringName, reason: String, detail: String)
signal _submitted

## An autopilot refused this many times in a row hands the decision to the player.
const AUTO_REFUSALS: int = 2

var entries: Array[Dictionary] = []
## The unit whose decision is awaited (&"" while no party decision is pending).
var waiting_for: StringName = &""
## Spec auto-battle: any object with choose(battle, unit), interrupt(battle) and on_invalid(...) (AutoPolicy); null =
## the player decides. Setting it wakes a decision that is already waiting.
var autopilot: Object = null:
	set(value):
		autopilot = value
		_auto_refusals = 0
		_submitted.emit()
## Accepted autopilot choices this battle (spec auto-battle A5: an analytics hint, never in entries or a hash).
var auto_picks: int = 0
var _pending: Dictionary = {}
var _dev: Array[Dictionary] = []
var _interrupts: Array[Dictionary] = []
var _from_auto: bool = false
var _auto_refusals: int = 0


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


## The player pressed `unit_id`'s ult (target_id &"" for SELF / ALL_* ults). Queued until the next ult window.
func submit_ult(unit_id: StringName, ability_tag: StringName, target_id: StringName = &"") -> void:
	_interrupts.append({"unit": unit_id, "ability": ability_tag, "target": target_id})
	_submitted.emit()


## Ult presses not fired yet (dropped when the battle ends first).
func pending_interrupts() -> int:
	return _interrupts.size()


## BETWEEN window: the next queued press that can fire now, else (Auto) the autopilot's ult, or {}. Never waits.
func interrupt(battle: Battle) -> Dictionary:
	_from_auto = false
	while not _interrupts.is_empty():
		var press: Dictionary = _interrupts.pop_front()
		var resolved := battle.resolve_press(press)
		if resolved.has("choice"):
			return resolved["choice"]
		action_rejected.emit(press["unit"], resolved["problem"][0], resolved["problem"][1])
	if _auto_on():
		var ult: Dictionary = autopilot.interrupt(battle)
		_from_auto = not ult.is_empty()
		return ult
	return {}


## A party member's decision. Queued ult presses go first (DECISION window), then the autopilot; a press while waiting
## wakes it too, and so does turning Auto on.
func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
	while true:
		_pending = {}
		if not _dev.is_empty():
			_from_auto = false
			return _dev.pop_front()
		var queued := interrupt(battle)
		if not queued.is_empty():
			return queued
		if _auto_on():
			var pick: Dictionary = autopilot.choose(battle, unit)
			if not pick.is_empty():
				_from_auto = true
				return pick
			_auto_refusals = AUTO_REFUSALS  # nothing legal: the player decides this one
		waiting_for = unit.unit_id
		action_requested.emit(unit.unit_id, battle.turn)
		while _pending.is_empty() and _dev.is_empty() and _interrupts.is_empty() and not _auto_on():
			await _submitted
		waiting_for = &""
		if not _pending.is_empty():
			_from_auto = false
			return _pending
	return {}


func on_invalid(battle: Battle, unit: BattleUnit, reason: String, detail: String) -> bool:
	if _from_auto:
		_from_auto = false
		_auto_refusals += 1
		return autopilot.on_invalid(battle, unit, reason, detail)
	action_rejected.emit(unit.unit_id, reason, detail)
	return true


func after_party_turn(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	_accepted()
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, battle.extra_action))


func after_interrupt(battle: Battle, unit: BattleUnit, action: Dictionary) -> void:
	_accepted()
	entries.append(ActionRecorder.entry(battle.turn, unit.unit_id, action, false, true))


func _auto_on() -> bool:
	return autopilot != null and _auto_refusals < AUTO_REFUSALS


func _accepted() -> void:
	if _from_auto:
		auto_picks += 1
	_from_auto = false
	_auto_refusals = 0


## The ActionLog JSON shape (Rpg.Contracts.Battle.ActionLog), field order matching the C# record.
func action_log(battle: Battle) -> Dictionary:
	return ActionRecorder.build_log(entries, battle.outcome, battle.final_hash)


## `extra`: a One More action (spec item-pass 3.2); `interrupt`: an ult cast out of turn (spec ult-interrupts). Each
## key is written only when true, so other logs are unchanged. No per-entry state hash (spec atomic-battles).
static func entry(turn: int, unit_id: StringName, action: Dictionary, extra: bool = false, interrupt: bool = false) -> Dictionary:
	var target := StringName(str(action.get("target", "")))
	var result := {
		"turn": turn,
		"actor": String(unit_id),
		"ability": String(action["ability"]),
		"target": null if target == &"" else String(target),
	}
	if extra:
		result["extra"] = true
	if interrupt:
		result["interrupt"] = true
	return result


static func build_log(log_entries: Array[Dictionary], outcome: String, final_hash: String) -> Dictionary:
	return {
		"schemaVersion": ReplayRunner.ACTION_LOG_SCHEMA_VERSION,
		"actions": log_entries,
		"claimedOutcome": outcome,
		"claimedFinalHash": final_hash,
	}
