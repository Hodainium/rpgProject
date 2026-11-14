## Content test for spec route-enemies (section 6): each of the twelve ending-route enemies does what it was made for,
## checked by direction only (a target is delayed, an ally healed, SP lowered, a phase starts), never by the tuned number,
## and a fight against each new encounter replays Verified. Reads res://content/ and is skipped when it isn't there.
extends TestCase

const DemoItems := preload("res://tests/game/test_demo_items.gd")
const Bosses := preload("res://tests/combat/test_bosses.gd")
const DEMO: String = "res://content/demo/"
const CONTENT_ROOT: String = "res://content/"
const REGULAR_ENCOUNTERS: Array[String] = ["bell_tower", "vespers", "counting_house", "gargoyle_watch", "doll_circle",
	"familiars", "moth_swarm", "echoes"]
const ELITE_ENCOUNTERS: Array[String] = ["glass_saint", "drake_lair", "hag_sister", "devourer"]

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	super()


func _ready_to_test() -> bool:
	if not ResourceLoader.exists(DEMO + "enemies/void_devourer.tres"):
		print("    skipped: no route-enemies content under ", DEMO)
		return false
	return true


func _battle(encounter: String) -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup(DemoItems._snapshot([], encounter), DemoItems._demo_content())
	check(error == "", "demo battle setup: " + error)
	for id in [&"P1", &"P2"]:
		_sturdy(battle.unit_by_id(id))
	return battle


func _act(battle: Battle, actor: StringName, ability: StringName, target: StringName) -> void:
	var unit := battle.unit_by_id(actor)
	var chosen := unit.ability_by_tag(ability)
	check(chosen != null, "%s has %s" % [actor, ability])
	if chosen == null:
		return
	await battle._activate(unit, chosen, battle.unit_by_id(target))
	battle._check_deaths()
	await battle._drain_triggers()


static func _sturdy(unit: BattleUnit) -> void:
	unit.asc.initialize_attribute_overrides({"max_hp": 1000000.0, "hp": 1000000.0})


static func _hurt(battle: Battle, unit: BattleUnit, percent: int) -> void:
	Bosses.hurt(battle.unit_by_id(&"P1"), unit, unit.stat(BattleUnit.MAX_HP) * percent / 100)
	battle._check_deaths()


## Damage events: [source id, target id, hit tags].
static func _hits(battle: Battle) -> Array:
	var hits := []
	battle.damage_dealt.connect(func(source, target, _amount, tags): hits.append([source, target, tags]))
	return hits


static func _delays(battle: Battle) -> Array:
	var delayed := []
	battle.action_delayed.connect(func(target, _delay): delayed.append(target))
	return delayed


static func _hit_both(hits: Array, source: StringName, damage_type: StringName) -> bool:
	for target in [&"P1", &"P2"]:
		if not hits.any(func(hit): return hit[0] == source and hit[1] == target and hit[2].has(damage_type)):
			return false
	return true


## Spec 3.6: the pattern's fourth step falls back to `fallback` before the elite's 50% phase and is `phase_ability`
## after it, which also brings Haste.
func _check_elite_phase(battle: Battle, elite_id: StringName, fallback: StringName, phase_ability: StringName) -> void:
	var elite := battle.unit_by_id(elite_id)
	var pattern: PatternBrain = elite.definition.brain
	var before := []
	for i in 4:
		before.append(pattern.choose(elite, battle)["ability"])
	eq(before[3], fallback, "%s: before its phase the fourth step falls back to %s" % [elite.definition.id, fallback])
	_hurt(battle, elite, 55)  # to 45%
	check(elite.asc.has_tag_exact(&"State.Phase.Two"), "%s enters its phase below 50%%" % elite.definition.id)
	check(elite.asc.has_tag_exact(&"Status.Buff.Haste"), "%s hastes itself in its phase" % elite.definition.id)
	var after := []
	for i in 4:
		after.append(pattern.choose(elite, battle)["ability"])
	eq(after[3], phase_ability, "%s: after its phase the fourth step is %s" % [elite.definition.id, phase_ability])


func test_cathedral_enemies() -> void:
	if not _ready_to_test():
		return
	var tower := _battle("bell_tower")
	var hits := _hits(tower)
	var delayed := _delays(tower)
	await _act(tower, &"E1", &"Ability.Toll", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Physical"), "Toll hits the whole party")
	check(delayed.has(&"P1") and delayed.has(&"P2"), "Toll delays every target: %s" % [delayed])

	var vespers := _battle("vespers")  # E1 Candle Acolyte, E2 Bell Ringer, E3 Choir Seraph
	hits = _hits(vespers)
	await _act(vespers, &"E1", &"Ability.Votiveflame", &"P1")
	check(hits.any(func(hit): return hit[0] == &"E1" and hit[2].has(&"Damage.Type.Fire")), "Votive Flame is Fire")
	var ringer := vespers.unit_by_id(&"E2")
	_hurt(vespers, ringer, 50)
	vespers.unit_by_id(&"P1").asc.apply_gameplay_effect(load(DEMO + "effects/weaken.tres"), vespers.unit_by_id(&"P1").asc, 1)
	ringer.asc.apply_gameplay_effect(load(DEMO + "effects/weaken.tres"), vespers.unit_by_id(&"P1").asc, 1)
	check(ringer.asc.has_tag(&"Status.Debuff"), "the Bell Ringer is weakened before Vigil")
	var hp_before := ringer.stat(BattleUnit.HP)
	await _act(vespers, &"E1", &"Ability.Vigil", &"")
	check(ringer.stat(BattleUnit.HP) > hp_before, "Vigil heals an ally")
	check(not ringer.asc.has_tag(&"Status.Debuff"), "Vigil cleanses an ally's debuffs")
	check(vespers.unit_by_id(&"P1").asc.has_tag(&"Status.Debuff"), "Vigil touches only the Acolyte's side")

	var saint_fight := _battle("glass_saint")  # E1 Glass Saint, E2 Candle Acolyte
	hits = _hits(saint_fight)
	await _act(saint_fight, &"E1", &"Ability.Prismray", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Ice"), "Prism Ray hits the whole party with Ice")
	await _act(saint_fight, &"E1", &"Ability.Stainedward", &"")
	for id in [&"E1", &"E2"]:
		check(saint_fight.unit_by_id(id).asc.has_tag_exact(&"Status.Buff.Ward"), "Stained Ward wards %s" % id)
	check(saint_fight.unit_by_id(&"E1").ability_by_tag(&"Ability.Shardrain") == null, "no Shard Rain before the phase")
	_check_elite_phase(saint_fight, &"E1", &"Ability.Smite", &"Ability.Shardrain")
	hits.clear()
	await _act(saint_fight, &"E1", &"Ability.Shardrain", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Physical"), "Shard Rain hits the whole party")


func test_vault_enemies() -> void:
	if not _ready_to_test():
		return
	var house := _battle("counting_house")  # E1, E2 Tally Clerks, E3 Gilded Mimic
	var warrior := house.unit_by_id(&"P1")
	warrior.asc.initialize_attribute_overrides({"mp": 4000.0})
	await _act(house, &"E1", &"Ability.Levy", &"P1")
	eq(warrior.stat("mp"), 2500, "Levy takes 15 SP")
	warrior.asc.initialize_attribute_overrides({"mp": 1000.0})
	await _act(house, &"E1", &"Ability.Levy", &"P1")
	eq(warrior.stat("mp"), 0, "Levy never takes SP below 0")

	var watch := _battle("gargoyle_watch")  # E1 Vault Gargoyle, E2 Vault Sentry
	var stunned := false
	for attempt in 12:
		await _act(watch, &"E1", &"Ability.Stonegaze", &"P1")
		stunned = stunned or watch.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Debuff.Stun")
	check(stunned, "Stone Gaze stuns (a 45% roll, 12 tries)")
	await _act(watch, &"E1", &"Ability.Brace", &"")
	check(watch.unit_by_id(&"E1").asc.has_tag_exact(&"Status.Buff.DefenseUp"), "the Gargoyle braces")

	var lair := _battle("drake_lair")  # E1 Hoard Drake, E2 Tally Clerk
	var hits := _hits(lair)
	await _act(lair, &"E1", &"Ability.Gildedbreath", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Fire"), "Gilded Breath hits the whole party with Fire")
	var drake := lair.unit_by_id(&"E1")
	_hurt(lair, drake, 20)
	var hp_before := drake.stat(BattleUnit.HP)
	await _act(lair, &"E1", &"Ability.Hoardgreed", &"")
	check(drake.stat(BattleUnit.HP) > hp_before, "Hoard Greed heals the Drake")
	check(drake.asc.has_tag_exact(&"Status.Buff.AttackUp"), "Hoard Greed rallies the Drake")
	_check_elite_phase(lair, &"E1", &"Ability.Bite", &"Ability.Furybreath")


func test_coven_enemies() -> void:
	if not _ready_to_test():
		return
	var circle := _battle("doll_circle")  # E1, E2 Hex Dolls, E3 Cultist
	var hits := _hits(circle)
	var bled := false
	for attempt in 12:
		await _act(circle, &"E1", &"Ability.Pinprick", &"P1")
		bled = bled or circle.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Debuff.Bleed")
	check(hits.any(func(hit): return hit[0] == &"E1" and hit[2].has(&"Damage.Type.Physical")), "Pinprick is Physical")
	check(bled, "Pinprick bleeds (a 60% roll, 12 tries)")

	var familiars := _battle("familiars")  # E1, E2 Coven Familiars, E3 Bound Demon
	hits = _hits(familiars)
	await _act(familiars, &"E1", &"Ability.Illomen", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Ice"), "Ill Omen hits the whole party with Ice")
	check(familiars.unit_by_id(&"E1").asc.has_tag_exact(&"Weakness.Fire"), "the Familiar is weak to Fire (Q7)")

	var coven := _battle("hag_sister")  # E1 Hag Sister, E2 Coven Familiar
	hits = _hits(coven)
	await _act(coven, &"E1", &"Ability.Boilover", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Fire"), "Boil Over hits the whole party with Fire")
	var hexed := false
	for attempt in 12:
		await _act(coven, &"E1", &"Ability.Haghex", &"")
		hexed = hexed or coven.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Debuff.Vulnerable")
	check(hexed, "the Hag's Hex makes the party Vulnerable (a 50% roll, 12 tries)")
	var familiar := coven.unit_by_id(&"E2")
	_hurt(coven, familiar, 50)
	var hp_before := familiar.stat(BattleUnit.HP)
	await _act(coven, &"E1", &"Ability.Cauldronbrew", &"")
	check(familiar.stat(BattleUnit.HP) > hp_before, "Cauldron Brew heals an ally")
	for id in [&"E1", &"E2"]:
		check(coven.unit_by_id(id).asc.has_tag_exact(&"Status.Buff.AttackUp"), "Cauldron Brew rallies %s" % id)
	_check_elite_phase(coven, &"E1", &"Ability.Haghex", &"Ability.Bitterboil")


func test_void_enemies() -> void:
	if not _ready_to_test():
		return
	var swarm := _battle("moth_swarm")
	var hits := _hits(swarm)
	await _act(swarm, &"E1", &"Ability.Dimwings", &"")
	check(_hit_both(hits, &"E1", &"Damage.Type.Ice"), "Dim Wings hits the whole party with Ice")

	var echoes := _battle("echoes")  # E1 Hollow Echo, E2 Void Wraith
	hits = _hits(echoes)
	await _act(echoes, &"E1", &"Ability.Echostrike", &"P1")
	eq(hits.filter(func(hit): return hit[0] == &"E1" and hit[1] == &"P1").size(), 2, "Echo Strike hits twice")
	var fired := DemoItems._fired(echoes)
	_sturdy(echoes.unit_by_id(&"E1"))
	await _act(echoes, &"P1", &"Ability.Strike", &"E1")
	check(not fired.has(&"Ability.Passive.Resound"), "Resound stays silent on a hit that isn't its weakness (Physical)")
	hits.clear()
	var caster := echoes.unit_by_id(&"P1")
	caster.asc.initialize_attribute_overrides({"max_mp": 100000.0, "mp": 100000.0})  # Ice Blast costs SP
	check(caster.asc.can_activate_ability(caster.ability_by_tag(&"Ability.Iceblast")), "the Warrior can cast Ice Blast")
	await _act(echoes, &"P1", &"Ability.Iceblast", &"E1")
	check(fired.has(&"Ability.Passive.Resound"), "Resound fires when the Echo is hit on its Ice weakness: %s" % [fired])
	check(hits.any(func(hit): return hit[0] == &"E1" and hit[1] == &"P1"), "and strikes the attacker back")
	# Spec Q7 review: the party's counters are Physical, so Thorn Mail (it strikes back at every hit) starts no chain.
	var thorns := Battle.new()
	host.add_child(thorns)
	_battles.append(thorns)
	check(thorns.setup(DemoItems._snapshot(["demo.item.thorn_mail"], "echoes"), DemoItems._demo_content()) == "", "setup")
	_sturdy(thorns.unit_by_id(&"P1"))
	_sturdy(thorns.unit_by_id(&"E1"))
	fired = DemoItems._fired(thorns)
	await _act(thorns, &"E1", &"Ability.Echostrike", &"P1")
	check(fired.has(&"Ability.Passive.Thornmail"), "the Warrior's Thorn Mail strikes back: %s" % [fired])
	check(not fired.has(&"Ability.Passive.Resound"), "and the Echo doesn't answer the Physical counter")
	eq(Array(thorns.content_warnings), [], "no trigger chain warning")

	var maw := _battle("devourer")  # E1 Void Devourer, E2 Null Moth
	var devourer := maw.unit_by_id(&"E1")
	var delayed := _delays(maw)
	var well_hits := _hits(maw)
	await _act(maw, &"E1", &"Ability.Gravitywell", &"")
	check(delayed.has(&"P1") and delayed.has(&"P2"), "Gravity Well delays every target: %s" % [delayed])
	eq(well_hits.size(), 0, "Gravity Well deals no damage")
	fired = DemoItems._fired(maw)
	_hurt(maw, devourer, 30)
	var hp_before := devourer.stat(BattleUnit.HP)
	await _act(maw, &"E1", &"Ability.Consume", &"P1")
	check(fired.has(&"Ability.Passive.Gorge"), "Consume triggers Gorge: %s" % [fired])
	check(devourer.stat(BattleUnit.HP) > hp_before, "Gorge heals the Devourer")
	fired.clear()
	await _act(maw, &"E1", &"Ability.Tremor", &"")
	check(not fired.has(&"Ability.Passive.Gorge"), "Gorge heals only on Consume")
	_check_elite_phase(maw, &"E1", &"Ability.Tremor", &"Ability.Ravenousmaw")
	fired.clear()
	await _act(maw, &"E1", &"Ability.Ravenousmaw", &"P1")
	check(fired.has(&"Ability.Passive.Gorge"), "the phase's Consume copy heals through Gorge too")


## Spec 3.3, 3.6: the encounters join their chapter's pool, the elites at a lower weight, none a boss fight; each new
## enemy has its drop.
func test_route_encounters_and_drops() -> void:
	if not _ready_to_test():
		return
	var chapters := {"bell_tower": &"Chapter.Cathedral", "vespers": &"Chapter.Cathedral", "glass_saint": &"Chapter.Cathedral",
		"counting_house": &"Chapter.Vault", "gargoyle_watch": &"Chapter.Vault", "drake_lair": &"Chapter.Vault",
		"doll_circle": &"Chapter.Coven", "familiars": &"Chapter.Coven", "hag_sister": &"Chapter.Coven",
		"moth_swarm": &"Chapter.Void", "echoes": &"Chapter.Void", "devourer": &"Chapter.Void"}
	for name in chapters:
		var encounter: EncounterDefinition = load(DEMO + "encounters/%s.tres" % name)
		check(encounter.tags.has(chapters[name]) and not encounter.tags.has(&"Encounter.Boss"),
			"%s is a %s battle, not a boss fight" % [name, chapters[name]])
		check(encounter.rewards.is_empty(), "%s has no rewards (Q5)" % name)
		var regular := REGULAR_ENCOUNTERS.has(name)
		check(encounter.weight_x100 < 100 if not regular else encounter.weight_x100 == 100,
			"%s weight %d" % [name, encounter.weight_x100])
	for name in ELITE_ENCOUNTERS:
		var elite: EnemyDefinition = (load(DEMO + "encounters/%s.tres" % name) as EncounterDefinition).slots[0].enemy
		check(elite.tags.has(&"Enemy.Rank.Elite") and not elite.tags.has(&"Enemy.Boss"), "%s is an elite, never a boss" % elite.id)
		check(elite.overtime_turn == 0 and not elite.mirror_party_items, "%s has no overtime or mirror" % elite.id)
		check(elite.drop_item != null and elite.drop_chance_x100 > 0, "%s may drop an item" % elite.id)
	for name in ["bell_ringer", "candle_acolyte", "tally_clerk", "vault_gargoyle", "hex_doll", "coven_familiar",
			"null_moth", "hollow_echo"]:
		var enemy: EnemyDefinition = load(DEMO + "enemies/%s.tres" % name)
		check(enemy.drop_item != null and enemy.drop_item.tags.has(&"Pool.Food"), "%s drops food" % name)
	eq((load(DEMO + "enemies/void_devourer.tres") as EnemyDefinition).drop_item.id, &"demo.item.vampire_fang",
		"the Void Devourer drops the Vampire Fang (Q7)")


## Spec 4, 6: a fight against each new encounter (the Warrior and the Cleric on the scripted controller) replays Verified
## with no content warning, and between them the fights use every new ability outside the elites' phases (those are
## checked above, since a fight may end before the phase).
func test_route_encounters_replay() -> void:
	if not _ready_to_test():
		return
	var used := {}
	for name in REGULAR_ENCOUNTERS + ELITE_ENCOUNTERS:
		var snap := DemoItems._snapshot([], name)
		snap["battleId"] = "route-" + name
		var battle := Battle.new()
		host.add_child(battle)
		_battles.append(battle)
		check(battle.setup(snap, DemoItems._demo_content()) == "", "setup " + name)
		battle.ability_activated.connect(func(_unit, ability, _target): used[ability] = true)
		battle.trigger_activated.connect(func(_unit, ability, _event): used[ability] = true)
		var controller := ScriptedController.new()
		await battle.run(controller)
		check(battle.runner_error == "", "%s: no runner error: %s" % [name, battle.runner_error])
		eq(Array(battle.content_warnings), [], "%s: no content warning" % name)
		var request := {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
		var result: Dictionary = await ReplayRunner.new().run(copy(request), CONTENT_ROOT, host)
		eq(result.get("verdict"), "Verified", "%s replays: %s" % [name, result])
	for tag in [&"Ability.Toll", &"Ability.Votiveflame", &"Ability.Prismray", &"Ability.Stainedward", &"Ability.Levy",
			&"Ability.Stonegaze", &"Ability.Gildedbreath", &"Ability.Hoardgreed", &"Ability.Pinprick", &"Ability.Illomen",
			&"Ability.Boilover", &"Ability.Haghex", &"Ability.Cauldronbrew", &"Ability.Dimwings", &"Ability.Echostrike",
			&"Ability.Consume", &"Ability.Gravitywell", &"Ability.Passive.Gorge", &"Ability.Vigil"]:
		# Resound needs an Ice hit, which the scripted Warrior and Cleric never make: test_void_enemies covers it.
		check(used.has(tag), "%s is used in the fights" % tag)


## Spec 3.6 (review, 2026-11-13): a drop obeys the run's card pool. Outside it, an item-room item from the pool, else
## food; a run without a pool, or a drop inside it, gets the designed item.
func test_drops_obey_the_card_pool() -> void:
	if not _ready_to_test():
		return
	var content := DemoItems._demo_content()
	var fang: ItemDefinition = load(DEMO + "items/vampire_fang.tres")
	var treasure: Array = []
	var food: Array = []
	for id in content.items:
		var tags: Array = content.items[id].tags
		if tags.has(&"Pool.Treasure") and id != fang.id:
			treasure.append(id)
		if tags.has(&"Pool.Food") and not tags.has(&"Pool.Treasure"):
			food.append(id)  # a Food+Treasure item would be the Treasure pick's, so "only food" leaves it out
	var cases := [[null, "no pool"], [[fang.id] + food, "the Fang in the pool"], [treasure + food, "the Fang outside"],
		[food, "only food"], [[], "an empty pool"]]
	var dropped := {}
	for case in cases:
		var run := RunController.new()
		host.add_child(run)
		_nodes.append(run)
		eq(run.start_run(content, ["demo.character.warrior"], "7", &"", case[0]), "", "a run with %s starts" % case[1])
		var stream := RunSeeds.rng(3, "drop")
		var state_before := stream.state
		var item: ItemDefinition = run._pooled_drop(fang, stream)
		dropped[case[1]] = item.id if item != null else &""
		if case[1] in ["no pool", "the Fang in the pool"]:
			eq(stream.state, state_before, "%s: the drop stream draws nothing more" % case[1])
		elif item != null:
			check(run.state.seen_items.has(item.id), "the substitute is marked seen")
		if case[1] == "the Fang outside":
			check(item != null and treasure.has(item.id), "outside the pool: an item-room item from it (%s)" % dropped[case[1]])
		if case[1] == "only food":
			var holdable := food.filter(func(id): return run.can_hold(1, content.items[id]) == "")
			if holdable.is_empty():
				eq(item, null, "food nobody can hold is never dropped (full use slots)")
				run.state.party[0]["use_slots"].clear()
				item = run._pooled_drop(fang, RunSeeds.rng(3, "drop"))
			else:
				check(item != null and holdable.has(item.id), "the food dropped is one the Warrior can hold")
			check(item != null and food.has(item.id), "no item-room item in the pool: food (%s)" % [item.id if item else &""])
	eq(dropped["no pool"], fang.id, "a run without a pool drops the designed item")
	eq(dropped["the Fang in the pool"], fang.id, "a pooled drop inside the pool is the designed item")
	eq(dropped["an empty pool"], &"", "nothing to give: no drop")
