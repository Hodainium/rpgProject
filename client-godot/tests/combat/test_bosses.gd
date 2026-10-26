## Spec content-pass H5 (boss phases as data) and H7 (party weakness hits): the lich court (E1 lich: phases at 60% and 25%,
## TacticalBrain; E2 drummer: PatternBrain) against the breakable guard, the hexer and the breaker. Fixtures only.
extends TestCase

const Statuses := preload("res://tests/combat/test_statuses.gd")


static func boss_snapshot(seed_text: String = "5") -> Dictionary:
	var snap: Dictionary = Statuses.status_snapshot(["guard_weak", "hexer", "breaker"], "lich_court", seed_text)
	snap["battleId"] = "boss-seed-%s" % seed_text
	return snap


## Lowers `unit`'s HP by `amount` (stored ×100) through an instant GAS effect from `source`.
static func hurt(source: BattleUnit, unit: BattleUnit, amount: int) -> void:
	var effect := GameplayEffect.new()
	effect.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := CombatModifier.new()
	modifier.attribute_name = "hp"
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = -amount
	effect.modifiers.append(modifier)
	unit.asc.apply_gameplay_effect(effect, source.asc, 1)


func test_phase_change() -> void:
	var battle := new_battle(boss_snapshot())
	var lich := battle.unit_by_id(&"E1")
	var phases := []
	battle.phase_changed.connect(func(unit_id, phase): phases.append([unit_id, phase]))
	var heard := Statuses.listen(lich)
	hurt(battle.unit_by_id(&"P1"), lich, 70000)  # 2000 → 1300 HP (65%): above the first threshold
	battle._check_deaths()
	eq(phases, [], "no phase above 60%")
	hurt(battle.unit_by_id(&"P1"), lich, 20000)  # 1100 HP (55%)
	battle._check_deaths()
	eq(phases, [[&"E1", 1]], "below 60%: the first phase")
	check(lich.asc.has_tag_exact(&"State.Phase.Two"), "its AbilitySet's tag")
	eq(Statuses.names(heard, "Event.Unit.PhaseChanged"), ["Event.Unit.PhaseChanged"], "the boss hears the phase change")
	check(not lich.asc.can_activate_ability(Statuses.ability(lich, "BleedBlast")), "the phase-1 move is locked")
	check(lich.asc.can_activate_ability(Statuses.ability(lich, "HexAll")), "the phase-2 move opens")
	battle._check_deaths()
	eq(phases.size(), 1, "each phase is entered once")
	check(StateHasher.canonical_lines(battle)["lines"].has("phase=E1|1"), "the phase is hashed")


func test_phase_double_cross() -> void:
	var battle := new_battle(boss_snapshot())
	var lich := battle.unit_by_id(&"E1")
	Statuses.apply(battle.unit_by_id(&"P2"), lich, "st_poison")
	var phases := []
	battle.phase_changed.connect(func(unit_id, phase): phases.append([unit_id, phase]))
	hurt(battle.unit_by_id(&"P1"), lich, 160000)  # 400 HP (20%): crosses 60% and 25% at once
	battle._check_deaths()
	eq(phases, [[&"E1", 1], [&"E1", 2]], "both phases, in order")
	check(lich.asc.has_tag_exact(&"State.Phase.Two") and lich.asc.has_tag_exact(&"State.Phase.Three"), "both sets granted")
	check(not lich.asc.has_tag_exact(&"Status.Debuff.Poison"), "the last phase cleared the debuffs")
	check(lich.asc.can_activate_ability(Statuses.ability(lich, "DoomBolt")), "the phase-3 move opens")
	check(not lich.asc.can_activate_ability(Statuses.ability(lich, "HexAll")), "and the phase-2 move closes")


func test_phase_not_on_kill() -> void:
	var battle := new_battle(boss_snapshot())
	var lich := battle.unit_by_id(&"E1")
	var phases := []
	battle.phase_changed.connect(func(unit_id, phase): phases.append([unit_id, phase]))
	hurt(battle.unit_by_id(&"P1"), lich, 300000)
	battle._check_deaths()
	check(not lich.alive, "the blow kills")
	eq(phases, [], "a killing blow starts no phase")
	eq(lich.phase_index, 0, "nothing entered")


## Spec content-pass H7 (Persona): an enemy hitting a party weakness gets a One More; the party unit is Downed, never
## Broken, and grants no second One More until its next turn.
func test_enemy_one_more() -> void:
	var battle := new_battle(boss_snapshot())
	var guard := battle.unit_by_id(&"P1")
	var lich := battle.unit_by_id(&"E1")
	var downed := []
	battle.unit_downed.connect(func(unit_id, by): downed.append([unit_id, by]))
	await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), guard)
	check(guard.asc.has_tag_exact(Battle.DOWNED_TAG), "a hit on the guard's Physical weakness downs it")
	eq(downed, [[&"P1", &"E1"]], "unit_downed reports it")
	eq(Statuses.ids(battle.one_more_queue), ["E1"], "the enemy is owed a One More")
	var controller := ScriptedController.new()
	var turn := battle.turn
	await battle._extra_action(battle.one_more_queue.pop_front(), controller)
	eq(battle.turn, turn + 1, "the enemy's extra action takes a turn number")
	eq(controller.entries, [], "an enemy One More is re-simulated, never logged")


func test_party_never_broken() -> void:
	var battle := new_battle(boss_snapshot())
	var guard := battle.unit_by_id(&"P1")
	var lich := battle.unit_by_id(&"E1")
	eq(guard.stat(Battle.MAX_TOUGHNESS), 0, "party characters have no toughness bar")
	for i in 3:
		await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), guard)
		guard.asc.clear_tag(Battle.DOWNED_TAG)
	check(not guard.asc.has_tag_exact(Battle.BROKEN_TAG), "weakness hits knock a party unit down, never break it")
	# Even a party unit that content gave toughness (a validator warning) never breaks.
	guard.asc.initialize_attribute_overrides({"max_toughness": 6000.0, "toughness": 3000.0})
	await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), guard)
	eq(guard.stat(Battle.TOUGHNESS), 0, "its toughness is emptied")
	check(not guard.asc.has_tag_exact(Battle.BROKEN_TAG), "but it is not Broken")


func test_downed_grants_once() -> void:
	var battle := new_battle(boss_snapshot())
	var guard := battle.unit_by_id(&"P1")
	var lich := battle.unit_by_id(&"E1")
	await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), guard)
	battle.one_more_queue.clear()
	await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), guard)
	eq(battle.one_more_queue, [] as Array[BattleUnit], "a Downed unit grants no second One More")
	var hexer := battle.unit_by_id(&"P2")
	await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), hexer)
	check(not hexer.asc.has_tag_exact(Battle.DOWNED_TAG), "a hit without a weakness downs nobody")
	eq(battle.one_more_queue, [] as Array[BattleUnit], "and grants nothing")
	# The guard stands up at its next turn start (the turn loop does this before the turn ticks).
	battle.turn_manager.av[guard] = -1
	var stopper := StopAfterFirstTurn.new()
	await battle.run(stopper)
	check(not guard.asc.has_tag_exact(Battle.DOWNED_TAG), "the guard is no longer Downed once its turn starts")
	await battle._activate(lich, Statuses.ability(lich, "BleedBlast"), guard)
	eq(Statuses.ids(battle.one_more_queue), ["E1"], "and can grant a One More again")


## Takes the first party decision, then stops the battle (a test controller for one turn).
class StopAfterFirstTurn:
	extends ScriptedController

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		battle.reject("Stopped", "test stop")
		return {}

	func interrupt(_battle: Battle) -> Dictionary:
		return {}
