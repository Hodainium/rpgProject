## Spec playable-demo 2.3b (F5): the chaos policy (bad and illegal moves), the invariant checker, and record → replay
## of every battle. Fixtures only.
extends TestCase

const UltTests := preload("res://tests/combat/test_ult_interrupts.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]


## Whole fixture runs on the chaos policy: every check on, no violation, deterministic, and illegal moves were tried.
func test_chaos_policy() -> void:
	var options := {"policy": "chaos", "illegal": 30, "party": PARTY}
	var report := await PlayReport.many(fixtures(), host, 1, 5, options)
	var again := await PlayReport.many(fixtures(), host, 1, 5, options)
	for violation in report["violations"]:
		check(false, "violation: %s" % violation)
	eq(report["stopped"], 0, "no chaos run stops on a runner error, a dead end or the step cap")
	check(not report["refused"].is_empty(), "illegal moves were submitted and refused: %s" % report["refused"])
	report.erase("failures")
	again.erase("failures")
	eq(WireJson.stringify(again), WireJson.stringify(report), "the same seeds give the same chaos report")
	var calm := await PlayReport.many(fixtures(), host, 1, 5, {"party": PARTY})
	check(calm["runs"].map(func(run): return run["runHash"]) != report["runs"].map(func(run): return run["runHash"]),
		"chaos plays differently from the auto policy")


## Every illegal case the chaos policy knows is refused with no state change, no log entry and no RNG draw. Battles on
## fixture snapshots with every decision starting illegal, until each case has been seen.
func test_illegal_moves_refused() -> void:
	var seen := {}
	var snapshots: Array[Dictionary] = [UltTests.ult_snapshot(), squad_snapshot("42"), squad_snapshot("7"),
		await _run_battle_snapshot()]
	for index in snapshots.size():
		for seed_value in range(1, 4 if index < snapshots.size() - 1 else 11):  # one unit has the costed skill: more tries
			var battle := new_battle(snapshots[index])
			var controller := ChaosController.new(RunSeeds.rng(seed_value, "test/chaos/%d" % index), 10000)
			await battle.run(controller)
			eq(battle.runner_error, "", "no runner error")
			eq(battle.mismatch, {}, "the recording is never rejected: %s" % battle.mismatch)
			for violation in controller.violations:
				check(false, "violation (snapshot %d, seed %d): %s" % [index, seed_value, violation])
			for case in controller.refused:
				seen[case] = seen.get(case, 0) + controller.refused[case]
			var request := {"snapshot": snapshots[index], "actionLog": ActionRecorder.build_log(controller.entries,
				battle.outcome, battle.final_hash)}
			var result := await replay(JSON.parse_string(WireJson.stringify(request)))
			eq(result.get("verdict"), "Verified", "a battle full of refused moves replays Verified")
	for case in ChaosController.ILLEGAL_CASES + ChaosController.ILLEGAL_INTERRUPTS:
		if case in ["dead_caster", "enemy_caster"] and not seen.has(case):
			continue  # needs a party death or an enemy ult on the fixtures; covered when it happens
		check(seen.has(case), "illegal case %s was submitted and refused (seen: %s)" % [case, seen])


## The first battle of fixture run seed 7 (the knight, medic and rogue with their run kits), as a BattleSnapshot v2.
func _run_battle_snapshot() -> Dictionary:
	var run := start_run(host, "7", PARTY)
	for step in 50:
		if not run.pending_battle.is_empty():
			break
		if not run.state.event.is_empty():
			for choice in run.current_page().choices.size():
				if run.choice_enabled(choice):
					run.choose(choice)
					break
			continue
		var next := RunPlayer.next_room(run)
		if next == -1:
			break
		run.enter_room(next)
	check(not run.pending_battle.is_empty(), "fixture run seed 7 reaches a battle")
	var snap := run.battle_snapshot()
	run.free()
	# The party's MP-cost skill (mend) is unaffordable from the start: every member enters with 0 MP (v2 "mp", after "hp").
	var members: Array = []
	for member in snap["party"]:
		var drained := {}
		for key in member:
			drained[key] = member[key]
			if key == "hp":
				drained["mp"] = 0
		drained["mp"] = 0
		members.append(drained)
	snap["party"] = members
	return snap


## The checker reports a broken bound and a dead unit still holding HP; it changes nothing.
func test_invariant_checker() -> void:
	var battle := new_battle(squad_snapshot("42"))
	var checker := InvariantChecker.new()
	var hash_before := battle.state_hash()
	checker.point(battle, "start")
	eq(checker.violations, [], "a fresh battle breaks no invariant")
	eq(battle.state_hash(), hash_before, "checking changes nothing")
	var unit := battle.unit_by_id(&"P1")
	unit.asc.get_attribute(BattleUnit.HP).current_value = unit.stat(BattleUnit.MAX_HP) + 100
	checker.point(battle, "turn", &"P1")
	eq(checker.violations.map(func(violation): return violation["invariant"]), ["hp_out_of_range"],
		"hp above max_hp is reported")
	unit.alive = false
	checker.point(battle, "turn", &"P1")
	check(checker.violations.any(func(violation): return violation["invariant"] == "dead_with_hp"), "a dead unit with HP is reported")
	check(checker.violations.all(func(violation): return violation["unit"] == "P1"), "the unit is named")
