## Spec content-pass 2.2: PatternBrain (a fixed rotation), TacticalBrain (affinity-aware targets, ult timing) and the
## ult-interrupts gap: a brain that returns an ult as a turn action stops the battle with a runner error. Fixtures only.
extends TestCase

const Statuses := preload("res://tests/combat/test_statuses.gd")
const Bosses := preload("res://tests/combat/test_bosses.gd")


func test_pattern_brain_rotation() -> void:
	var battle := new_battle(Bosses.boss_snapshot())
	var drummer := battle.unit_by_id(&"E2")
	var brain: PatternBrain = drummer.definition.brain
	var chosen := []
	for i in 4:
		chosen.append(String(brain.choose(drummer, battle)["ability"]))
	eq(chosen, ["Fixture.Ability.Claw", "Fixture.Ability.Claw", "Fixture.Ability.Bash", "Fixture.Ability.Claw"],
		"the pattern repeats")
	eq(drummer.pattern_step, 4, "one step per choice")
	check(StateHasher.canonical_lines(battle)["lines"].has("pattern=E2|4"), "the step is hashed")
	check(not Array(StateHasher.canonical_lines(battle)["lines"]).any(func(line): return line.begins_with("pattern=E1")),
		"units without a pattern hash no pattern line")


func test_pattern_brain_fallback() -> void:
	var battle := new_battle(Bosses.boss_snapshot())
	var drummer := battle.unit_by_id(&"E2")
	var brain := PatternBrain.new()
	brain.pattern.assign([&"Fixture.Ability.Missing"])
	eq(String(brain.choose(drummer, battle)["ability"]), "Fixture.Ability.Claw", "a step the unit can't take falls back to the default")
	eq(drummer.pattern_step, 1, "the step still counts")


func test_brain_ult_as_action_is_runner_error() -> void:
	var battle := new_battle(Bosses.boss_snapshot())
	var lich := battle.unit_by_id(&"E1")
	lich.asc.initialize_attribute_overrides({"energy": 10000.0})
	var definition: EnemyDefinition = lich.definition.duplicate()
	var brain := PatternBrain.new()
	brain.pattern.assign([&"Fixture.Ability.DeathRay"])
	definition.brain = brain
	lich.definition = definition
	var result: Dictionary = await battle._take_action(lich, ScriptedController.new())
	eq(result, {}, "no action")
	check(battle.runner_error.contains("illegal action"), "a runner error, never a verdict: " + battle.runner_error)
	eq(battle.mismatch, {}, "no mismatch")


func test_tactical_brain_avoids_drain() -> void:
	var battle := new_battle(Statuses.status_snapshot(["hexer", "guard"], "status_trial", "3",
		{1: ["frostguard"], 2: ["implant"]}))
	var brain := TacticalBrain.new()
	var imp := battle.unit_by_id(&"E3")
	var wisp := battle.unit_by_id(&"E1")
	eq(Statuses.ids(brain.target_pool(imp, battle, Statuses.ability(imp, "FireBolt"))), ["P1"],
		"a Fire attack skips the guard, which drains Fire")
	eq(Statuses.ids(brain.target_pool(wisp, battle, Statuses.ability(wisp, "FrostTouch"))), ["P2"],
		"an Ice attack skips the hexer, which resists Ice")
	battle.unit_by_id(&"P1").alive = false
	eq(Statuses.ids(brain.target_pool(imp, battle, Statuses.ability(imp, "FireBolt"))), ["P2"],
		"with only the drainer left it still attacks")
	# Without affinities in the party the pool is the default one, so the draw (and the replay) is the same.
	var plain := new_battle(Statuses.status_snapshot())
	var plain_imp := plain.unit_by_id(&"E3")
	var state := plain.rng.state
	var tactical_choice := brain.choose(plain_imp, plain)
	var tactical_draw := plain.rng.state
	plain.rng.state = state
	eq(EnemyBrain.new().choose(plain_imp, plain), tactical_choice, "the same choice as the default brain")
	eq(plain.rng.state, tactical_draw, "from the same RNG draw")


func test_tactical_ult_timing() -> void:
	var battle := new_battle(Bosses.boss_snapshot())
	var lich := battle.unit_by_id(&"E1")
	lich.asc.initialize_attribute_overrides({"energy": 10000.0})
	var brain: TacticalBrain = lich.definition.brain
	eq(brain.choose_interrupt(lich, battle), {}, "holds the ult while no party unit is Downed")
	battle.unit_by_id(&"P1").asc.add_tag(Battle.DOWNED_TAG)
	eq(String(brain.choose_interrupt(lich, battle).get("ability", "")), "Fixture.Ability.DeathRay",
		"casts it on a Downed party member")
	var eager := TacticalBrain.new()
	battle.unit_by_id(&"P1").asc.clear_tag(Battle.DOWNED_TAG)
	check(not eager.choose_interrupt(lich, battle).is_empty(), "with no condition set it casts at once, like the default")
	var careful := TacticalBrain.new()
	careful.ult_when_ally_hp_below_x100 = 5000
	eq(careful.choose_interrupt(lich, battle), {}, "holds while every ally is above 50%")
	Bosses.hurt(battle.unit_by_id(&"P1"), battle.unit_by_id(&"E2"), 100000)
	check(not careful.choose_interrupt(lich, battle).is_empty(), "casts once an ally is below 50%")
