## Spec item-pass 3.1/3.2: hit tags (crit, weakness, break, follow-up), weakness damage and toughness, HSR break with
## a Persona-style One More, follow-up attacks and the kill event. Fixtures only (duelist vs brittle).
extends TestCase

const DAMAGE_DEALT_PREFIX: String = "Event.Damage.Dealt"


## The duelist (Fire skills, no crits by default) against brittle enemies (weak to Fire, toughness 30).
static func break_snapshot(encounter: String = "brittle_pair", items: Array = [], seed_text: String = "11") -> Dictionary:
	return {
		"schemaVersion": 2,
		"battleId": "break-seed-%s" % seed_text,
		"seed": seed_text,
		"encounterId": "fixture.encounter." + encounter,
		"party": [
			{"slot": 1, "unitDefId": "fixture.character.duelist", "level": 1, "skills": [], "equipmentIds": [],
				"items": items, "useSlots": []},
		],
	}


func _ability(unit: BattleUnit, name: String) -> BattleAbility:
	return unit.ability_by_tag(StringName("Fixture.Ability." + name))


## Every event a unit receives, in order: [[tag, payload], ...].
static func _listen(unit: BattleUnit) -> Array:
	var received := []
	unit.asc.gameplay_event_received.connect(func(tag, payload): received.append([tag, payload]))
	return received


static func _tags(received: Array, prefix: String) -> Array:
	return received.filter(func(event): return String(event[0]).begins_with(prefix)).map(func(event): return String(event[0]))


func test_hit_tag_events() -> void:
	var battle := new_battle(break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	var first := battle.unit_by_id(&"E1")
	var dealt := _listen(duelist)
	var taken := _listen(first)
	var hits := []
	battle.damage_dealt.connect(func(_source, target, amount, hit_tags): hits.append([target, amount, hit_tags]))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), first)
	eq(_tags(dealt, DAMAGE_DEALT_PREFIX), ["Event.Damage.Dealt", "Event.Damage.Dealt.Fire", "Event.Damage.Dealt.Break",
		"Event.Damage.Dealt.Weakness"], "damage type events, then one event per hit tag, sorted")
	eq(_tags(taken, "Event.Damage.Taken"), ["Event.Damage.Taken", "Event.Damage.Taken.Fire", "Event.Damage.Taken.Break",
		"Event.Damage.Taken.Weakness"], "the target gets the Taken versions")
	# ATK 500 × 50% = 250, DEF 0, weakness damage taken 200% → 500.
	eq(hits, [[&"E1", 50000, [&"Hit.Break", &"Hit.Weakness"]]], "damage_dealt carries the amount and hit tags")
	var payload: Dictionary = dealt.filter(func(event): return event[0] == &"Event.Damage.Dealt")[0][1]
	eq(payload["hit_tags"], [&"Hit.Break", &"Hit.Weakness"], "the event payload carries the hit tags")

	duelist.asc.initialize_attribute_overrides({"crit_rate": 10000.0})
	dealt.clear()
	hits.clear()
	await battle._activate(duelist, _ability(duelist, "Strike"), battle.unit_by_id(&"E2"))
	eq(_tags(dealt, DAMAGE_DEALT_PREFIX), ["Event.Damage.Dealt", "Event.Damage.Dealt.Critical"],
		"a crit without a damage type or weakness sends only Critical")
	eq(hits, [[&"E2", 75000, [&"Hit.Critical"]]], "the ExecCalc's crit (×150%) is reported as Hit.Critical")


func test_weakness_from_effect() -> void:
	var battle := new_battle(break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	var target := battle.unit_by_id(&"E1")
	target.asc.clear_tag(&"Weakness.Fire")  # drop the definition's weakness: the effect alone must provide it
	var hits := []
	battle.damage_dealt.connect(func(_source, _target, amount, hit_tags): hits.append([amount, hit_tags]))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), target)
	eq(hits[-1], [25000, []], "no weakness: a plain hit")
	await battle._activate(duelist, _ability(duelist, "Expose"), target)
	check(target.asc.has_tag_exact(&"Weakness.Fire"), "Exposed grants Weakness.Fire through its granted tags")
	await battle._activate(duelist, _ability(duelist, "FireSlash"), target)
	eq(hits[-1][1], [&"Hit.Break", &"Hit.Weakness"], "a timed weakness counts like a definition one")
	target.asc.turn_end()
	target.asc.turn_end()
	check(not target.asc.has_tag_exact(&"Weakness.Fire"), "the weakness ends with the effect")
	await battle._activate(duelist, _ability(duelist, "FireSlash"), target)
	eq(hits[-1][1], [], "later hits are normal again")


## The third GAS path (spec item-pass 3.3): a variant's AbilitySet.tags. A private content index, so the fixtures stay as built.
func test_weakness_from_ability_set() -> void:
	var content := ContentIndex.new(FIXTURES)
	var plain: UnitDefinition = content.units[&"fixture.enemy.brittle"].duplicate()
	plain.id = &"test.enemy.plain"
	plain.tags = []
	content.units[plain.id] = plain
	var weak_set := AbilitySet.new()
	weak_set.tags = [&"Weakness.Fire"]
	var variant := EnemyVariant.new()
	variant.id = &"test.variant.weak_fire"
	variant.grants = weak_set
	content.variants[variant.id] = variant
	var snap := break_snapshot("brittle_one")
	snap["enemies"] = [{"slot": 1, "unitDefId": "test.enemy.plain"}, {"slot": 2, "unitDefId": "test.enemy.plain",
		"variantId": "test.variant.weak_fire"}]
	var battle := Battle.new()
	host.add_child(battle)
	var error := battle.setup(snap, content, null)
	check(error == "", "battle setup failed: " + error)
	var duelist := battle.unit_by_id(&"P1")
	var hits := {}
	battle.damage_dealt.connect(func(_source, target, _amount, hit_tags): hits[target] = hit_tags)
	await battle._activate(duelist, _ability(duelist, "FireSlash"), battle.unit_by_id(&"E1"))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), battle.unit_by_id(&"E2"))
	eq(hits[&"E1"], [], "no tags, no variant: a plain hit")
	check(battle.unit_by_id(&"E2").asc.has_tag_exact(&"Weakness.Fire"), "the variant's AbilitySet.tags reach the ASC")
	check(hits[&"E2"].has(&"Hit.Weakness"), "and count as a weakness")
	battle.queue_free()


func test_weakness_dmg_attribute() -> void:
	var battle := new_battle(break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	battle.unit_by_id(&"E2").asc.initialize_attribute_overrides({"weakness_dmg": 12500.0})
	var hits := []
	battle.damage_dealt.connect(func(_source, target, amount, _tags): hits.append([target, amount]))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), battle.unit_by_id(&"E1"))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), battle.unit_by_id(&"E2"))
	eq(hits, [[&"E1", 50000], [&"E2", 31250]], "weakness damage taken is each unit's own attribute (200% vs 125%)")


func test_toughness_and_broken_dmg() -> void:
	var battle := new_battle(break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	var first := battle.unit_by_id(&"E1")
	var second := battle.unit_by_id(&"E2")
	first.asc.initialize_attribute_overrides({"max_toughness": 9000.0, "toughness": 9000.0})
	await battle._activate(duelist, _ability(duelist, "FireSlash"), first)
	eq(first.stat("toughness"), 6000, "toughness_dmg 0%: the row's 30")
	duelist.asc.initialize_attribute_overrides({"toughness_dmg": 10000.0})
	await battle._activate(duelist, _ability(duelist, "FireSlash"), first)
	eq(first.stat("toughness"), 0, "toughness_dmg +100%: 60")

	var hits := []
	battle.damage_dealt.connect(func(_source, _target, amount, _tags): hits.append(amount))
	second.asc.add_tag(Battle.BROKEN_TAG)
	await battle._activate(duelist, _ability(duelist, "Strike"), second)
	duelist.asc.initialize_attribute_overrides({"broken_dmg": 5000.0})
	await battle._activate(duelist, _ability(duelist, "Strike"), second)
	eq(hits, [50000, 75000], "broken_dmg does nothing at 0%, +50% against a Broken target")


func test_break_delay_and_recovery() -> void:
	var battle := new_battle(break_snapshot("brittle_one"))
	var duelist := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	var av_before: int = battle.turn_manager.av[enemy]
	var broken := []
	battle.unit_broken.connect(func(unit_id, breaker_id): broken.append([unit_id, breaker_id]))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), enemy)
	check(enemy.asc.has_tag_exact(Battle.BROKEN_TAG), "toughness 0 → State.Broken")
	eq(broken, [[&"E1", &"P1"]], "unit_broken names the breaker")
	# SPD 80 → full AV 12500; delayed by 25%.
	eq(battle.turn_manager.av[enemy], av_before + 3125, "the Broken unit's action is delayed by 25% of its full AV")
	eq(battle.one_more_queue, [duelist], "the breaker is owed a One More")
	var hits := []
	battle.damage_dealt.connect(func(_source, _target, _amount, hit_tags): hits.append(hit_tags))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), enemy)
	eq(hits, [[&"Hit.Weakness"]], "while Broken: weakness damage, no toughness damage, no second break")
	eq(battle.one_more_queue.size(), 1, "no second One More")
	battle._recover(enemy)
	eq(enemy.stat("toughness"), 3000, "recovery refills toughness")
	check(not enemy.asc.has_tag_exact(Battle.BROKEN_TAG), "and removes State.Broken")


func test_break_blast_one_more() -> void:
	var battle := new_battle(break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	await battle._activate(duelist, _ability(duelist, "FireWave"), null)
	check(battle.unit_by_id(&"E1").asc.has_tag_exact(Battle.BROKEN_TAG) and battle.unit_by_id(&"E2").asc.has_tag_exact(Battle.BROKEN_TAG),
		"one blast breaks both")
	eq(battle.one_more_queue, [duelist], "one action that breaks two units earns one One More")


func test_break_kill_and_victory() -> void:
	var battle := new_battle(break_snapshot("brittle_one"))
	var duelist := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	enemy.asc.initialize_attribute_overrides({"hp": 100.0})
	await battle._activate(duelist, _ability(duelist, "FireSlash"), enemy)
	check(not enemy.asc.has_tag_exact(Battle.BROKEN_TAG), "a killing blow is a kill, not a break")
	eq(battle.one_more_queue, [], "no One More from a kill")
	var request: Dictionary = await record(break_snapshot("brittle_one"))
	eq(request["actionLog"]["claimedOutcome"], "Victory", "a battle full of breaks is won")
	eq((await replay(request)).get("verdict"), "Verified", "and replays")


## The scripted party: turn 1 Fire Slash breaks E2 → One More (turn 2) Fire Wave breaks E1 → One More (turn 3) Strike.
func test_one_more_chain_records_and_replays() -> void:
	var battle := new_battle(break_snapshot())
	var started := []
	battle.one_more_started.connect(func(unit_id): started.append([unit_id, battle.turn]))
	var recovered := []
	battle.unit_recovered.connect(func(unit_id): recovered.append([unit_id, battle.unit_by_id(unit_id).stat("toughness")]))
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "no runner error: " + battle.runner_error)
	check(not recovered.is_empty() and recovered[0][1] == 3000, "a Broken enemy recovers full toughness at its turn: %s" % [recovered])
	var actions := controller.entries
	eq(actions.slice(0, 3).map(func(entry): return [entry["turn"], entry["ability"], entry.get("extra", false)]),
		[[1, "Fixture.Ability.FireSlash", false], [2, "Fixture.Ability.FireWave", true], [3, "Fixture.Ability.Strike", true]],
		"a break chains One More actions, each logged with extra")
	eq(started.slice(0, 2), [[&"P1", 2], [&"P1", 3]], "one_more_started fires for each")
	var request := {"snapshot": break_snapshot(), "actionLog": ActionRecorder.build_log(actions, battle.outcome, battle.final_hash)}
	eq((await replay(request)).get("verdict"), "Verified", "breaks and One More actions replay")

	var dropped := copy(request)
	dropped["actionLog"]["actions"][1].erase("extra")
	var rejected := await replay(dropped)
	eq([rejected.get("errorCode"), rejected.get("mismatch", {}).get("reason")], [2002, "TurnMismatch"],
		"a One More logged as a normal turn → 2002")
	var claimed := copy(request)
	claimed["actionLog"]["actions"][0]["extra"] = true
	var rejected_claim := await replay(claimed)
	eq([rejected_claim.get("errorCode"), rejected_claim.get("mismatch", {}).get("reason")], [2002, "TurnMismatch"],
		"a One More claimed without a break → 2002")


func test_extra_action_skips_turn_ticks() -> void:
	var battle := new_battle(break_snapshot("brittle_one"))
	var duelist := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	battle.one_more_queue.append(duelist)
	var av_before: Dictionary = battle.turn_manager.av.duplicate()
	var controller := ScriptedController.new()
	await battle._extra_action(duelist, controller)
	eq(battle.turn, 1, "the extra action has its own turn number")
	eq(battle.turn_manager.av[duelist], av_before[duelist], "and doesn't change the actor's action value")
	eq(controller.entries[0].get("extra"), true, "it is logged as extra")
	check(enemy.stat(BattleUnit.HP) < 300000, "the actor really acted")


func test_break_by_follow_up() -> void:
	var battle := new_battle(break_snapshot("brittle_one", ["fixture.item.burn_charm"]))
	var duelist := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	var hits := []
	battle.damage_dealt.connect(func(_source, _target, _amount, hit_tags): hits.append(hit_tags))
	duelist.asc.initialize_attribute_overrides({"crit_rate": 10000.0})
	await battle._activate(duelist, _ability(duelist, "Strike"), enemy)
	duelist.asc.initialize_attribute_overrides({"crit_rate": 0.0})
	eq(battle.one_more_queue, [], "the crit itself (no weakness) breaks nothing")
	await battle._drain_triggers()
	eq(hits, [[&"Hit.Critical"], [&"Hit.Break", &"Hit.FollowUp", &"Hit.Weakness"]],
		"the crit triggers the Fire follow-up, whose hits carry Hit.FollowUp and break the enemy")
	eq(battle.one_more_queue, [duelist], "a break by a follow-up earns its owner the One More")


func test_follow_up_attack() -> void:
	var battle := new_battle(break_snapshot("brittle_one", ["fixture.item.chaser_charm"]))
	var duelist := battle.unit_by_id(&"P1")
	var events := _listen(duelist)
	var fired := []
	battle.trigger_activated.connect(func(unit_id, ability_tag, event_tag): fired.append([unit_id, ability_tag, event_tag]))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), battle.unit_by_id(&"E1"))
	await battle._drain_triggers()
	eq(fired, [[&"P1", &"Fixture.Ability.Chaser", &"Event.Damage.Dealt.Weakness"],
		[&"P1", &"Fixture.Ability.Momentum", &"Event.Attack.FollowUp"]],
		"the weakness hit triggers the follow-up, which sends Event.Attack.FollowUp")
	eq(duelist.stat(BattleUnit.ENERGY), 1000, "Momentum reacted to the follow-up")
	eq(_tags(events, "Event.Ability.Used").size(), 1, "a follow-up is not an action (no Event.Ability.Used)")
	check(not duelist.action_abilities().has(_ability(duelist, "Chaser")), "and can't be chosen")
	var request: Dictionary = await record(break_snapshot("brittle_pair", ["fixture.item.chaser_charm"]))
	eq((await replay(request)).get("verdict"), "Verified", "follow-ups are re-simulated on replay")


## HSR rule: a follow-up never fires from a follow-up's own hit. A plain passive on those hits still does, and a
## passive chain still stops at the depth cap.
func test_follow_ups_never_feed_follow_ups() -> void:
	var battle := new_battle(break_snapshot("brittle_one", ["fixture.item.chaser_charm"]))
	var duelist := battle.unit_by_id(&"P1")
	var echo: BattleAbility = load(FIXTURES + "abilities/chaser.tscn").instantiate()
	echo.ability_tag = &"Test.Ability.Echo"
	echo.trigger_event_tag = &"Event.Damage.Dealt.FollowUp"
	duelist.asc.add_child(echo)
	var fired := []
	battle.trigger_activated.connect(func(_unit, ability_tag, _event): fired.append(ability_tag))
	await battle._activate(duelist, _ability(duelist, "FireSlash"), battle.unit_by_id(&"E1"))
	await battle._drain_triggers()
	check(not fired.has(&"Test.Ability.Echo"), "a follow-up listening to follow-up hits never fires")
	check(fired.has(&"Fixture.Ability.Chaser"), "the first follow-up did")

	var chain := new_battle(break_snapshot("brittle_one", ["fixture.item.chaser_charm"]))
	var hero := chain.unit_by_id(&"P1")
	var plain: BattleAbility = load(FIXTURES + "abilities/chaser.tscn").instantiate()
	plain.ability_tag = &"Test.Ability.Plain"
	plain.asset_tags.clear()  # not a follow-up: its hits feed itself until the cap
	plain.trigger_event_tag = &"Event.Damage.Dealt"
	hero.asc.add_child(plain)
	await chain._activate(hero, _ability(hero, "Strike"), chain.unit_by_id(&"E1"))
	await chain._drain_triggers()
	check(Array(chain.content_warnings).any(func(w): return w.contains("trigger chain")), "other chains still stop at the depth cap")


func test_unit_killed_event() -> void:
	var battle := new_battle(break_snapshot())
	var duelist := battle.unit_by_id(&"P1")
	var first := battle.unit_by_id(&"E1")
	var second := battle.unit_by_id(&"E2")
	var duelist_events := _listen(duelist)
	var second_events := _listen(second)
	first.asc.initialize_attribute_overrides({"hp": 100.0})
	await battle._activate(duelist, _ability(duelist, "Strike"), first)
	battle._check_deaths()
	var died: Array = second_events.filter(func(event): return event[0] == Battle.EVENT_UNIT_DIED)
	eq(died.size(), 1, "the living get Event.Unit.Died")
	eq(died[0][1]["instigator"], duelist, "its payload names the killer")
	var killed: Array = duelist_events.filter(func(event): return event[0] == Battle.EVENT_UNIT_KILLED)
	eq(killed.map(func(event): return [event[1]["source"], event[1]["target"]]), [[duelist, first]], "the killer gets Event.Unit.Killed")

	# A blast kills both: one Killed per (killer, dead), in unit order.
	var pair := new_battle(break_snapshot())
	var hero := pair.unit_by_id(&"P1")
	var hero_events := _listen(hero)
	for id in [&"E1", &"E2"]:
		pair.unit_by_id(id).asc.initialize_attribute_overrides({"hp": 100.0})
	await pair._activate(hero, _ability(hero, "FireWave"), null)
	pair._check_deaths()
	eq(hero_events.filter(func(event): return event[0] == Battle.EVENT_UNIT_KILLED).map(func(event): return event[1]["target"].unit_id),
		[&"E1", &"E2"], "a double kill sends two Killed events in unit order")

	# A dev kill (the unit's own effect) credits nobody, not even an earlier attacker.
	var dev := new_battle(break_snapshot("brittle_one"))
	var dev_hero := dev.unit_by_id(&"P1")
	var dev_events := _listen(dev_hero)
	await dev._activate(dev_hero, _ability(dev_hero, "Strike"), dev.unit_by_id(&"E1"))
	var kill := GameplayEffect.new()
	kill.policy = GameplayEffect.DurationPolicy.INSTANT
	var modifier := CombatModifier.new()
	modifier.attribute_name = BattleUnit.HP
	modifier.value_x100 = -10000000
	kill.modifiers.append(modifier)
	dev.apply_to_units(kill, [&"E1"])
	eq(dev_events.filter(func(event): return event[0] == Battle.EVENT_UNIT_KILLED), [], "a dev kill sends no Killed event")


func test_killer_dying_too_gets_no_event() -> void:
	var battle := new_battle(break_snapshot("brittle_one"))
	var duelist := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	var events := _listen(duelist)
	enemy.asc.initialize_attribute_overrides({"hp": 0.0})
	duelist.asc.initialize_attribute_overrides({"hp": 0.0})
	enemy.last_hit_by = duelist  # after the overrides, which count as each unit's own effect
	battle._check_deaths()
	eq(events.filter(func(event): return event[0] == Battle.EVENT_UNIT_KILLED), [], "a killer that dies in the same step gets nothing")


func test_unit_killed_by_dot() -> void:
	var battle := new_battle(break_snapshot("brittle_one"))
	var duelist := battle.unit_by_id(&"P1")
	var enemy := battle.unit_by_id(&"E1")
	var events := _listen(duelist)
	var poison: GameplayEffect = load(FIXTURES + "effects/poison.tres")
	duelist.asc.apply_effect_spec_to_target(GameplayEffectSpec.new(poison, GameplayEffectContext.new(duelist, duelist)), enemy.asc)
	enemy.asc.initialize_attribute_overrides({"hp": 3000.0})
	enemy.asc.turn_start()  # the tick takes the last 30 HP
	eq(enemy.stat(BattleUnit.HP), 0, "the DoT tick kills")
	battle._check_deaths()
	eq(events.filter(func(event): return event[0] == Battle.EVENT_UNIT_KILLED).size(), 1, "the DoT's source gets Event.Unit.Killed")


func test_turn_manager_delay() -> void:
	var battle := new_battle(break_snapshot("brittle_one"))
	var enemy := battle.unit_by_id(&"E1")
	var before: int = battle.turn_manager.av[enemy]
	battle.turn_manager.delay(enemy, 10000)
	eq(battle.turn_manager.av[enemy], before + TurnManager.full_av(enemy), "a 100% delay adds one full action value")
	battle.turn_manager.remove(enemy)
	battle.turn_manager.delay(enemy, 2500)
	check(not battle.turn_manager.av.has(enemy), "delaying a unit out of the queue does nothing")
