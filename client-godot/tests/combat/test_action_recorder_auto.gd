## Spec auto-battle: ActionRecorder.autopilot. Auto picks are logged like manual ones (same log and hash as the same
## picks made by hand), counted in auto_picks, and replay as Verified; turning Auto on wakes a waiting decision, turning
## it off hands decisions back; a refused or empty autopilot hands the decision to the player. Fixtures only.
extends TestCase

const Golden := preload("res://tests/combat/test_golden.gd")


## An autopilot that always picks an ability nobody has (refused by the battle), or nothing (`empty`).
class StubPilot:
	extends RefCounted
	var asked: int = 0
	var refused: int = 0
	var empty: bool = false

	func choose(_battle: Battle, _unit: BattleUnit) -> Dictionary:
		asked += 1
		return {} if empty else {"ability": &"Stub.Ability.Nowhere", "target": &""}

	func interrupt(_battle: Battle) -> Dictionary:
		return {}

	func on_invalid(_battle: Battle, _unit: BattleUnit, _reason: String, _detail: String) -> bool:
		refused += 1
		return true


static func _pilot(ults: bool = true) -> AutoPolicy:
	var options := AutoPolicy.Options.new()
	options.ults = ults
	return AutoPolicy.new(options, fixtures())


## Auto picks and the same picks submitted by hand give the same log and final hash (ults held, so every pick is a
## turn action the hand can copy).
func test_auto_log_equals_manual() -> void:
	var snap := Golden.auto_snapshot()
	var auto_battle := new_battle(snap)
	var auto := ActionRecorder.new()
	auto.autopilot = _pilot(false)
	await auto_battle.run(auto)
	var hand_battle := new_battle(snap)
	var hand := ActionRecorder.new()
	var policy := _pilot(false)
	hand.action_requested.connect(func(unit_id: StringName, _turn: int) -> void:
		var pick := policy.choose(hand_battle, hand_battle.unit_by_id(unit_id))
		hand.submit_action.call_deferred(pick["ability"], pick["target"]))
	await hand_battle.run(hand)
	check(not auto.entries.is_empty(), "Auto played")
	eq(auto.entries, hand.entries, "the same log")
	eq(auto_battle.final_hash, hand_battle.final_hash, "the same final hash")
	eq(auto.auto_picks, auto.entries.size(), "every entry was an Auto pick")
	eq(hand.auto_picks, 0, "no Auto pick by hand")


func test_auto_battle_replays() -> void:
	var request := await record_auto(Golden.auto_snapshot())
	var result := await replay(copy(request))
	eq(result["verdict"], "Verified", "an Auto battle verifies like any other")
	eq(result["finalStateHash"], request["actionLog"]["claimedFinalHash"], "same hash")


## Turning Auto on while a decision waits takes it at once; turning it off hands the next one back.
func test_auto_toggle_wakes_and_releases() -> void:
	var battle := new_battle(Golden.auto_snapshot())
	var recorder := ActionRecorder.new()
	var requested := []
	recorder.action_requested.connect(func(unit_id: StringName, turn: int) -> void:
		requested.append(turn)
		if requested.size() == 1:
			(func(): recorder.autopilot = _pilot()).call_deferred()  # the player presses Auto
		else:
			# Auto was turned off again: the player finishes the battle with the same policy's picks.
			var pick := _pilot().choose(battle, battle.unit_by_id(unit_id))
			recorder.submit_action.call_deferred(pick["ability"], pick["target"]))
	var picks_before_off := [0]
	battle.turn_started.connect(func(_unit_id: StringName, _turn: int) -> void:
		if recorder.auto_picks >= 2 and recorder.autopilot != null:
			picks_before_off[0] = recorder.auto_picks
			recorder.autopilot = null)
	await battle.run(recorder)
	check(battle.outcome != "", "the battle ends")
	check(requested.size() >= 2, "the first decision waited, and a later one waited again after Auto went off")
	check(picks_before_off[0] >= 2, "Auto played while on")
	eq(recorder.auto_picks, picks_before_off[0], "no Auto pick after it went off")


## A refused autopilot pick is retried once, then the player decides; an autopilot with nothing to pick hands over too.
func test_auto_refusal_falls_back_to_the_player() -> void:
	for empty in [false, true]:
		var battle := new_battle(Golden.auto_snapshot())
		var recorder := ActionRecorder.new()
		var stub := StubPilot.new()
		stub.empty = empty
		recorder.autopilot = stub
		var waited := [0]
		recorder.action_requested.connect(func(_unit_id: StringName, _turn: int) -> void:
			waited[0] += 1
			if waited[0] == 1:
				(func(): recorder.autopilot = _pilot()).call_deferred())  # a working Auto finishes the battle
		await battle.run(recorder)
		eq(waited[0], 1, "the player was asked once (%s)" % ("empty" if empty else "refused"))
		eq(stub.asked, 1 if empty else ActionRecorder.AUTO_REFUSALS, "asked until it gave up")
		eq(stub.refused, 0 if empty else ActionRecorder.AUTO_REFUSALS, "each refusal reached the autopilot")
		check(not recorder.entries.any(func(entry) -> bool: return entry["ability"] == "Stub.Ability.Nowhere"),
			"a refused pick is never logged")
		check(battle.outcome != "", "the battle ends")
