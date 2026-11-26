## Spec auto-battle: the player's Auto policy (the smart policy of spec playable-demo 3.9, D20, now system code). It picks
## weaknesses, avoids drains, heals a hurt ally (Ability.Role.Heal), revives (Ability.Role.Revive), cleanses, buffs,
## keeps CONSUMABLE items unless allowed, holds ults when told to, never draws from the battle's RNG, and plays whole
## runs cleanly through ActionRecorder; chaos on top of it (D21) at 0% is exactly the smart policy. Fixtures only.
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
			if row != null and row.damage_mode != ExecutionRow.DamageMode.USE_EFFECT and AutoPolicy.damage_type(row) != "":
				return [ability, AutoPolicy.damage_type(row)]
	return []


static func _policy(consumables: bool = false, ults: bool = true) -> AutoPolicy:
	var options := AutoPolicy.Options.new()
	options.consumables = consumables
	options.ults = ults
	return AutoPolicy.new(options, fixtures())


## A fixture ability scene, instantiated (the caller frees it).
static func _scene(name: String) -> BattleAbility:
	return (load("res://tests/fixtures/abilities/%s.tscn" % name) as PackedScene).instantiate() as BattleAbility


func test_auto_targets_weakness_and_avoids_drain() -> void:
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
	var plain := AutoPolicy.score_of(battle, unit, ability, enemies[0])
	check(AutoPolicy.score_of(battle, unit, ability, weak) > plain, "a weakness scores higher")
	# choose() takes the best-scoring (ability, target) over every move it may use.
	var policy := _policy()
	var choice := policy.choose(battle, unit)
	var best := -1
	for candidate in policy._activatable(unit):
		if candidate.targets_enemies():
			for target in AutoPolicy._targets(battle, unit, candidate):
				best = maxi(best, AutoPolicy.score_of(battle, unit, candidate, target))
	var picked := unit.ability_by_tag(choice["ability"])
	var aimed := battle.unit_by_id(choice["target"]) if choice["target"] != &"" else AutoPolicy._enemies_of(battle, unit)[0]
	eq(AutoPolicy.score_of(battle, unit, picked, aimed), best, "Auto takes the best-scoring move: %s" % choice)
	for enemy in enemies:
		enemy.asc.add_tag(StringName("Drain." + kind))
	eq(AutoPolicy.score_of(battle, unit, ability, weak), 0, "a drain is never worth hitting")


func test_auto_heals_a_hurt_ally_by_role() -> void:
	var battle := new_battle(_party_snapshot(10000))  # 100 of the knight's 1000 HP; nobody dead
	var knight := battle.unit_by_id(&"P1")
	check(knight.ability_by_tag(&"Fixture.Ability.Flask").asset_tags.has(AutoPolicy.ROLE_HEAL), "Flask is tagged Heal")
	var choice := _policy().choose(battle, knight)
	eq(choice.get("ability"), &"Fixture.Ability.Flask", "a hurt party is healed first (the knight's Flask, a cooldown item)")


## Spec auto-battle A4: the Feather is CONSUMABLE: Auto doesn't spend it unless allowed.
func test_auto_keeps_consumables() -> void:
	var battle := new_battle(BattleV2.v2_snapshot("7"))  # the rogue (P3) is dead; the knight holds the Feather
	var knight := battle.unit_by_id(&"P1")
	check(knight.ability_by_tag(&"Fixture.Ability.Feather") != null, "the knight can use the Feather")
	var kept := _policy().choose(battle, knight)
	check(kept.get("ability") != &"Fixture.Ability.Feather", "a consumable is kept by default: %s" % kept)
	var spent := _policy(true).choose(battle, knight)
	eq([spent.get("ability"), spent.get("target")], [&"Fixture.Ability.Feather", &"P3"],
		"with consumables allowed, the dead rogue is revived")


func test_auto_cleanses_a_controlled_ally() -> void:
	var battle := new_battle(_party_snapshot())
	var medic := battle.unit_by_id(&"P2")
	var purify := _scene("ult_purify")
	var actions: Array[BattleAbility] = [purify]
	var policy := _policy()
	eq(policy._cleanse(battle, medic, actions), {}, "nobody to cleanse")
	battle.unit_by_id(&"P1").asc.add_tag(Battle.CONTROLLED_TAG)
	eq(policy._cleanse(battle, medic, actions), {"ability": &"Fixture.Ability.UltPurify", "target": &""},
		"a controlled ally is cleansed")
	purify.free()


func test_auto_buffs_only_when_missing() -> void:
	var battle := new_battle(_party_snapshot())
	var knight := battle.unit_by_id(&"P1")
	var ward := _scene("ward")
	var actions: Array[BattleAbility] = [ward]
	var policy := _policy()
	eq(policy._buff(battle, knight, actions), {"ability": &"Fixture.Ability.Ward", "target": &""}, "the ward is missing")
	knight.asc.add_tag(&"Status.Buff.Ward")
	eq(policy._buff(battle, knight, actions), {}, "already warded")
	ward.free()


func test_auto_holds_ults_when_told() -> void:
	var battle := new_battle(_party_snapshot())
	eq(_policy(false, false).interrupt(battle), {}, "ults=off never casts an ult")


func test_auto_draws_no_rng() -> void:
	var battle := new_battle(_party_snapshot(10000))
	var before := battle.rng.state
	var first := _policy().choose(battle, battle.unit_by_id(&"P1"))
	var second := _policy().choose(battle, battle.unit_by_id(&"P1"))
	eq(first, second, "the same state gives the same choice")
	eq(battle.rng.state, before, "choosing never draws from the battle's RNG")


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


# --- Spec auto-support -----------------------------------------------------------------------------------------------------

## The fixture psalmist (P1: Mend 300 for 25 SP, Great Mend 300 x its 150% SP gain for 37, Mass Mend 300 for 50, Renew 6% a
## tick for 2 ticks at 25, Purge Mend 450 + cleanse for 60, Anthem 25 and Grand Anthem 37), a chanter (P2, 1200 HP) and a
## cantor (P3, 1100 HP) against the sp trial's keepers. `first` replaces P1 (the hymnist has no basic).
static func _support_snapshot(first: String = "psalmist") -> Dictionary:
	var members: Array = []
	for entry in [[1, first], [2, "chanter"], [3, "cantor"]]:
		members.append({"slot": entry[0], "unitDefId": "fixture.character." + entry[1], "level": 1, "skills": [],
			"equipmentIds": [], "items": [], "useSlots": []})
	return {"schemaVersion": 2, "battleId": "auto-support", "seed": "13", "encounterId": "fixture.encounter.sp_trial",
		"party": members}


static func _set_hp(unit: BattleUnit, value: int) -> void:
	unit.asc.initialize_attribute_overrides({"hp": float(value)} as Dictionary[String, float])


## HP missing (whole HP) on P2 and P3.
func _hurt(battle: Battle, p2_missing: int, p3_missing: int) -> void:
	for pair in [[&"P2", p2_missing], [&"P3", p3_missing]]:
		var unit := battle.unit_by_id(pair[0])
		_set_hp(unit, unit.stat(BattleUnit.MAX_HP) - int(pair[1]) * 100)


func _heal_pick(battle: Battle) -> Array:
	var policy := _policy()
	var unit := battle.unit_by_id(&"P1")
	var pick := policy._heal(battle, unit, policy._activatable(unit))
	return [pick.get("ability", &""), pick.get("target", &"")]


func test_restore_reader_matches_what_the_heal_restores() -> void:
	var battle := new_battle(_support_snapshot())
	var psalmist := battle.unit_by_id(&"P1")
	var chanter := battle.unit_by_id(&"P2")
	for case in [[&"Fixture.Ability.AsMend", 30000], [&"Fixture.Ability.AsGreatMend", 45000]]:
		_set_hp(chanter, 30000)
		var ability := psalmist.ability_by_tag(case[0])
		eq(RestoreReader.hp_restore(ability, psalmist, chanter), case[1], "%s reads %d" % case)
		check(await battle._activate(psalmist, ability, chanter), "%s casts" % case[0])
		eq(chanter.stat(BattleUnit.HP) - 30000, case[1], "%s restores what the reader says" % case[0])
	# A HoT: its ticks over its duration.
	_set_hp(chanter, 30000)
	var renew := psalmist.ability_by_tag(&"Fixture.Ability.AsRenew")
	eq(RestoreReader.hp_restore(renew, psalmist, chanter), 14400, "Renew: 6% of 1200 HP (72) a tick, 2 ticks")
	check(await battle._activate(psalmist, renew, chanter), "Renew casts")
	chanter.asc.turn_start()
	chanter.asc.turn_start()
	chanter.asc.turn_start()  # nothing left to tick
	eq(chanter.stat(BattleUnit.HP) - 30000, 14400, "Renew restores its counted ticks")
	# Both ways through the fixture ExecCalc: restore_of is the execute formula.
	var calc: Variant = (load("res://tests/fixtures/effects/as_heal_300_bonus.tres") as GameplayEffect).executions[0]
	eq(calc.restore_of(psalmist.asc, chanter.asc), {"hp": 45000}, "the source bonus (the psalmist's 150% SP gain)")
	eq(calc.restore_of(chanter.asc, chanter.asc), {"hp": 30000}, "a 100% source")
	eq(RestoreReader.hp_restore(psalmist.ability_by_tag(&"Fixture.Ability.AsAnthem"), psalmist, chanter), 0, "a buff restores 0")


func test_auto_heals_by_effective_healing() -> void:
	var battle := new_battle(_support_snapshot())
	_hurt(battle, 300, 300)
	eq(_heal_pick(battle), [&"Fixture.Ability.AsMassMend", &""], "two allies down 300: the party heal (600 vs 450)")
	_hurt(battle, 500, 0)
	eq(_heal_pick(battle), [&"Fixture.Ability.AsGreatMend", &"P2"], "one ally down 500: the big heal (450 is 150% of 300)")
	_hurt(battle, 320, 0)
	eq(_heal_pick(battle), [&"Fixture.Ability.AsMend", &"P2"], "one ally down 320: the small heal (320 is 107% of 300)")
	_hurt(battle, 0, 0)
	eq(_heal_pick(battle), [&"", &""], "a heal that would only overheal is never picked")
	# Ties: same SP and healing, the most hurt target (P3 63% under P2 66%).
	_hurt(battle, 400, 400)
	var policy := _policy()
	var mend: Array[BattleAbility] = [battle.unit_by_id(&"P1").ability_by_tag(&"Fixture.Ability.AsMend")]
	eq(policy._heal(battle, battle.unit_by_id(&"P1"), mend), {"ability": &"Fixture.Ability.AsMend", "target": &"P3"},
		"a tie goes to the most hurt target")
	eq(policy.last_detail, "E=300", "the detail is the effective healing")


## Review fix: a costlier heal must reach HEAL_STEP% of every cheaper heal, not only of the pick so far.
func test_a_costlier_heal_must_beat_every_cheaper_one() -> void:
	var battle := new_battle(_support_snapshot())
	_hurt(battle, 360, 80)  # Mend 300; Great Mend 360 (120%: not enough); Mass Mend 300 + 80 = 380 (127% of Mend, 106% of Great)
	eq(_heal_pick(battle), [&"Fixture.Ability.AsMend", &"P2"], "the party heal is not 125% of the big heal: the small one")


## Review fix: a REFRESH_DURATION HoT already on the target at its stack cap counts only the ticks a refresh adds.
func test_a_running_hot_counts_only_the_refreshed_ticks() -> void:
	var battle := new_battle(_support_snapshot())
	var psalmist := battle.unit_by_id(&"P1")
	var chanter := battle.unit_by_id(&"P2")
	var regen: GameplayEffect = (load("res://tests/fixtures/effects/as_renew.tres") as GameplayEffect).duplicate()
	regen.stacking_policy = GameplayEffect.StackingPolicy.REFRESH_DURATION
	regen.max_stacks = 1
	eq(RestoreReader.effect_restore(regen, psalmist.asc, chanter.asc), {"hp": 14400}, "not running: both ticks")
	chanter.asc.apply_gameplay_effect(regen, psalmist.asc, 1)
	eq(RestoreReader.effect_restore(regen, psalmist.asc, chanter.asc), {}, "just applied: a refresh adds nothing")
	chanter.asc.turn_start()
	eq(RestoreReader.effect_restore(regen, psalmist.asc, chanter.asc), {"hp": 7200}, "one tick gone: a refresh adds one")


func test_a_cleansing_heal_wins_at_equal_healing_while_an_ally_is_afflicted() -> void:
	var battle := new_battle(_support_snapshot())
	_hurt(battle, 500, 0)
	eq(_heal_pick(battle)[0], &"Fixture.Ability.AsGreatMend", "nobody afflicted: Purge Mend (450 for 60) misses the 125% step")
	battle.unit_by_id(&"P2").asc.add_tag(Battle.CONTROLLED_TAG)
	eq(_heal_pick(battle), [&"Fixture.Ability.AsPurgeMend", &"P2"], "afflicted: the cleansing heal at equal healing")
	_hurt(battle, 400, 400)
	eq(_heal_pick(battle)[0], &"Fixture.Ability.AsMassMend", "afflicted but the cleansing heal heals less (400 vs 800)")


func test_spread_hurt_heals_before_anyone_is_critical() -> void:
	var battle := new_battle(_support_snapshot())
	_set_hp(battle.unit_by_id(&"P2"), 78000)  # 65%
	_set_hp(battle.unit_by_id(&"P3"), 74800)  # 68%
	check(not AutoPolicy._party_hurt(battle), "nobody under 45%")
	var policy := _policy()
	policy.choose(battle, battle.unit_by_id(&"P1"))
	eq(policy.last_reason, "heal", "two allies under 70%: a heal")
	_set_hp(battle.unit_by_id(&"P3"), 110000)
	policy.choose(battle, battle.unit_by_id(&"P1"))
	check(policy.last_reason != "heal", "one ally under 70%%: no heal (%s)" % policy.last_reason)


func test_party_buff() -> void:
	var battle := new_battle(_support_snapshot())
	var psalmist := battle.unit_by_id(&"P1")
	var policy := _policy()
	var actions := policy._activatable(psalmist)
	eq(policy._party_buff(battle, psalmist, actions, 0), {"ability": &"Fixture.Ability.AsGrandAnthem", "target": &""},
		"three allies lack it: the costlier rank")
	eq(policy._party_buff(battle, psalmist, actions, 7000), {"ability": &"Fixture.Ability.AsAnthem", "target": &""},
		"only the cheaper one is payable above a 70 SP reserve")
	eq(policy._party_buff(battle, psalmist, actions, 8000), {}, "neither above an 80 SP reserve")
	eq(policy.choose(battle, psalmist).get("ability"), &"Fixture.Ability.AsGrandAnthem", "choose casts it at battle start")
	eq(policy.last_reason, "party buff", "as a party buff")
	battle.unit_by_id(&"P2").asc.add_tag(&"Status.Buff.AttackUp")
	battle.unit_by_id(&"P3").asc.add_tag(&"Status.Buff.AttackUp")
	eq(policy._party_buff(battle, psalmist, actions, 0), {}, "only one ally lacks it")
	battle.unit_by_id(&"P2").asc.remove_tag(&"Status.Buff.AttackUp")
	battle.unit_by_id(&"P3").asc.remove_tag(&"Status.Buff.AttackUp")
	_set_hp(battle.unit_by_id(&"P2"), 30000)  # 25%: the party is in danger
	eq(policy._party_buff(battle, psalmist, actions, 0), {}, "not while the party is in danger")
	_set_hp(battle.unit_by_id(&"P2"), 120000)
	for enemy in AutoPolicy._enemies_of(battle, psalmist):
		@warning_ignore("integer_division")
		_set_hp(enemy, enemy.stat(BattleUnit.MAX_HP) / 5)
	eq(policy._party_buff(battle, psalmist, actions, 0), {}, "not when every enemy is under 25%")
	# The cap and fallback buff take 3.3's order too.
	eq(policy._buff(battle, psalmist, actions), {"ability": &"Fixture.Ability.AsGrandAnthem", "target": &""},
		"the fallback buff: most allies lacking, then the higher cost")


func test_a_unit_without_a_basic_keeps_the_old_buff_rule() -> void:
	var battle := new_battle(_support_snapshot("hymnist"))
	var policy := _policy()
	policy.choose(battle, battle.unit_by_id(&"P1"))
	check(policy.last_reason != "party buff", "no party buff before damage without a basic (%s)" % policy.last_reason)


func test_support_picks_are_deterministic_and_draw_no_rng() -> void:
	var battle := new_battle(_support_snapshot())
	_hurt(battle, 300, 300)
	var before := battle.rng.state
	var first := _policy().choose(battle, battle.unit_by_id(&"P1"))
	var second := _policy().choose(battle, battle.unit_by_id(&"P1"))
	eq(first, second, "the same state gives the same pick")
	eq(battle.rng.state, before, "no draw from the battle's RNG")


func test_auto_picks_are_tallied_per_class() -> void:
	var battle := new_battle(_support_snapshot())
	var policy := _policy()
	var tally := {}
	policy.tally = tally
	policy.choose(battle, battle.unit_by_id(&"P1"))
	eq(tally, {"fixture.character.psalmist": {"reasons": {"party buff": 1},
		"abilities": {"party buff": {"Fixture.Ability.AsGrandAnthem": 1}}}}, "one party buff counted")
	var block := PlayReport.auto_picks_block([{"autoPicks": tally}, {"autoPicks": tally}] as Array[Dictionary])
	eq(block["fixture.character.psalmist"]["reasons"]["party buff"], 2, "runs merge by sum")
