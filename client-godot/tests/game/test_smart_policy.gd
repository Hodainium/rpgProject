## Spec playable-demo 3.9: the smart policy (D20) picks weaknesses, avoids drains, heals a hurt ally and plays whole runs
## cleanly; chaos on top of it (D21) at 0% is exactly the smart policy. Fixtures only.
extends TestCase

const BattleV2 := preload("res://tests/combat/test_battle_v2.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]


## The v2 golden party (the knight holds Frost, an Ice move) with every member alive; `hp` sets the knight's HP.
static func _party_snapshot(knight_hp: Variant = null) -> Dictionary:
	var snap: Dictionary = BattleV2.v2_snapshot("7")
	var party: Array = []
	for member in snap["party"]:
		var healthy := {}
		for key in member:
			if key != "hp":
				healthy[key] = member[key]
		if int(member["slot"]) == 1 and knight_hp != null:
			healthy["hp"] = knight_hp
		party.append(healthy)
	snap["party"] = party
	return snap


## The first damaging action ability of `unit` and its damage type.
static func _damaging(unit: BattleUnit) -> Array:
	for ability in unit.action_abilities():
		if not ability.targets_enemies() or not ability.needs_target():
			continue
		for row in ability.executions:
			if row != null and row.damage_mode != ExecutionRow.DamageMode.USE_EFFECT and SmartController._damage_type(row) != "":
				return [ability, SmartController._damage_type(row)]
	return []


func test_smart_targets_weakness_and_avoids_drain() -> void:
	var battle := new_battle(_party_snapshot())
	var unit := battle.unit_by_id(&"P1")
	var found := _damaging(unit)
	check(not found.is_empty(), "P1 has a typed single-target move")
	if found.is_empty():
		return
	var ability: BattleAbility = found[0]
	var kind: String = found[1]
	var enemies := battle.target_candidates(unit, ability)
	check(enemies.size() >= 2, "two targets to choose from")
	var weak: BattleUnit = enemies[enemies.size() - 1]
	weak.asc.add_tag(StringName("Weakness." + kind))
	var plain := SmartController.score_of(battle, unit, ability, enemies[0])
	check(SmartController.score_of(battle, unit, ability, weak) > plain, "a weakness scores higher")
	# choose() takes the best-scoring (ability, target) over every move it may use.
	var choice := SmartController.new().choose(battle, unit)
	var best := -1
	for candidate in SmartController._activatable(unit):
		if candidate.targets_enemies():
			for target in SmartController._targets(battle, unit, candidate):
				best = maxi(best, SmartController.score_of(battle, unit, candidate, target))
	var picked := unit.ability_by_tag(choice["ability"])
	var aimed := battle.unit_by_id(choice["target"]) if choice["target"] != &"" else SmartController._enemies_of(battle, unit)[0]
	eq(SmartController.score_of(battle, unit, picked, aimed), best, "the smart policy takes the best-scoring move: %s" % choice)
	for enemy in enemies:
		enemy.asc.add_tag(StringName("Drain." + kind))
	eq(SmartController.score_of(battle, unit, ability, weak), 0, "a drain is never worth hitting")


func test_smart_heals_a_hurt_ally() -> void:
	var battle := new_battle(_party_snapshot(10000))  # 100 of the knight's 1000 HP; nobody dead
	var knight := battle.unit_by_id(&"P1")
	var choice := SmartController.new().choose(battle, knight)
	eq(choice.get("ability"), &"Fixture.Ability.Flask", "a hurt party is healed first (the knight's Flask)")


func test_smart_plays_whole_runs() -> void:
	var options := {"policy": "smart", "party": PARTY, "check": true}
	var report := await PlayReport.many(fixtures(), host, 1, 5, options)
	var again := await PlayReport.many(fixtures(), host, 1, 5, options)
	eq(report["stopped"], 0, "every smart run ends")
	eq(report["violations"], [], "every battle verifies and breaks no invariant")
	report.erase("failures")
	again.erase("failures")
	eq(WireJson.stringify(again), WireJson.stringify(report), "deterministic")
	var auto := await PlayReport.many(fixtures(), host, 1, 5, {"party": PARTY})
	check(report["runs"].map(func(run): return run["runHash"]) != auto["runs"].map(func(run): return run["runHash"]),
		"the smart policy plays differently from auto")


## Chaos at 0% of decisions is the smart policy, move for move; from a later floor, the earlier floors are smart.
func test_chaos_on_top_of_smart() -> void:
	var smart := await PlayReport.many(fixtures(), host, 1, 3, {"policy": "smart", "party": PARTY})
	var calm := await PlayReport.many(fixtures(), host, 1, 3, {"policy": "chaos", "chaos": 0, "party": PARTY})
	eq(calm["runs"].map(func(run): return run["runHash"]), smart["runs"].map(func(run): return run["runHash"]),
		"chaos at 0% plays exactly like smart")
	eq(calm["violations"], [], "and checks every battle")
	var late := await PlayReport.many(fixtures(), host, 1, 3, {"policy": "chaos", "chaos": 100, "chaos_from": 2,
		"party": PARTY})
	eq(late["stopped"], 0, "chaos from floor 2 ends every run")
	eq(late["violations"], [], "no violation")
	var full := await PlayReport.many(fixtures(), host, 1, 3, {"policy": "chaos", "chaos": 50, "party": PARTY})
	eq(full["violations"], [], "chaos at 50% on top of smart: no violation")
	check(not full["refused"].is_empty(), "illegal moves are still tried at 50%")
