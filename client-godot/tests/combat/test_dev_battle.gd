## Dev decisions in battle (spec dev-tools 3.6): applied through GAS only with allow_dev, logged as an ordinary entry,
## and rejected with 2002 IllegalAbility on replay.
extends TestCase

const KILL := preload("res://game/dev/content/effects/dev_kill.tres")


## Plays a fixture battle with an ActionRecorder whose first decision is a dev kill of every enemy.
func _battle_with_kill(allow: bool) -> Battle:
	var battle := new_battle(squad_snapshot())
	battle.allow_dev = allow
	var recorder := ActionRecorder.new()
	recorder.submit_dev(&"Dev.Kill", KILL, "enemies")
	recorder.action_requested.connect(_pick.bind(battle, recorder))
	await battle.run(recorder)
	battle.set_meta("entries", recorder.entries)
	return battle


func test_dev_kill_through_gas() -> void:
	var battle := await _battle_with_kill(true)
	eq(battle.outcome, Battle.VICTORY, "kill enemies → Victory through the normal death and end checks")
	var entries: Array = battle.get_meta("entries")
	eq(entries[0]["ability"], "Dev.Kill", "logged as an ordinary action entry")
	eq(entries[0]["target"], "enemies", "with its targets")


func test_dev_decision_needs_allow_dev() -> void:
	var battle := await _battle_with_kill(false)
	var entries: Array = battle.get_meta("entries")
	check(entries.all(func(entry) -> bool: return entry["ability"] != "Dev.Kill"), "without allow_dev nothing is applied or logged")


func test_replay_rejects_dev_battle() -> void:
	var request: Dictionary = await record(squad_snapshot())
	var actions: Array = request["actionLog"]["actions"]
	var first: Dictionary = actions[0]
	actions.insert(0, {"turn": first["turn"], "actor": first["actor"], "ability": "Dev.Kill", "target": "enemies"})
	var result := await replay(copy(request))
	eq(result.get("verdict"), "Rejected", "a logged dev decision is rejected")
	eq(result.get("errorCode"), 2002, "with 2002")
	eq(result.get("mismatch", {}).get("reason"), "IllegalAbility", "as an illegal ability")


## The first usable ability on the first valid target.
func _pick(unit_id: StringName, _turn: int, battle: Battle, recorder: ActionRecorder) -> void:
	var unit := battle.unit_by_id(unit_id)
	for ability in unit.action_abilities():
		if not unit.asc.can_activate_ability(ability):
			continue
		var targets := battle.target_candidates(unit, ability)
		if ability.needs_target() and targets.is_empty():
			continue
		recorder.submit_action.call_deferred(ability.ability_tag, targets[0].unit_id if ability.needs_target() else &"")
		return


## A battle snapshot whose party holds a dev stat item can't verify: the verifier's index has no dev content, so setup
## stops with "unknown item" (a runner error) instead of crashing or verifying.
func test_replay_rejects_dev_item() -> void:
	var content := fixtures().overlay([])
	content.add_root(RunController.DEV_CONTENT)
	var run := RunController.new()
	host.add_child(run)
	run.start_run(content, [&"fixture.character.knight"], "7")
	eq(run.dev_stat("atk", 1, 1), "", "a dev stat item is held")
	eq(run.dev_spawn(content.encounters[&"fixture.encounter.lone"]), "", "a battle is waiting")
	var snapshot := run.battle_snapshot()
	check(snapshot["party"][0]["items"].has("dev.up.atk"), "the snapshot carries the dev item")
	var result := await replay(copy({"snapshot": snapshot, "actionLog": ActionRecorder.build_log([], Battle.VICTORY, "")}))
	check(result.get("verdict") != "Verified", "it never verifies")
	eq(result["mismatch"]["reason"], "MalformedRequest", "it is refused as a malformed request")
	check(str(result["mismatch"]["detail"]).contains("unknown item 'dev.up.atk'"),
		"setup stops cleanly naming the item: %s" % result)
	run.free()
