## Spec skill-points: SP gain on basic attacks, scaled SP costs read by CostReader, growth of SP gain and max SP, level
## skills (a rank replacing rank I, an enemy's secret skill), one level concept (D21), the read-only level attribute
## (D22) and the mirror's skip tags (D14), all on frozen fixtures (the chanter and the keepers of the sp trial).
extends TestCase

const CHANTER := "fixture.character.chanter"

var _handles: Array = []
var _runs: Array = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


## Chanters at `levels` (each carrying `mp` ×100 when given) against the sp trial: keeper E1 at level 1, keeper E2 at
## level 2 through its slot's level bonus.
static func sp_snapshot(seed_text: String = "13", levels: Array = [1, 3], mp: Variant = null) -> Dictionary:
	var members: Array = []
	for index in levels.size():
		var member := {"slot": index + 1, "unitDefId": CHANTER, "level": levels[index], "skills": [], "equipmentIds": [],
			"items": [], "useSlots": []}
		if mp != null:
			member["mp"] = mp
		members.append(member)
	return {"schemaVersion": 2, "battleId": "sp-seed-%s" % seed_text, "seed": seed_text,
		"encounterId": "fixture.encounter.sp_trial", "party": members}


func _act(battle: Battle, actor_id: StringName, tag: StringName, target_id: StringName = &"E1") -> bool:
	var actor := battle.unit_by_id(actor_id)
	var done: bool = await battle._activate(actor, actor.ability_by_tag(tag), battle.unit_by_id(target_id))
	await battle._drain_triggers()
	return done


func test_basic_attack_gains_sp() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 1000))
	check(await _act(battle, &"P1", &"Fixture.Ability.ChantJab"), "the level-1 chanter jabs")
	eq(battle.unit_by_id(&"P1").stat("mp"), 2700, "10 SP + 17 per basic")
	check(await _act(battle, &"P2", &"Fixture.Ability.ChantJab"), "the level-3 chanter jabs")
	eq(battle.unit_by_id(&"P2").stat("mp"), 2900, "17 × 114% = 19.38, truncated to 19")
	check(await _act(battle, &"P1", &"Fixture.Ability.ChantBurst"), "rank I costs 25")
	eq(battle.unit_by_id(&"P1").stat("mp"), 200, "a costed ability gains nothing")


func test_basic_at_full_sp_restores_nothing() -> void:
	var battle := new_battle(sp_snapshot())
	await _act(battle, &"P1", &"Fixture.Ability.ChantJab")
	eq(battle.unit_by_id(&"P1").stat("mp"), 6000, "the mp clamp holds at the cap")


func test_cost_is_scaled_and_refused_when_short() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 2400))
	var chanter := battle.unit_by_id(&"P1")
	var burst := chanter.ability_by_tag(&"Fixture.Ability.ChantBurst")
	eq(CostReader.sp_cost(burst, chanter.asc), 2500, "the cost the battle would take")
	check(not chanter.asc.can_activate_ability(burst), "1 SP short: refused")
	var thrift := GameplayEffect.new()
	thrift.policy = GameplayEffect.DurationPolicy.INFINITE
	var modifier := CombatModifier.new()
	modifier.attribute_name = "sp_cost"
	modifier.operation = GameplayEffectModifier.Operation.PERCENT_ADD
	modifier.value_x100 = -2100
	thrift.modifiers.append(modifier)
	chanter.asc.apply_gameplay_effect(thrift, chanter.asc, 1)
	eq(CostReader.sp_cost(burst, chanter.asc), 1900, "25 × 79% = 19.75, truncated to 19 in the caster's favour")
	eq(AbilityHint.cost_text(burst, chanter), "19 SP", "the hint shows the unit's cost")
	eq(AbilityHint.cost_text(burst), "25 SP", "without a unit, the base cost")
	check(chanter.asc.can_activate_ability(burst), "affordable now")
	check(await _act(battle, &"P1", &"Fixture.Ability.ChantBurst"), "cast")
	eq(chanter.stat("mp"), 500, "the scaled cost was taken")


func test_exact_cost_is_affordable() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 2500))
	var chanter := battle.unit_by_id(&"P1")
	check(chanter.asc.can_activate_ability(chanter.ability_by_tag(&"Fixture.Ability.ChantBurst")), "exactly the cost")


func test_growth_raises_sp_gain_and_pool() -> void:
	var battle := new_battle(sp_snapshot())
	var low := battle.unit_by_id(&"P1")
	var high := battle.unit_by_id(&"P2")
	eq(low.stat("sp_gain"), 10000, "level 1: 100%")
	eq(high.stat("sp_gain"), 11400, "level 3: +7% per level above 1")
	eq(high.stat("max_mp"), 6840, "the pool grows by the same 14%")


func test_rank_replaces_rank_one() -> void:
	var battle := new_battle(sp_snapshot())
	var low := battle.unit_by_id(&"P1")
	var high := battle.unit_by_id(&"P2")
	check(low.ability_by_tag(&"Fixture.Ability.ChantBurst") != null, "level 1 keeps rank I")
	check(low.ability_by_tag(&"Fixture.Ability.ChantBurstTwo") == null, "and has no rank II")
	check(high.ability_by_tag(&"Fixture.Ability.ChantBurstTwo") != null, "level 3 has rank II")
	check(high.ability_by_tag(&"Fixture.Ability.ChantBurst") == null, "rank II replaced rank I")
	eq(CostReader.sp_cost(high.ability_by_tag(&"Fixture.Ability.ChantBurstTwo"), high.asc), 3700, "rank II costs more")


func test_secret_skill_and_one_level_concept() -> void:
	var battle := new_battle(sp_snapshot())
	var plain := battle.unit_by_id(&"E1")
	var leveled := battle.unit_by_id(&"E2")
	eq(plain.level, 1, "slot 1: depth level 1")
	eq(leveled.level, 2, "slot 2: +1 from its slot")
	check(plain.ability_by_tag(&"Fixture.Ability.SecretSlam") == null, "below the secret skill's level: absent")
	check(leveled.ability_by_tag(&"Fixture.Ability.SecretSlam") != null, "at its level: present")
	eq(leveled.effect_level, 1, "an enemy's GAS level stays 1")
	for ability in leveled.abilities():
		eq(ability.ability_level, 1, "%s is granted at GAS level 1" % ability.ability_tag)
	var party := battle.unit_by_id(&"P2")
	eq(party.effect_level, 3, "a party member's GAS level is its level")


func test_variant_and_depth_raise_enemy_level() -> void:
	var rules := ScalingRules.new()
	eq(rules.level_for_depth(4), 1, "an empty table: level 1")
	rules.enemy_level_by_depth.assign([1, 3, 5])
	eq(rules.level_for_depth(0), 1, "depth 0")
	eq(rules.level_for_depth(1), 3, "depth 1")
	eq(rules.level_for_depth(9), 5, "past the end: the last value")
	var elite: EnemyVariant = fixtures().variants[&"fixture.variant.elite"]
	var before := elite.level_bonus
	elite.level_bonus = 1
	var snap := sp_snapshot()
	snap["enemies"] = [{"slot": 1, "unitDefId": "fixture.enemy.keeper", "loadoutRef": null,
		"variantId": "fixture.variant.elite"}]
	var battle := new_battle(snap)
	elite.level_bonus = before
	eq(battle.unit_by_id(&"E1").level, 2, "an elite variant adds its level bonus")
	check(battle.unit_by_id(&"E1").ability_by_tag(&"Fixture.Ability.SecretSlam") != null, "and reaches the secret skill")


func test_level_attribute_is_read_only() -> void:
	var battle := new_battle(sp_snapshot())
	var high := battle.unit_by_id(&"P2")
	eq(high.stat("level"), 300, "level 3, stored ×100")
	eq(battle.unit_by_id(&"E2").stat("level"), 200, "an enemy's level too")
	var bump := GameplayEffect.new()
	bump.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := CombatModifier.new()
	modifier.attribute_name = "level"
	modifier.operation = GameplayEffectModifier.Operation.ADD
	modifier.value_x100 = 500
	bump.modifiers.append(modifier)
	high.asc.apply_gameplay_effect(bump, high.asc, 1)
	eq(high.stat("level"), 300, "an effect can't change it")
	var lines: Array = StateHasher.canonical_lines(battle)["lines"]
	check(lines.has("attr=P2|level|300|300"), "it is in the state hash")


func test_record_replay_and_tampers() -> void:
	var request := await record(sp_snapshot())
	var actions: Array = request["actionLog"]["actions"]
	check(actions.any(func(entry) -> bool: return entry["ability"] == "Fixture.Ability.ChantJab"), "basics were used")
	check(actions.any(func(entry) -> bool: return entry["ability"] == "Fixture.Ability.ChantBurstTwo"), "rank II was used")
	eq((await replay(request)).get("verdict"), "Verified", "SP, costs and level skills replay")
	for tampered in [sp_tampered_cost(request), sp_tampered_unlearned(request)]:
		var result := await replay(tampered)
		eq(result.get("verdict"), "Rejected", "a tampered log is rejected")
		eq(result.get("mismatch", {}).get("reason"), "IllegalAbility", "with IllegalAbility (2002)")


## The level-1 chanter's first basic attack (cast because it couldn't pay for rank I) claimed as rank I instead.
static func sp_tampered_cost(request: Dictionary) -> Dictionary:
	var tampered := copy(request)
	for entry in tampered["actionLog"]["actions"]:
		if entry["actor"] == "P1" and entry["ability"] == "Fixture.Ability.ChantJab":
			entry["ability"] = "Fixture.Ability.ChantBurst"
			break
	return tampered


## The level-3 chanter's first rank II cast claimed as rank I, which rank II replaced.
static func sp_tampered_unlearned(request: Dictionary) -> Dictionary:
	var tampered := copy(request)
	for entry in tampered["actionLog"]["actions"]:
		if entry["actor"] == "P2" and entry["ability"] == "Fixture.Ability.ChantBurstTwo":
			entry["ability"] = "Fixture.Ability.ChantBurst"
			break
	return tampered


func test_mirror_skip_tags() -> void:
	var snap: Dictionary = preload("res://tests/combat/test_mirror.gd").mirror_snapshot()
	snap["party"][0]["items"] = ["fixture.item.leech"]
	var mirror: EnemyDefinition = fixtures().units[&"fixture.enemy.mirror"]
	var copied := new_battle(snap)
	check(copied.unit_by_id(&"E1").asc.has_tag(&"Drain.Physical"), "without skip tags the boss copies the drain")
	mirror.mirror_skip_tags.assign([&"Drain"])
	var skipped := new_battle(snap)
	mirror.mirror_skip_tags.clear()
	check(not skipped.unit_by_id(&"E1").asc.has_tag(&"Drain.Physical"), "with Drain skipped it doesn't")
	check(skipped.unit_by_id(&"P1").asc.has_tag(&"Drain.Physical"), "the holder keeps it")


func test_level_up_announces_learned_skill() -> void:
	var run := start_run(host, "5", [CHANTER])
	_runs.append(run)
	var leveled: RunStructure = run.structure.duplicate()
	var curve: Array[int] = [50, 120, 400]  # a new array: the fixture run's curve stays empty
	leveled.xp_to_level = curve
	run.structure = leveled
	var heard := []
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.RUN_SKILL_LEARNED,
		func(_on: StringName, message): heard.append(message)))
	var before := run.run_log.size()
	run.gain_levels(1, null)
	eq(heard.size(), 0, "level 2: nothing learned")
	run.gain_levels(5, null)
	eq(heard.size(), 1, "a jump past level 3 announces rank II once")
	if heard.size() == 1:
		eq(heard[0].data.get("skillTag"), "Fixture.Ability.ChantBurstTwo", "the skill learned")
		eq(heard[0].data.get("replacesTag"), "Fixture.Ability.ChantBurst", "and the rank it replaces")
	eq(run.run_log.size(), before, "learning logs nothing: the level already does")
	var snap := run.battle_snapshot() if not run.pending_battle.is_empty() else {}
	check(snap.is_empty() or snap["party"][0]["skills"].is_empty(), "level skills never enter the run state's skills")


## Spec skill-points 3.4: the player's Auto (and the smart policy) on the rhythm.
func _auto(battle: Battle, unit_id: StringName) -> Dictionary:
	return AutoPolicy.new(AutoPolicy.Options.new(), fixtures()).choose(battle, battle.unit_by_id(unit_id))


func test_auto_builds_sp_then_spends() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 1], 2000))
	eq(_auto(battle, &"P1")["ability"], &"Fixture.Ability.ChantJab", "20 SP: can't pay 25, so a basic")
	battle = new_battle(sp_snapshot("13", [1, 1], 3000))
	eq(_auto(battle, &"P1")["ability"], &"Fixture.Ability.ChantBurst", "30 SP: rank I scores well over 150% of a basic")


func test_auto_spends_at_the_cap() -> void:
	var battle := new_battle(sp_snapshot())
	check(AutoPolicy.basic_would_overflow(battle.unit_by_id(&"P1")), "full SP: a basic would be wasted")
	battle = new_battle(sp_snapshot("13", [1, 1], 1000))
	check(not AutoPolicy.basic_would_overflow(battle.unit_by_id(&"P1")), "10 of 60: room for a basic")


func test_auto_keeps_a_heal_while_in_danger() -> void:
	var snap := sp_snapshot("13", [1, 1], 3000)
	snap["party"][0]["unitDefId"] = "fixture.character.cantor"
	var calm := new_battle(snap)
	eq(_auto(calm, &"P1")["ability"], &"Fixture.Ability.ChantBurst", "no danger: the cantor spends 25 of its 30 SP")
	snap["party"][1]["hp"] = 0
	var danger := new_battle(snap)
	eq(AutoPolicy.danger_reserve(danger, danger.unit_by_id(&"P1")), 2500, "an ally down: keep the hymn's 25 SP")
	eq(_auto(danger, &"P1")["ability"], &"Fixture.Ability.ChantJab", "so it builds SP instead of bursting")
	var scripted := ScriptedController.new()
	for turn in 3:
		var pick: Dictionary = scripted.choose(danger, danger.unit_by_id(&"P1"))
		check(pick["ability"] != &"Fixture.Ability.ChantBurst", "the auto policy keeps the reserve too (pick %d)" % turn)


func test_units_without_a_basic_keep_the_old_rule() -> void:
	var battle := new_battle(preload("res://tests/combat/test_battle_v2.gd").v2_snapshot())
	check(not AutoPolicy.has_basic(battle.unit_by_id(&"P1")), "the fixture knight has no basic attack")
	eq(AutoPolicy.danger_reserve(battle, battle.unit_by_id(&"P1")), 0, "it holds no SP reserve: its cost isn't an SP ExecCalc")


func test_chaos_tries_unaffordable_moves() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 1000))
	var chaos := ChaosController.new(RunSeeds.rng(13, "dev/chaos/test"), 10000)  # an illegal try at every decision
	await battle.run(chaos)
	check(int(chaos.refused.get("unaffordable", 0)) > 0, "chaos submitted moves it couldn't pay for")
	eq(chaos.violations, [], "and every one was refused without changing the battle")


## Spec skill-points: the hint names the caster and the SP a move costs it, and a party row previews it on its SP bar.
func test_hint_carries_the_sp_preview() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 3000))
	var chanter := battle.unit_by_id(&"P1")
	var hint := AbilityHint.of(chanter, chanter.ability_by_tag(&"Fixture.Ability.ChantBurst"))
	eq(hint["unit"], "P1", "the caster")
	eq(hint["spCost"], 25, "its whole SP cost")
	eq(AbilityHint.of(chanter, chanter.ability_by_tag(&"Fixture.Ability.ChantJab"))["spCost"], 0, "a basic costs nothing")
	var row: Control = load("res://presentation/demo/ui/member_row.tscn").instantiate()
	host.add_child(row)
	row.set_item({"name": "Chanter", "hp": 10, "hp_max": 10, "mp": 30, "mp_max": 60, "mp_preview": 25}, null)
	eq(row.get_node("%MpBar").value, 5.0, "the bar shows what the move leaves")
	check(row.get_node("%MpText").text.contains("25"), "and the numbers show the cost")
	row.set_item({"name": "Chanter", "hp": 10, "hp_max": 10, "mp": 30, "mp_max": 60}, null)
	eq(row.get_node("%MpBar").value, 30.0, "no preview: the full bar")
	row.free()


## Spec skill-points: the Status screen's kit lists a level skill not reached yet with the level that unlocks it.
func test_member_kit_lists_locked_skills() -> void:
	var run := start_run(host, "5", [CHANTER])
	_runs.append(run)
	var locked := run.member_kit(1).filter(func(entry) -> bool: return entry["name"] == "Chant Burst 2")
	eq(locked.size(), 1, "rank II is listed before it is learned")
	if locked.size() == 1:
		eq(locked[0]["unlock_level"], 3, "with its level")
	check(run.member_kit(1).any(func(entry) -> bool: return entry["name"] == "Chant Burst" and entry["unlock_level"] == 0),
		"rank I is in the kit")


## Spec skill-points D19: a brain with level_skill_every uses the secret skill the unit has reached; a unit below its
## level never does, and 0 (the default) leaves the brain as it was.
func test_brain_uses_reached_secret_skill() -> void:
	var battle := new_battle(sp_snapshot())
	var brain := EnemyBrain.new()
	eq(brain.level_skill_choice(battle.unit_by_id(&"E2"), battle), {}, "off by default")
	brain.level_skill_every = 1
	eq(brain.choose(battle.unit_by_id(&"E2"), battle)["ability"], &"Fixture.Ability.SecretSlam", "the level-2 keeper uses it")
	eq(brain.choose(battle.unit_by_id(&"E1"), battle)["ability"], &"Fixture.Ability.Claw", "the level-1 keeper can't")


## Spec skill-points: the optional battle log (BattleLog) shows actions, triggers, Auto's picks with a reason and the
## outcome; it changes nothing (the same final hash with it on).
func test_battle_log() -> void:
	var quiet := await record_auto(sp_snapshot())
	var lines: Array = []
	var was := BattleLog.enabled
	BattleLog.enabled = true
	BattleLog.sink = lines
	var logged := await record_auto(sp_snapshot())
	BattleLog.enabled = was
	BattleLog.sink = null
	check(lines.any(func(text) -> bool: return text.contains("auto P1 picks")), "Auto's picks are logged")
	check(lines.any(func(text) -> bool: return text.contains("(basic)") or text.contains("(ability)")), "with a reason")
	check(lines.any(func(text) -> bool: return text.contains("trigger") and text.contains("Fixture.Ability.SpGain")),
		"triggered passives are logged")
	check(lines.any(func(text) -> bool: return text.contains("ended:")), "and the outcome")
	eq(logged["actionLog"]["claimedFinalHash"], quiet["actionLog"]["claimedFinalHash"], "logging changes nothing")


## Spec skill-points: the soft enrage. From its overtime turn on, an enemy gets its overtime effect at each of its
## turns (stacking); none set, nothing changes.
func test_overtime_enrage() -> void:
	var keeper: EnemyDefinition = fixtures().units[&"fixture.enemy.keeper"]
	var plain := new_battle(sp_snapshot())
	await plain.run(ScriptedController.new())
	keeper.overtime_turn = 1
	keeper.overtime_effect = load("res://tests/fixtures/effects/per_item_boost.tres")
	var raging := new_battle(sp_snapshot())
	var e2 := raging.unit_by_id(&"E2")
	var before := e2.stat("atk")
	await raging.run(ScriptedController.new())
	keeper.overtime_turn = 0
	keeper.overtime_effect = null
	check(e2.stat("atk") > before or not e2.alive, "its ATK grew each of its turns")
	var stacks := 0
	for active_effect in e2.asc._active_effects:
		if active_effect.get_effect_def().resource_path.ends_with("per_item_boost.tres"):
			stacks += 1
	check(stacks >= 1, "one stack per turn (%d)" % stacks)
	check(plain.unit_by_id(&"E2").asc._active_effects.all(func(active_effect) -> bool:
		return not active_effect.get_effect_def().resource_path.ends_with("per_item_boost.tres")), "no overtime set: no stacks")


## Spec skill-points: in overtime, the party effect reaches every living party unit at each of the enemy's turns (here
## a 5-turn Poison from turn 1, against the same battle without it).
func test_overtime_party_effect() -> void:
	var keeper: EnemyDefinition = fixtures().units[&"fixture.enemy.keeper"]
	var plain := new_battle(sp_snapshot())
	await plain.run(ScriptedController.new())
	keeper.overtime_turn = 1
	keeper.overtime_party_effect = load("res://tests/fixtures/effects/st_poison.tres")
	var hurt := new_battle(sp_snapshot())
	await hurt.run(ScriptedController.new())
	keeper.overtime_turn = 0
	keeper.overtime_party_effect = null
	var total := func(battle: Battle) -> int:
		return battle.unit_by_id(&"P1").stat("hp") + battle.unit_by_id(&"P2").stat("hp")
	check(total.call(hurt) < total.call(plain) or hurt.outcome != plain.outcome, "the party lost HP to the overtime effect")


## Spec skill-points 4.1: a One More's extra action that is a basic gains SP like any other basic.
func test_one_more_basic_gains_sp() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 1000))
	battle.extra_action = true
	check(await _act(battle, &"P1", &"Fixture.Ability.ChantJab"), "the extra action is a basic")
	eq(battle.unit_by_id(&"P1").stat("mp"), 2700, "and gains 17 SP")


## Spec skill-points 4.1: only Event.Ability.Used.Basic restores SP; follow-ups (fired from the trigger queue, which
## sends no Used event) and ults gain nothing.
func test_follow_ups_and_ults_gain_no_sp() -> void:
	var battle := new_battle(sp_snapshot("13", [1, 3], 1000))
	var chanter := battle.unit_by_id(&"P1")
	chanter.asc.send_gameplay_event(&"Event.Ability.Used.FollowUp", {"source": chanter, "target": chanter})
	chanter.asc.send_gameplay_event(&"Event.Ability.Used.Ultimate", {"source": chanter, "target": chanter})
	await battle._drain_triggers()
	eq(chanter.stat("mp"), 1000, "a follow-up or ult event restores nothing")
	chanter._grant_ability(load("res://tests/fixtures/abilities/ult_nova.tscn"), &"")
	chanter.asc.initialize_attribute_overrides({"energy": 10000.0})
	var ult := chanter.ability_by_tag(&"Fixture.Ability.UltNova")
	check(ult != null and await battle._activate(chanter, ult, null), "an ult is cast")
	await battle._drain_triggers()
	eq(chanter.stat("mp"), 1000, "and gains no SP")


## Spec skill-points 4.1: in field mode an SP cost is scaled by sp_cost too (the cantor's Hymn, 25 SP, at 79%).
func test_field_cost_is_scaled() -> void:
	var snap := sp_snapshot("13", [1], 4000)
	snap["party"][0]["unitDefId"] = "fixture.character.cantor"
	var field := Battle.new()
	host.add_child(field)
	_runs.append(field)
	eq(field.setup_field(snap, fixtures()), "", "a field battle")
	var cantor := field.unit_by_id(&"P1")
	var thrift := GameplayEffect.new()
	thrift.policy = GameplayEffect.DurationPolicy.INFINITE
	var modifier := CombatModifier.new()
	modifier.attribute_name = "sp_cost"
	modifier.operation = GameplayEffectModifier.Operation.PERCENT_ADD
	modifier.value_x100 = -2100
	thrift.modifiers.append(modifier)
	cantor.asc.apply_gameplay_effect(thrift, cantor.asc, 1)
	eq(await field.perform(&"P1", &"Fixture.Ability.Hymn", &"P1"), [], "Hymn on the map")
	eq(cantor.stat("mp"), 4000 - 1900, "25 × 79% = 19 SP")


## Spec skill-points D18: a level jump announces each level skill it reaches, once each.
func test_level_jump_announces_each_skill() -> void:
	var chanter: CharacterDefinition = fixtures().characters[&"fixture.character.chanter"]
	var extra := LevelSkill.new()
	extra.level = 4
	extra.ability = load("res://tests/fixtures/abilities/secret_slam.tscn")
	chanter.level_skills.append(extra)
	var run := start_run(host, "5", [CHANTER])
	_runs.append(run)
	var leveled: RunStructure = run.structure.duplicate()
	var curve: Array[int] = [50, 120, 400]
	leveled.xp_to_level = curve
	run.structure = leveled
	var heard := []
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.RUN_SKILL_LEARNED,
		func(_on: StringName, message): heard.append(message.data.get("skillTag"))))
	run.gain_levels(3, null)
	chanter.level_skills.erase(extra)
	eq(heard, ["Fixture.Ability.ChantBurstTwo", "Fixture.Ability.SecretSlam"], "levels 3 and 4, one message each")


## Spec skill-points D2 (fallback): RunStructure.sp_start_min raises a low carried SP at battle start; off, it carries.
func test_sp_start_min() -> void:
	var run := start_run(host, "5", [CHANTER])
	_runs.append(run)
	run.state.party[0]["mp"] = 0
	eq(run._with_sp_floor(run.party_capture(false))[0]["mp"], 0, "off: SP carries as it is")
	var floored: RunStructure = run.structure.duplicate()
	floored.sp_start_min_x100 = 5000
	run.structure = floored
	eq(run._with_sp_floor(run.party_capture(false))[0]["mp"], 3000, "50% of 60 max SP")
	run.state.party[0]["mp"] = 4500
	eq(run._with_sp_floor(run.party_capture(false))[0]["mp"], 4500, "more than the floor: unchanged")


## Spec skill-points D13 (b): mirror_limit copies only the first N pieces and counts no more for the per-item effect.
func test_mirror_limit() -> void:
	var mirror: EnemyDefinition = fixtures().units[&"fixture.enemy.mirror"]
	mirror.mirror_limit = 2
	var battle := new_battle(preload("res://tests/combat/test_mirror.gd").mirror_snapshot())
	mirror.mirror_limit = 0
	var stacks := 0
	for active_effect in battle.unit_by_id(&"E1").asc._active_effects:
		if active_effect.get_effect_def().resource_path.ends_with("per_item_boost.tres"):
			stacks += 1
	eq(stacks, 2, "6 pieces held, 2 counted")


## Spec skill-points: the console's status shows a party unit's SP, gain and cost, and nothing for enemies.
func test_status_sp_text() -> void:
	var battle := new_battle(sp_snapshot("13", [3], 1000))
	var status_command := preload("res://game/dev/commands/status.gd")
	eq(status_command.sp_text(battle.unit_by_id(&"P1")), " · SP 10/68 (+19 a basic, gain 114%, cost 100%)", "the chanter")
	eq(status_command.sp_text(battle.unit_by_id(&"E1")), "", "enemies have no SP")
