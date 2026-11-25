## Spec item-power 2.1: the kernel hooks K1 (ally events), K2 (DoT tick events), K3 (trigger chance), K4 (random targets),
## K5 (dying), K6 (event amount), K7 (echo) and K8 (copies), on fixtures only: hexer and guard against the status trial,
## the chanter against the keepers.
extends TestCase

const Statuses := preload("res://tests/combat/test_statuses.gd")


## hexer (P1) and guard (P2) holding the named ip_* items against the status trial (E1 wisp, E2 toad, E3 imp).
static func power_snapshot(items: Dictionary, name: String, seed_text: String, hp: Dictionary = {}, encounter: String = "status_trial") -> Dictionary:
	var held := {}
	for slot in items:
		held[slot] = items[slot].map(func(item: String) -> String: return "ip_" + item)
	var snap: Dictionary = Statuses.status_snapshot(["hexer", "guard"], encounter, seed_text, held)
	snap["battleId"] = "%s-seed-%s" % [name, seed_text]
	return _with_hp(snap, hp)


## Carried HP right after `level`: the PartyMemberSnapshot field order.
static func _with_hp(snap: Dictionary, hp: Dictionary) -> Dictionary:
	var party: Array = []
	for member in snap["party"]:
		if not hp.has(member["slot"]):
			party.append(member)
			continue
		party.append({"slot": member["slot"], "unitDefId": member["unitDefId"], "level": member["level"], "hp": hp[member["slot"]],
			"skills": member["skills"], "equipmentIds": member["equipmentIds"], "items": member["items"],
			"useSlots": member["useSlots"]})
	snap["party"] = party
	return snap


## chanter (P1) and cantor (P2) against the two keepers.
static func sp_snapshot(items: Dictionary, name: String, seed_text: String) -> Dictionary:
	var held := {}
	for slot in items:
		held[slot] = items[slot].map(func(item: String) -> String: return "ip_" + item)
	var snap: Dictionary = Statuses.status_snapshot(["chanter", "cantor"], "sp_trial", seed_text, held)
	snap["battleId"] = "%s-seed-%s" % [name, seed_text]
	return snap


# --- The goldens (test_golden) -------------------------------------------------------------------------------------------

## K1-K4: DoT ticks, chances, random targets, ally counters.
static func proc_golden() -> Dictionary:
	return power_snapshot({1: ["plague", "bell", "hook"], 2: ["vow", "knife"]}, "proc", "17")


## K5: the guard starts nearly dead and is saved once.
static func dying_golden() -> Dictionary:
	return power_snapshot({1: ["vow"], 2: ["undying"]}, "dying", "21", {2: 2000})


## K6, K7: echoed skills, lifesteal, reflect.
static func echo_golden() -> Dictionary:
	return sp_snapshot({1: ["twin", "drink", "splash"], 2: ["reflect"]}, "echo", "23")


## K8: two copies of one item.
static func copies_golden() -> Dictionary:
	return power_snapshot({1: ["copy"], 2: ["copy", "copy"]}, "copies", "29")


func _fired(battle: Battle) -> Array:
	var fired := []
	battle.trigger_activated.connect(func(unit_id, ability_tag, _event):
		fired.append("%s %s" % [unit_id, String(ability_tag).trim_prefix("Fixture.Ability.")]))
	return fired


func _use(battle: Battle, unit_id: String, name: String, target_id: String = "") -> void:
	var unit := battle.unit_by_id(StringName(unit_id))
	await battle._activate(unit, Statuses.ability(unit, name), battle.unit_by_id(StringName(target_id)) if target_id != "" else null)


## Gives a unit an ability scene of the fixtures (an ip_* proc) in a running battle.
func _grant(unit: BattleUnit, name: String) -> BattleAbility:
	var ability: BattleAbility = load(FIXTURES + "abilities/%s.tscn" % name).instantiate()
	unit.asc.add_child(ability)
	return ability


# --- K1 ally events ------------------------------------------------------------------------------------------------------

func test_ally_hit_fires_counters_in_slot_order() -> void:
	var snap: Dictionary = Statuses.status_snapshot(["hexer", "guard", "breaker"], "status_trial", "3",
		{1: ["ip_vow"], 2: ["ip_vow"], 3: ["ip_vow"]})
	var battle := new_battle(snap)
	var fired := _fired(battle)
	var heard := {}
	for unit in battle.units():
		heard[unit.unit_id] = Statuses.listen(unit)
	var hit := battle.unit_by_id(&"P2")
	await _use(battle, "E3", "FireBolt", "P2")
	eq(Statuses.names(heard[&"P2"], "Event.Ally."), [], "the hit unit gets no ally event")
	eq(Statuses.names(heard[&"P1"], "Event.Ally."), ["Event.Ally.Damage.Taken"], "its ally does")
	eq(Statuses.names(heard[&"E1"], "Event.Ally."), [], "not the other side")
	eq(heard[&"P1"][-1][1]["source"].unit_id, &"E3", "same payload: the attacker")
	eq(heard[&"P1"][-1][1]["target"], hit, "and the unit that was hit")
	var attacker_hp := battle.unit_by_id(&"E3").stat(BattleUnit.HP)
	var hit_hp := hit.stat(BattleUnit.HP)
	await battle._drain_triggers()
	eq(fired, ["P1 IpVow", "P1 IpVowHeal", "P3 IpVow", "P3 IpVowHeal"], "slot order, grant order on each unit")
	check(battle.unit_by_id(&"E3").stat(BattleUnit.HP) < attacker_hp, "the counters hit the attacker")
	check(hit.stat(BattleUnit.HP) > hit_hp, "an ally-aimed trigger aims at the ally that was hit")


func test_own_side_damage_sends_no_ally_event() -> void:
	var battle := new_battle(power_snapshot({2: ["vow"]}, "own", "3"))
	var heard := Statuses.listen(battle.unit_by_id(&"P2"))
	var hexer := battle.unit_by_id(&"P1")
	var spec := GameplayEffectSpec.new(load(FIXTURES + "effects/damage.tres"), GameplayEffectContext.new(hexer, hexer), 1)
	battle._send_damage_events(hexer, hexer, 500, ExecutionRow.new(), spec)
	eq(Statuses.names(heard, "Event.Ally."), [], "HP a unit's own side costs it sets off no ally counter")
	check(Statuses.names(Statuses.listen(hexer), "Event.Ally.").is_empty(), "nor on itself")


func test_ally_ultimate_event() -> void:
	var battle := new_battle(power_snapshot({1: ["ult_echo"]}, "ult", "3"))
	var fired := _fired(battle)
	var caster := Statuses.listen(battle.unit_by_id(&"P1"))
	var ally := Statuses.listen(battle.unit_by_id(&"P2"))
	battle.unit_by_id(&"P1").asc.initialize_attribute_overrides({"energy": 10000.0} as Dictionary[String, float])
	await _use(battle, "P1", "UltPurify")
	eq(Statuses.names(ally, "Event.Ally."), ["Event.Ally.Ability.Used.Ultimate"], "the ally hears the ult")
	eq(Statuses.names(caster, "Event.Ally."), [], "the caster does not")
	await battle._drain_triggers()
	eq(fired.filter(func(name) -> bool: return name.contains("Ip")), ["P2 IpUltEcho"], "a party-wide item reacts on the ally")


# --- K2 DoT tick events --------------------------------------------------------------------------------------------------

func test_dot_ticks_tell_the_applier_per_stack() -> void:
	var battle := new_battle(power_snapshot({}, "dot", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	for stack in 3:
		Statuses.apply(hexer, toad, "st_poison")
	var dealt := Statuses.listen(hexer)
	var taken := Statuses.listen(toad)
	toad.asc.turn_start()
	eq(Statuses.names(dealt, "Event.Damage"), ["Event.Damage.Dealt.Dot", "Event.Damage.Dealt.Dot", "Event.Damage.Dealt.Dot"],
		"one per stack to the applier, and never the generic event")
	eq(Statuses.names(taken, "Event.Damage"), ["Event.Damage.Taken.Dot", "Event.Damage.Taken.Dot", "Event.Damage.Taken.Dot"],
		"one per stack to the ticked unit")
	var payload: Dictionary = dealt[0][1]
	eq([payload["source"], payload["target"], payload["amount"], payload["effect"].resource_path],
		[hexer, toad, 2000, Statuses.EFFECTS + "st_poison.tres"], "source, target, amount, effect")


func test_dead_applier_gets_no_dot_event() -> void:
	var battle := new_battle(power_snapshot({}, "dot", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var toad := battle.unit_by_id(&"E2")
	Statuses.apply(hexer, toad, "st_poison")
	hexer.alive = false
	var dealt := Statuses.listen(hexer)
	var taken := Statuses.listen(toad)
	toad.asc.turn_start()
	eq(Statuses.names(dealt, "Event.Damage"), [], "a dead applier hears nothing")
	eq(Statuses.names(taken, "Event.Damage"), ["Event.Damage.Taken.Dot"], "the ticked unit still does")


func test_own_dot_and_generic_listeners_stay_silent() -> void:
	var battle := new_battle(power_snapshot({2: ["reflect"]}, "dot", "3"))
	var guard := battle.unit_by_id(&"P2")
	var toad := battle.unit_by_id(&"E2")
	var fired := _fired(battle)
	Statuses.apply(toad, guard, "st_poison")
	guard.asc.turn_start()
	await battle._drain_triggers()
	eq(fired, [], "a 'when hit' passive (Event.Damage.Taken) never fires on a tick")
	var own := new_battle(power_snapshot({}, "dot", "3"))
	var hexer := own.unit_by_id(&"P1")
	Statuses.apply(hexer, hexer, "st_poison")
	var heard := Statuses.listen(hexer)
	hexer.asc.turn_start()
	eq(Statuses.names(heard, "Event.Damage"), [], "HP a unit's own effect costs it sends no tick event")


func test_dot_spread_carries_the_dot() -> void:
	var battle := new_battle(power_snapshot({1: ["plague"]}, "dot", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var wisp := battle.unit_by_id(&"E1")
	Statuses.apply(hexer, wisp, "st_burn", 3000, [&"Damage.Type.Fire"])
	wisp.asc.turn_start()
	var fired := _fired(battle)
	await battle._drain_triggers()
	eq(fired, ["P1 IpPlague", "P1 IpSpread"], "the tick's follow-up, then the spread")
	var spread: Array = []
	for enemy_id in [&"E1", &"E2", &"E3"]:
		var burn := Statuses.active(battle.unit_by_id(enemy_id), "st_burn")
		if burn != null and enemy_id != &"E1":
			spread.append(burn)
	eq(spread.size(), 1, "one other enemy now burns")
	eq(int(spread[0].spec.get_set_by_caller_magnitude(ExecutionRow.DAMAGE_FLAT_TAG)), 3000, "with the same tick damage")
	check(spread[0].spec.dynamic_tags.has(&"Damage.Type.Fire"), "and damage type")


func test_a_dot_without_a_stack_limit_spreads_shorter() -> void:
	var battle := new_battle(power_snapshot({1: ["plague"]}, "dot", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var wisp := battle.unit_by_id(&"E1")
	var burn: GameplayEffect = load(FIXTURES + "effects/poison.tres")  # FREE stacking, 3 turns
	eq(burn.stacking_policy, GameplayEffect.StackingPolicy.FREE, "the fixture DoT has no stack limit")
	Statuses.apply(hexer, wisp, "poison")
	var seen := []
	for tick in 12:  # every tick of every copy, until they run out
		for enemy_id in [&"E1", &"E2", &"E3"]:
			battle.unit_by_id(enemy_id).asc.initialize_attribute_overrides({"hp": 90000.0} as Dictionary[String, float])
			battle.unit_by_id(enemy_id).asc.turn_start()
			await battle._drain_triggers()
		var copies := 0
		for enemy_id in [&"E1", &"E2", &"E3"]:
			for active_effect in battle.unit_by_id(enemy_id).asc._active_effects:
				copies += 1 if active_effect.get_effect_def() == burn else 0
		seen.append(copies)
	eq(seen[-1], 0, "the spread runs out by itself: %s" % [seen])
	check(seen.max() <= 8, "and never grows without end: %s" % [seen])


func test_a_two_turn_dot_spreads_one_turn() -> void:
	var battle := new_battle(power_snapshot({1: ["plague"]}, "dot", "3"))
	var burn: GameplayEffect = load(FIXTURES + "effects/poison.tres")
	var hexer := battle.unit_by_id(&"P1")
	var context := GameplayEffectContext.new(hexer, hexer)
	var spec := GameplayEffectSpec.new(burn, context, 1)
	spec.remaining_turns = 2
	hexer.asc.apply_effect_spec_to_target(spec, battle.unit_by_id(&"E1").asc)
	battle.unit_by_id(&"E1").asc.turn_start()
	await battle._drain_triggers()
	var turns := []
	for enemy_id in [&"E2", &"E3"]:
		for active_effect in battle.unit_by_id(enemy_id).asc._active_effects:
			if active_effect.get_effect_def() == burn:
				turns.append(active_effect.spec.remaining_turns)
	eq(turns, [1], "a 2-turn DoT's first tick spreads a 1-turn one")
	battle.unit_by_id(&"E1").asc.turn_start()
	await battle._drain_triggers()
	var copies := 0
	for enemy_id in [&"E2", &"E3"]:
		for active_effect in battle.unit_by_id(enemy_id).asc._active_effects:
			copies += 1 if active_effect.get_effect_def() == burn else 0
	eq(copies, 1, "its last tick has nothing left to give")


func test_an_ally_s_dot_sends_no_tick_event() -> void:
	var battle := new_battle(power_snapshot({}, "dot", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var heard := Statuses.listen(hexer)
	Statuses.apply(hexer, battle.unit_by_id(&"P2"), "st_poison")
	battle.unit_by_id(&"P2").asc.turn_start()
	eq(Statuses.names(heard, "Event.Damage"), [], "HP a unit's own side costs it is nobody's DoT")


func test_overtime_is_no_dot() -> void:
	var battle := new_battle(power_snapshot({}, "dot", "3"))
	var guard := battle.unit_by_id(&"P2")
	var wisp := battle.unit_by_id(&"E1")
	var enemy: EnemyDefinition = wisp.definition.duplicate()
	enemy.overtime_party_effect = load(FIXTURES + "effects/st_poison.tres")
	wisp.definition = enemy
	var heard := Statuses.listen(guard)
	Statuses.apply(wisp, guard, "st_poison")
	guard.asc.turn_start()
	eq(Statuses.names(heard, "Event.Damage"), [], "the boss clock's ticks are nobody's DoT")


# --- K3 trigger chance ---------------------------------------------------------------------------------------------------

func test_trigger_chance() -> void:
	for spec in [[0, 12], [10000, 12], [3000, -1]]:
		var count := 0
		for seed_value in 12:
			var battle := new_battle(power_snapshot({1: ["copy"]}, "chance", str(seed_value)))
			var hexer := battle.unit_by_id(&"P1")
			Statuses.ability(hexer, "IpCopyHit").trigger_chance_x100 = spec[0]
			_plain(Statuses.ability(hexer, "IpCopyHit"))
			var fired := _fired(battle)
			var state_before := battle.rng.state
			hexer.asc.send_gameplay_event(Battle.EVENT_DAMAGE_DEALT, {"source": hexer, "target": battle.unit_by_id(&"E1")})
			battle.unit_by_id(&"E1").asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
			await battle._drain_triggers()
			if spec[0] in [0, 10000]:
				eq(battle.rng.state, state_before, "an unset or certain chance draws nothing")
			else:
				check(battle.rng.state != state_before, "a chance draws once")
			count += fired.size()
		if spec[1] >= 0:
			eq(count, spec[1], "chance %d always fires" % spec[0])
		else:
			check(count > 0 and count < 12, "30%% fires sometimes (%d of 12)" % count)


## A plain trigger instead of a follow-up: it still fires at a target that is already down (a follow-up never does, D20), where its
## rows hit nothing and roll nothing, so only the trigger's own roll moves the RNG.
static func _plain(ability: BattleAbility) -> void:
	var none: Array[StringName] = []
	ability.asset_tags = none


func test_one_roll_per_queued_trigger_and_a_miss_costs_nothing() -> void:
	var battle := new_battle(power_snapshot({1: ["copy"]}, "chance", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var wisp := battle.unit_by_id(&"E1")
	var proc := Statuses.ability(hexer, "IpCopyHit")
	proc.trigger_chance_x100 = 1  # 0.01%: practically never
	proc.cost_effect = load(FIXTURES + "effects/ult_cost.tres")
	hexer.asc.initialize_attribute_overrides({"energy": 10000.0} as Dictionary[String, float])
	var expected := RandomNumberGenerator.new()
	expected.seed = battle.rng.seed
	expected.state = battle.rng.state
	for count in 3:
		hexer.asc.send_gameplay_event(Battle.EVENT_DAMAGE_DEALT, {"source": hexer, "target": wisp})
		expected.randi_range(0, 9999)
	var fired := _fired(battle)
	var events := Statuses.listen(hexer)
	await battle._drain_triggers()
	eq(battle.rng.state, expected.state, "three queued triggers: three rolls")
	eq(fired, [], "all missed")
	eq(hexer.stat(BattleUnit.ENERGY), 10000, "a miss pays no cost")
	eq(events, [], "and sends no event")


func test_field_mode_never_rolls() -> void:
	var field := Battle.new()
	host.add_child(field)
	_battles.append(field)
	field.setup_field(power_snapshot({1: ["copy"]}, "field", "3"), fixtures())
	var proc := Statuses.ability(field.unit_by_id(&"P1"), "IpCopyHit")
	var state := field.rng.state
	check(field._trigger_fires(proc), "a chance always fires on the map")
	eq(field.rng.state, state, "and draws nothing")


# --- K4 random targets ---------------------------------------------------------------------------------------------------

func test_random_enemy_draws_among_the_units_that_are_up() -> void:
	var battle := new_battle(power_snapshot({1: ["knife"]}, "random", "3"))
	var hexer := battle.unit_by_id(&"P1")
	battle.unit_by_id(&"E2").asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
	var knife := Statuses.ability(hexer, "IpKnife")
	var expected := RandomNumberGenerator.new()
	expected.seed = battle.rng.seed
	expected.state = battle.rng.state
	var seen := {}
	for draw in 24:
		var picked: BattleUnit = battle._expand_targets(hexer, knife, null)["primary"]
		eq(picked.unit_id, [&"E1", &"E3"][expected.randi_range(0, 1)], "one draw over the living, in slot order")
		seen[picked.unit_id] = true
	eq(seen.size(), 2, "both come up")
	eq(battle.rng.state, expected.state, "one draw per activation")


func test_random_other_and_other_enemies_spare_the_event_target() -> void:
	var battle := new_battle(power_snapshot({1: ["hook", "splash"]}, "random", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var event := {"source": hexer, "target": battle.unit_by_id(&"E2")}
	for draw in 12:
		check(battle._expand_targets(hexer, Statuses.ability(hexer, "IpHook"), null, event)["primary"].unit_id != &"E2",
			"another enemy, never the one that was hit")
	var used := {"source": hexer, "target": hexer, "primary": battle.unit_by_id(&"E3"), "targets": []}
	eq(Statuses.ids(battle._expand_targets(hexer, Statuses.ability(hexer, "IpSplash"), null, used)["targets"]), ["E1", "E2"],
		"every enemy but the one the basic attack was aimed at")
	for other in [&"E1", &"E3"]:
		battle.unit_by_id(other).asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
	var fired := _fired(battle)
	var state := battle.rng.state
	hexer.asc.send_gameplay_event(Battle.EVENT_DAMAGE_DEALT, event)
	await battle._drain_triggers()
	eq(fired, [], "with no other enemy it does not fire")
	eq(battle.rng.state, state, "and draws nothing")


func test_basic_splash_and_skill_event() -> void:
	var battle := new_battle(sp_snapshot({1: ["splash"]}, "splash", "3"))
	var events := Statuses.listen(battle.unit_by_id(&"P1"))
	var fired := _fired(battle)
	var other_hp := battle.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _use(battle, "P1", "ChantJab", "E1")
	await battle._drain_triggers()
	check(fired.has("P1 IpSplash"), "a basic attack splashes")
	check(battle.unit_by_id(&"E2").stat(BattleUnit.HP) < other_hp, "onto the other enemy")
	check(not Statuses.names(events, "Event.Ability").has("Event.Ability.Used.Skill"), "a basic attack is no skill")
	events.clear()
	battle.unit_by_id(&"P1").asc.initialize_attribute_overrides({"mp": 6000.0} as Dictionary[String, float])
	await _use(battle, "P1", "ChantBurst", "E1")
	check(Statuses.names(events, "Event.Ability").has("Event.Ability.Used.Skill"), "a move with a cost is one")
	var used: Dictionary = events.filter(func(event) -> bool: return event[0] == "Event.Ability.Used.Skill")[0][1]
	eq([used["primary"].unit_id, Statuses.ids(used["targets"])], [&"E1", ["E1"]], "its payload says what it was aimed at")


# --- K5 dying --------------------------------------------------------------------------------------------------------------

func test_a_save_keeps_the_unit_alive_once() -> void:
	var battle := new_battle(power_snapshot({2: ["undying"]}, "dying", "3"))
	var guard := battle.unit_by_id(&"P2")
	var imp := battle.unit_by_id(&"E3")
	var killer := Statuses.listen(imp)
	var ally := Statuses.listen(battle.unit_by_id(&"P1"))
	var died := []
	battle.unit_died.connect(func(unit_id): died.append(unit_id))
	Statuses.apply(imp, guard, "damage", 100000000)
	eq(guard.stat(BattleUnit.HP), 0, "a killing blow")
	await battle._settle_deaths()
	check(guard.alive, "the save kept it alive")
	eq(guard.stat(BattleUnit.HP), 30000, "at the HP its trigger gave")
	check(guard.asc.has_tag_exact(Battle.DEATH_SAVED_TAG), "and the save is spent")
	eq(died, [], "nobody died")
	eq(Statuses.names(killer, "Event.Unit"), [], "a saved unit gave no kill")
	eq(Statuses.names(ally, "Event.Unit.Died"), [], "nor a death")
	check(battle.turn_manager.av.has(guard), "it keeps its place in the turn order")
	Statuses.apply(imp, guard, "damage", 100000000)
	await battle._settle_deaths()
	check(not guard.alive, "a second lethal hit in the same battle kills it")
	eq(died, [&"P2"], "once")
	eq(Statuses.names(killer, "Event.Unit.Killed"), ["Event.Unit.Killed"], "and is a kill")


func test_without_a_save_it_dies_as_before() -> void:
	var battle := new_battle(power_snapshot({1: ["vow"]}, "dying", "3"))
	var guard := battle.unit_by_id(&"P2")
	Statuses.apply(battle.unit_by_id(&"E3"), guard, "damage", 100000000)
	var heard := Statuses.listen(guard)
	await battle._settle_deaths()
	check(not guard.alive, "dead at the same check")
	eq(Statuses.names(heard, "Event.Unit.Dying"), [], "no dying event without a listener")


func test_a_dev_kill_meets_the_save() -> void:
	var battle := new_battle(power_snapshot({2: ["undying"]}, "dying", "3"))
	battle.allow_dev = true
	var kill := GameplayEffect.new()
	var loss := CombatModifier.new()
	loss.attribute_name = "hp"
	loss.value_x100 = -100000000
	kill.modifiers.append(loss)
	await battle._apply_dev(battle.unit_by_id(&"P1"), {"dev": &"Dev.Kill", "effect": kill, "targets": "2"}, ScriptedController.new())
	check(battle.unit_by_id(&"P2").alive, "a dev kill in battle goes through the same death check")


func test_only_the_dying_triggers_run_at_the_check() -> void:
	var battle := new_battle(power_snapshot({1: ["vow"], 2: ["undying"]}, "dying", "3"))
	var fired := _fired(battle)
	await _use(battle, "E3", "FireBolt", "P2")  # queues the hexer's counter
	Statuses.apply(battle.unit_by_id(&"E3"), battle.unit_by_id(&"P2"), "damage", 100000000)
	await battle._settle_deaths()
	eq(fired, ["P2 IpUndying"], "what was already queued keeps waiting")
	await battle._drain_triggers()
	eq(fired, ["P2 IpUndying", "P1 IpVow", "P1 IpVowHeal"], "and runs at the next drain")


# --- K6 event amount -----------------------------------------------------------------------------------------------------

func test_reflect_and_lifesteal_read_the_event_amount() -> void:
	var battle := new_battle(power_snapshot({1: ["drink"], 2: ["reflect"]}, "amount", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var guard := battle.unit_by_id(&"P2")
	var toad := battle.unit_by_id(&"E2")  # the toad: not weak to Physical
	var amounts := []
	battle.damage_dealt.connect(func(source, target, amount, _tags): amounts.append([source, target, amount]))
	guard.asc.send_gameplay_event(Battle.EVENT_DAMAGE_TAKEN, {"source": toad, "target": guard, "amount": 40000})
	toad.asc.initialize_attribute_overrides({"def": 0.0} as Dictionary[String, float])
	await battle._drain_triggers()
	eq(amounts, [[&"P2", &"E2", 20000]], "half of the event's amount back to the attacker")
	hexer.asc.initialize_attribute_overrides({"hp": 10000.0} as Dictionary[String, float])
	hexer.asc.send_gameplay_event(Battle.EVENT_DAMAGE_DEALT, {"source": hexer, "target": toad, "amount": 40000})
	await battle._drain_triggers()
	eq(hexer.stat(BattleUnit.HP), 20000, "a heal effect reads Data.Event.Amount: 25% of it")
	var row := ExecutionRow.new()
	row.damage_mode = ExecutionRow.DamageMode.EVENT_AMOUNT
	var spec := GameplayEffectSpec.new(load(FIXTURES + "effects/damage.tres"), GameplayEffectContext.new(hexer, hexer), 1)
	row.apply_override(spec)
	eq(int(spec.get_set_by_caller_magnitude(ExecutionRow.DAMAGE_FLAT_TAG, -1.0)), 0, "outside a trigger the amount is 0")


# --- K7 echo -------------------------------------------------------------------------------------------------------------

func test_echo_repeats_the_skill_at_scale() -> void:
	var battle := new_battle(sp_snapshot({1: ["twin"]}, "echo", "3"))
	var chanter := battle.unit_by_id(&"P1")
	var events := Statuses.listen(chanter)
	var fired := _fired(battle)
	var hits := []
	battle.damage_dealt.connect(func(_source, target, amount, tags): hits.append([target, amount, tags]))
	chanter.asc.initialize_attribute_overrides({"mp": 6000.0} as Dictionary[String, float])
	await _use(battle, "P1", "ChantBurst", "E2")
	var mp_after := chanter.stat(BattleUnit.MP)
	await battle._drain_triggers()
	eq(fired, ["P1 IpTwin"], "the skill echoed once: an echo never echoes")
	eq(hits.size(), 2, "two casts")
	eq([hits[0][0], hits[1][0]], [&"E2", &"E2"], "on the same target")
	check(absi(hits[1][1] - Fixed.pct(hits[0][1], 6000)) <= 1, "at 60%%: %d then %d" % [hits[0][1], hits[1][1]])
	check(hits[1][2].has(&"Hit.Echo") and hits[1][2].has(&"Hit.FollowUp"), "its hits are echo and follow-up hits")
	check(not hits[0][2].has(&"Hit.Echo"), "the first cast's are not")
	eq(chanter.stat(BattleUnit.MP), mp_after, "no cost")
	eq(events.filter(func(event) -> bool: return event[0] == "Event.Ability.Used").size(), 1, "no Event.Ability.Used of its own")
	await _use(battle, "P1", "ChantJab", "E2")
	await battle._drain_triggers()
	eq(fired.count("P1 IpTwin"), 1, "a basic attack is not echoed")


func test_echo_of_a_finished_target_stays_quiet() -> void:
	var battle := new_battle(sp_snapshot({1: ["twin"]}, "echo", "3"))
	var chanter := battle.unit_by_id(&"P1")
	var fired := _fired(battle)
	chanter.asc.initialize_attribute_overrides({"mp": 6000.0} as Dictionary[String, float])
	await _use(battle, "P1", "ChantBurst", "E2")
	battle.unit_by_id(&"E2").asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
	await battle._drain_triggers()
	check(not fired.has("P1 IpTwin"), "nothing left to hit: no echo")


func test_hp_costs_never_take_the_last_hp() -> void:
	var battle := new_battle(power_snapshot({}, "cost", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var cost := GameplayEffect.new()
	var loss := CombatModifier.new()
	loss.attribute_name = "hp"
	loss.value_x100 = -2500
	cost.modifiers.append(loss)
	for pair in [[2501, true], [2500, false], [2499, false]]:
		hexer.asc.initialize_attribute_overrides({"hp": float(pair[0])} as Dictionary[String, float])
		eq(hexer.asc.can_afford_cost(cost), pair[1], "%d HP (x100) against a cost of 25" % pair[0])


## A damage row that leaves the damage to its effect (a damage ExecCalc then deals 100% ATK) echoes at the echo's scale too.
func test_echo_scales_a_row_without_an_override() -> void:
	var row := ExecutionRow.new()
	row.damage_mode = ExecutionRow.DamageMode.USE_EFFECT
	for scale in [0, 6000]:
		var spec := GameplayEffectSpec.new(load(FIXTURES + "effects/damage.tres"), GameplayEffectContext.new(null, null), 1)
		row.apply_override(spec, null, scale)
		eq(spec.set_by_caller_magnitudes.has(ExecutionRow.DAMAGE_MULTIPLIER_TAG), scale > 0, "only an echo sets it")
		if scale > 0:
			eq(int(spec.get_set_by_caller_magnitude(ExecutionRow.DAMAGE_MULTIPLIER_TAG)), scale, "to its scale")


## D22: what a kill sets off plays in the turn of the kill, not at the next actor's turn start.
func test_kill_triggers_play_in_the_turn_of_the_kill() -> void:
	var battle := new_battle(power_snapshot({1: ["knife"], 2: ["knife"]}, "kills", "3"))
	for unit in battle.units():
		if not unit.is_party():
			unit.asc.initialize_attribute_overrides({"hp": 3000.0} as Dictionary[String, float])
	var deaths := []
	var strikes := []
	battle.unit_died.connect(func(unit_id):
		if not String(unit_id).begins_with("P"):
			deaths.append(battle.turn))
	battle.trigger_activated.connect(func(_unit, ability_tag, _event):
		if ability_tag == &"Fixture.Ability.IpKnife":
			strikes.append([battle.turn, deaths.back() if not deaths.is_empty() else -1]))
	await battle.run(ScriptedController.new())
	check(not strikes.is_empty(), "a kill's strike fired")
	for strike in strikes:
		eq(strike[0], strike[1], "the strike plays in the turn of the last kill before it")


func test_echo_scales_every_number_a_row_has() -> void:
	var row := ExecutionRow.new()
	row.damage_mode = ExecutionRow.DamageMode.FLAT
	row.flat_damage_x100 = 10000
	row.toughness_x100 = 3000
	var battle := new_battle(sp_snapshot({}, "echo", "3"))
	var unit := battle.unit_by_id(&"P1")
	var spec := GameplayEffectSpec.new(load(FIXTURES + "effects/damage.tres"), GameplayEffectContext.new(unit, unit), 1)
	row.apply_override(spec, null, 6000)
	eq(int(spec.get_set_by_caller_magnitude(ExecutionRow.DAMAGE_FLAT_TAG)), 6000, "flat damage")
	eq(int(spec.get_set_by_caller_magnitude(ExecutionRow.TOUGHNESS_TAG)), 1800, "toughness damage")
	eq(int(spec.get_set_by_caller_magnitude(ExecutionRow.ECHO_SCALE_TAG)), 6000, "the scale itself, for restores")
	var plain := GameplayEffectSpec.new(load(FIXTURES + "effects/damage.tres"), GameplayEffectContext.new(unit, unit), 1)
	row.apply_override(plain)
	check(not plain.set_by_caller_magnitudes.has(ExecutionRow.ECHO_SCALE_TAG), "nothing is set outside an echo")


func test_echo_scales_buffs_and_ticks_but_not_tags() -> void:
	var battle := new_battle(sp_snapshot({}, "echo", "3"))
	var unit := battle.unit_by_id(&"P1")
	for pair in [["haste", "spd", 0.12], ["st_poison", "hp", -1200.0]]:
		var spec := GameplayEffectSpec.new(load(FIXTURES + "effects/%s.tres" % pair[0]), GameplayEffectContext.new(unit, unit), 1)
		ExecutionRow.scale_modifiers(spec, 6000)
		check(is_equal_approx(spec.mutated_magnitudes[pair[1]], pair[2]), "%s at 60%%: %s" % [pair[0], spec.mutated_magnitudes])
	var stun := GameplayEffectSpec.new(load(FIXTURES + "effects/st_stun.tres"), GameplayEffectContext.new(unit, unit), 1)
	ExecutionRow.scale_modifiers(stun, 6000)
	eq(stun.remaining_turns, 1, "a status that only grants tags lands whole")


# --- The ult cap -----------------------------------------------------------------------------------------------------------

## The user, 2026-11-23: charge refunds that add up to a full bar cast for ever without it (ults use no turn).
func test_three_ults_per_turn_then_the_next_turn() -> void:
	var battle := new_battle(power_snapshot({}, "cap", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var ult := Statuses.ability(hexer, "UltPurify")
	var choice := {"unit": &"P1", "ability": &"Fixture.Ability.UltPurify", "target": &""}
	for cast in Battle.ULTS_PER_TURN:
		hexer.asc.initialize_attribute_overrides({"energy": 10000.0} as Dictionary[String, float])
		eq(battle.validate_interrupt(hexer, choice, true), [], "cast %d is fine" % (cast + 1))
		await battle._interrupt(hexer, choice, ScriptedController.new())
		eq(battle.mismatch, {}, "and fires")
	hexer.asc.initialize_attribute_overrides({"energy": 10000.0} as Dictionary[String, float])
	check(not hexer.asc.can_activate_ability(ult), "a full bar does not help: the fourth waits for the next turn")
	eq(battle.validate_interrupt(hexer, choice, true)[0], "IllegalAbility", "a log claiming it is rejected")
	check(battle.ult_left(battle.unit_by_id(&"P2")), "per unit")
	battle._ults_cast.clear()  # what the next turn does
	check(hexer.asc.can_activate_ability(ult), "then it is free again")


func test_a_refund_loop_ends() -> void:
	var snap: Dictionary = preload("res://tests/combat/test_ult_interrupts.gd").ult_snapshot()
	var battle := new_battle(snap)
	var endless: BattleAbility = load(FIXTURES + "abilities/overcharge.tscn").instantiate()
	var full := GameplayEffect.new()
	var gain := CombatModifier.new()
	gain.attribute_name = "energy"
	gain.value_x100 = 10000
	full.modifiers.append(gain)
	var row: ExecutionRow = endless.executions[0].duplicate()
	row.effect = full
	endless.executions = [row] as Array[ExecutionRow]
	endless.ability_tag = &"Test.Ability.Endless"
	battle.unit_by_id(&"P1").asc.add_child(endless)
	var casts := {}
	battle.interrupt_started.connect(func(unit_id, _tag):
		var key := "%s t%d" % [unit_id, battle.turn]
		casts[key] = int(casts.get(key, 0)) + 1)
	var recorder := ActionRecorder.new()
	recorder.autopilot = AutoPolicy.new(AutoPolicy.Options.new(), fixtures())
	await battle.run(recorder)
	check(battle.outcome != Battle.ONGOING, "the battle ends (%s, %s, %s)" % [battle.outcome, battle.runner_error, battle.mismatch])
	check(casts.values().all(func(count: int) -> bool: return count <= Battle.ULTS_PER_TURN), "never more than the cap: %s" % casts)


func test_a_costed_counter_never_pays_for_a_downed_attacker() -> void:
	var battle := new_battle(power_snapshot({1: ["vow"]}, "cost", "3"))
	var hexer := battle.unit_by_id(&"P1")
	var imp := battle.unit_by_id(&"E3")
	Statuses.ability(hexer, "IpVow").cost_effect = load(FIXTURES + "effects/ult_cost.tres")
	hexer.asc.initialize_attribute_overrides({"energy": 10000.0} as Dictionary[String, float])
	await _use(battle, "E3", "FireBolt", "P2")
	imp.asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
	var fired := _fired(battle)
	await battle._drain_triggers()
	check(not fired.has("P1 IpVow"), "no strike at a unit that is already down")
	eq(hexer.stat(BattleUnit.ENERGY), 10000, "and no cost")


# --- K8 copies -------------------------------------------------------------------------------------------------------------

func test_copies_apply_in_full() -> void:
	var one := new_battle(power_snapshot({2: ["copy"]}, "copies", "3"))
	var two := new_battle(power_snapshot({2: ["copy", "copy"]}, "copies", "3"))
	var base := 30000
	eq(one.unit_by_id(&"P2").stat("atk"), Fixed.pct(base, 11000), "one copy: +10% ATK")
	eq(two.unit_by_id(&"P2").stat("atk"), Fixed.pct(base, 12000), "two copies: +20% ATK")
	eq(Array(two.content_warnings), [], "a copy is no duplicate")
	var guard := two.unit_by_id(&"P2")
	var granted := guard.abilities().filter(func(ability: BattleAbility) -> bool: return ability.ability_tag == &"Fixture.Ability.IpCopyHit")
	eq(granted.size(), 2, "the ability is granted once per copy")
	for ability in granted:
		ability.trigger_chance_x100 = 0
	var fired := _fired(two)
	guard.asc.send_gameplay_event(Battle.EVENT_DAMAGE_DEALT, {"source": guard, "target": two.unit_by_id(&"E1")})
	await two._drain_triggers()
	eq(fired, ["P2 IpCopyHit", "P2 IpCopyHit"], "and each fires on its own")
	for ability in granted:
		ability.trigger_chance_x100 = 5000
		_plain(ability)
	var expected := RandomNumberGenerator.new()
	expected.seed = two.rng.seed
	expected.state = two.rng.state
	fired.clear()
	guard.asc.send_gameplay_event(Battle.EVENT_DAMAGE_DEALT, {"source": guard, "target": two.unit_by_id(&"E1")})
	two.unit_by_id(&"E1").asc.initialize_attribute_overrides({"hp": 0.0} as Dictionary[String, float])
	var rolls := [expected.randi_range(0, 9999) < 5000, expected.randi_range(0, 9999) < 5000]
	await two._drain_triggers()
	eq(fired.size(), rolls.count(true), "each copy rolls for itself")
	eq(two.rng.state, expected.state, "two rolls")


func test_party_item_copies_on_two_members() -> void:
	var battle := new_battle(power_snapshot({1: ["ult_echo"], 2: ["ult_echo"]}, "copies", "3"))
	for unit_id in [&"P1", &"P2"]:
		eq(battle.unit_by_id(unit_id).abilities().filter(func(ability: BattleAbility) -> bool:
			return ability.ability_tag == &"Fixture.Ability.IpUltEcho").size(), 2, "two copies of a party-wide item count on everyone")


func test_a_true_duplicate_still_warns() -> void:
	var snap := power_snapshot({1: ["vow"]}, "copies", "3")
	var battle := new_battle(snap)
	var hexer := battle.unit_by_id(&"P1")
	hexer._grant_ability(load(FIXTURES + "abilities/ip_vow.tscn"), &"", [], &"fixture.item.other", 99)
	check(Array(hexer.warnings).any(func(text): return text.contains("already has Fixture.Ability.IpVow")),
		"the same tag from another source is skipped with a warning")
	var twice := new_battle(power_snapshot({}, "copies", "3")).unit_by_id(&"P1")
	var scene: PackedScene = load(FIXTURES + "abilities/ip_vow.tscn")
	twice._grant_ability(scene, &"", [], &"fixture.item.one", 5)
	twice._grant_ability(scene, &"", [], &"fixture.item.one", 5)
	check(not twice.warnings.is_empty(), "the same scene twice in one copy's set is a duplicate too")


# --- Chains --------------------------------------------------------------------------------------------------------------

func test_a_self_feeding_pair_stops_at_the_cap() -> void:
	var hashes := []
	for run in 2:
		var battle := new_battle(power_snapshot({1: ["crown", "hook"]}, "chain", "3"))
		var hexer := battle.unit_by_id(&"P1")
		Statuses.ability(hexer, "IpHook").trigger_chance_x100 = 0
		var fired := _fired(battle)
		await _use(battle, "P1", "Strike", "E1")
		await battle._drain_triggers()
		eq(fired.count("P1 IpCrown"), TriggerQueue.MAX_DEPTH, "the crown feeds itself up to the cap")
		eq(fired.count("P1 IpHook"), 1, "a follow-up's hit never fires another item's follow-up")
		eq(battle.chain_cap_hits, 1, "the cap is counted")
		eq(Array(battle.content_warnings).filter(func(text): return text.contains("trigger chain")).size(), 1, "and warned about once")
		await _use(battle, "P1", "Strike", "E1")
		await battle._drain_triggers()
		eq(Array(battle.content_warnings).filter(func(text): return text.contains("trigger chain")).size(), 1, "once per battle")
		hashes.append(battle.state_hash())
	eq(hashes[0], hashes[1], "the same way every time")


func test_strikes_feed_follow_ups() -> void:
	var battle := new_battle(power_snapshot({1: ["knife", "hook"]}, "chain", "3"))
	var hexer := battle.unit_by_id(&"P1")
	Statuses.ability(hexer, "IpHook").trigger_chance_x100 = 0
	var fired := _fired(battle)
	hexer.asc.send_gameplay_event(Battle.EVENT_UNIT_KILLED, {"source": hexer, "target": battle.unit_by_id(&"E1")})
	await battle._drain_triggers()
	eq(fired, ["P1 IpKnife", "P1 IpHook"], "a strike is a hit of the holder's own: follow-ups fire from it")


func test_chained_attacks_tell_the_gate() -> void:
	var gate := RecordingGate.new()
	var battle := new_battle(power_snapshot({1: ["crown", "hook"]}, "chain", "3"), gate)
	Statuses.ability(battle.unit_by_id(&"P1"), "IpHook").trigger_chance_x100 = 0
	await _use(battle, "P1", "Strike", "E1")
	await battle._drain_triggers()
	eq(gate.seen.slice(0, 4), [["Strike", false], ["IpHook", false], ["IpCrown", true], ["IpCrown", true]],
		"the action and the first triggered attack are paced in full, the rest of the chain faster")
	await _use(battle, "P1", "Strike", "E1")
	eq(gate.seen[-1], ["Strike", false], "the next action is not part of the chain")


class RecordingGate extends PresentationGate:
	var seen: Array = []

	func begin_ability(_unit_id: StringName, ability: BattleAbility, _sequence: Array[StringName]) -> void:
		if not ability.is_triggered() or ability.plays_like_attack():
			seen.append([String(ability.ability_tag).trim_prefix("Fixture.Ability."), chained])


# --- Record and replay ---------------------------------------------------------------------------------------------------

func test_every_hook_records_and_replays() -> void:
	for snap in [proc_golden(), dying_golden(), echo_golden(), copies_golden()]:
		var request: Dictionary = await record(snap)
		var result: Dictionary = await replay(copy(request))
		eq(result.get("verdict"), "Verified", "%s replays" % snap["battleId"])


func test_the_goldens_exercise_their_hooks() -> void:
	for spec in [[proc_golden(), ["IpPlague", "IpSpread", "IpBell", "IpHook", "IpVow", "IpVowHeal", "IpKnife"]],
			[dying_golden(), ["IpUndying"]], [echo_golden(), ["IpTwin", "IpDrink", "IpSplash", "IpReflect"]],
			[copies_golden(), ["IpCopyHit"]]]:
		var battle := new_battle(spec[0])
		var fired := {}
		battle.trigger_activated.connect(func(_unit, ability_tag, _event):
			fired[String(ability_tag).trim_prefix("Fixture.Ability.")] = true)
		await battle.run(ScriptedController.new())
		for name in spec[1]:
			check(fired.has(name), "%s fires %s" % [spec[0]["battleId"], name])
