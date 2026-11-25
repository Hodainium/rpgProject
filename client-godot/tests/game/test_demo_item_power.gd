## Content test for spec item-power 2.3: the 40 new demo items and pieces are there, tagged for pools, sets, rarity and bots, and
## the special ones do what their description says: by direction only, never by the tuned number. Skipped without the demo.
extends TestCase

const DEMO: String = "res://content/demo/"
const ITEMS: Array[String] = ["chain_bell", "feast_knife", "vengeful_aegis", "sun_heart", "undying_ember", "shatter_covenant",
	"philosophers_coin", "twin_soul", "plague_crown", "echo_crown", "void_heart", "hollow_crown", "void_tether", "null_lens",
	"starving_maw", "echo_of_nothing", "chain_hook", "reapers_mark", "guardians_vow", "venom_spur", "second_wind",
	"lifebloom_seed", "battle_hymn", "bulwark_sigil", "static_ring", "hunters_snare", "blood_charm", "thick_hide", "kindling",
	"quick_draw", "focus_stone", "menders_bell"]
const GEAR: Array[String] = ["executioners_greatsword", "storm_spear", "bloodthirst_blade", "runebound_staff", "thornheart_plate",
	"sentinel_plate", "mantle_of_haste", "warlords_crown"]

static var _demo: ContentIndex


static func _content_index() -> ContentIndex:
	if _demo == null:
		_demo = ContentIndex.new("res://content/")
	return _demo


func _ready_to_test() -> bool:
	if ResourceLoader.exists(DEMO + "items/chain_bell.tres"):
		return true
	print("    skipped: no item-power content under ", DEMO)
	return false


## Warrior (P1, holding `items`, wearing `gear`) and Cleric (P2, holding `second`) against two slimes.
func _battle(items: Array = [], gear: Array = [], second: Array = []) -> Battle:
	var ids := func(names: Array, kind: String) -> Array:
		return names.map(func(name: String) -> String: return "demo.%s.%s" % [kind, name])
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup({"schemaVersion": 2, "battleId": "demo-item-power", "seed": "5",
		"encounterId": "demo.encounter.slime_pair", "party": [
			{"slot": 1, "unitDefId": "demo.character.warrior", "level": 1, "skills": [],
				"equipmentIds": ids.call(gear, "equipment"), "items": ids.call(items, "item"), "useSlots": []},
			{"slot": 2, "unitDefId": "demo.character.cleric", "level": 1, "skills": [], "equipmentIds": [],
				"items": ids.call(second, "item"), "useSlots": []}]}, _content_index())
	check(error == "", "demo battle setup: " + error)
	for unit in battle.units():  # no enemy dies of one hit
		if not unit.is_party():
			_set_stat(unit, "max_hp", 1000000)
			_set_stat(unit, "hp", 1000000)
	return battle


func _act(battle: Battle, actor: StringName, ability: StringName, target: StringName = &"") -> void:
	var unit := battle.unit_by_id(actor)
	await battle._activate(unit, unit.ability_by_tag(ability), battle.unit_by_id(target) if target != &"" else null)
	await battle._drain_triggers()


func _start_events(battle: Battle) -> void:
	for unit in battle.units():
		unit.asc.send_gameplay_event(Battle.EVENT_BATTLE_START, {"source": unit, "target": unit})
	await battle._drain_triggers()


func _always(battle: Battle, unit_id: StringName) -> void:
	for ability in battle.unit_by_id(unit_id).abilities():
		ability.trigger_chance_x100 = 0


static func _set_stat(unit: BattleUnit, attribute: String, value: int) -> void:
	unit.asc.initialize_attribute_overrides({attribute: float(value)} as Dictionary[String, float])


static func _set_hp(unit: BattleUnit, value: int) -> void:
	_set_stat(unit, "hp", value)


func test_forty_tagged_things() -> void:
	if not _ready_to_test():
		return
	var content := _content_index()
	eq(ITEMS.size() + GEAR.size(), 40, "forty new things")
	var sets := {}
	for pair in [[ITEMS, "item", content.items], [GEAR, "equipment", content.equipment]]:
		for name in pair[0]:
			var thing: Resource = pair[2].get(StringName("demo.%s.%s" % [pair[1], name]))
			check(thing != null, "%s exists" % name)
			if thing == null:
				continue
			var tags: Array = thing.get("tags")
			var count := func(prefix: String) -> int:
				return tags.filter(func(tag) -> bool: return String(tag).begins_with(prefix)).size()
			check(count.call("Pool.") > 0 and count.call("Item.Rarity.") == 1 and count.call("Card.Set.") == 1,
				"%s has its pools, rarity and set" % name)
			check(count.call("Item.Fit.") > 0, "%s tells the bots who it fits" % name)
			check(not (tags.has(&"Pool.Treasure") and tags.has(&"Pool.Boss")), "%s is not in both the item rooms' and the boss's pool" % name)
			eq(FitProposal.missing(thing), [], "%s carries what the fit pass would propose" % name)
			for tag in tags:
				if String(tag).begins_with("Card.Set."):
					sets[String(tag)] = int(sets.get(String(tag), 0)) + 1
	eq(sets, {"Card.Set.Core": 33, "Card.Set.Descent": 7}, "33 core, 7 Descent")
	check(not content.items[&"demo.item.philosophers_gold"].tags.any(func(tag) -> bool: return String(tag).begins_with("Pool.")),
		"the Philosopher's Gold is in no pool, so it is no card")


func test_follow_ups_and_strikes() -> void:
	if not _ready_to_test():
		return
	var bell := _battle(["chain_bell", "chain_hook", "static_ring"])
	_always(bell, &"P1")
	var other := bell.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _act(bell, &"P1", &"Ability.Strike", &"E1")
	check(bell.unit_by_id(&"E2").stat(BattleUnit.HP) < other, "the bell and the hook reach the other enemy")
	var spear := _battle([], ["storm_spear"])
	other = spear.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _act(spear, &"P1", &"Ability.Strike", &"E1")
	check(spear.unit_by_id(&"E2").stat(BattleUnit.HP) < other, "the spear strikes another enemy")
	var sun := _battle(["sun_heart"])
	other = sun.unit_by_id(&"E2").stat(BattleUnit.HP)
	await _act(sun, &"P1", &"Ability.Strike", &"E1")
	check(sun.unit_by_id(&"E2").stat(BattleUnit.HP) < other, "the Sun Heart's basic attacks splash")
	check(sun.unit_by_id(&"P1").stat("sp_basic") > _battle().unit_by_id(&"P1").stat("sp_basic"), "and give more SP")
	var crowned := _battle(["static_ring", "hollow_crown"])
	_always(crowned, &"P1")
	var fired := []
	crowned.trigger_activated.connect(func(_unit, tag, _event): fired.append(tag))
	await _act(crowned, &"P1", &"Ability.Strike", &"E1")
	eq(fired.count(&"Ability.Passive.HollowCrown"), TriggerQueue.MAX_DEPTH, "the Hollow Crown chains to the cap")
	check(crowned.unit_by_id(&"P1").stat(BattleUnit.MAX_HP) < _battle().unit_by_id(&"P1").stat(BattleUnit.MAX_HP), "for max HP")


func test_ally_hits() -> void:
	if not _ready_to_test():
		return
	for name in ["vengeful_aegis", "void_tether", "guardians_vow"]:
		var battle := _battle([name])
		var slime := battle.unit_by_id(&"E1")
		var cleric := battle.unit_by_id(&"P2")
		var warrior_hp := battle.unit_by_id(&"P1").stat(BattleUnit.HP)
		@warning_ignore("integer_division")
		_set_hp(cleric, cleric.stat(BattleUnit.MAX_HP) / 2)
		var slime_hp := slime.stat(BattleUnit.HP)
		var ability: BattleAbility = slime.action_abilities()[0]
		await battle._activate(slime, ability, cleric)
		var hurt := cleric.stat(BattleUnit.HP)
		await battle._drain_triggers()
		check(slime.stat(BattleUnit.HP) < slime_hp, "%s strikes the attacker" % name)
		eq(cleric.stat(BattleUnit.HP) > hurt, name == "guardians_vow", "%s: only the Vow heals the one that was hit" % name)
		eq(battle.unit_by_id(&"P1").stat(BattleUnit.HP) < warrior_hp, name == "void_tether", "%s: only the Tether costs HP" % name)


func test_kills() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(["starving_maw", "second_wind", "blood_charm", "reapers_mark", "feast_knife"])
	var warrior := battle.unit_by_id(&"P1")
	_set_hp(warrior, 10000)
	var atk := warrior.stat("atk")
	var enemy_hp := battle.unit_by_id(&"E1").stat(BattleUnit.HP) + battle.unit_by_id(&"E2").stat(BattleUnit.HP)
	warrior.asc.send_gameplay_event(Battle.EVENT_UNIT_KILLED, {"source": warrior, "target": battle.unit_by_id(&"E1")})
	await battle._drain_triggers()
	check(warrior.stat(BattleUnit.HP) > 10000, "a kill heals")
	check(warrior.stat("atk") > atk, "and raises ATK")
	check(battle.unit_by_id(&"E1").stat(BattleUnit.HP) + battle.unit_by_id(&"E2").stat(BattleUnit.HP) < enemy_hp, "the knife strikes")
	var hp := warrior.stat(BattleUnit.HP)
	warrior.asc.send_gameplay_event(Battle.EVENT_TURN_START, {"source": warrior, "target": warrior})
	await battle._drain_triggers()
	check(warrior.stat(BattleUnit.HP) < hp, "the Maw hungers each turn")
	_set_hp(warrior, 100)
	warrior.asc.send_gameplay_event(Battle.EVENT_TURN_START, {"source": warrior, "target": warrior})
	await battle._drain_triggers()
	eq(warrior.stat(BattleUnit.HP), 100, "but never kills")


func test_undying_ember() -> void:
	if not _ready_to_test():
		return
	for items in [["undying_ember"], ["undying_ember", "void_heart"]]:
		var battle := _battle(items)
		var warrior := battle.unit_by_id(&"P1")
		var atk := warrior.stat("atk")
		_set_hp(warrior, 0)
		await battle._settle_deaths()
		check(warrior.alive and warrior.stat(BattleUnit.HP) > 0, "%s: saved" % [items])
		check(warrior.stat("atk") > atk, "with more ATK")
		_set_hp(warrior, 0)
		await battle._settle_deaths()
		check(not warrior.alive, "once per battle")


func test_echo_and_ults() -> void:
	if not _ready_to_test():
		return
	var battle := _battle([], [], ["twin_soul"])
	var cleric := battle.unit_by_id(&"P2")
	var warrior := battle.unit_by_id(&"P1")
	_set_stat(cleric, "max_mp", 50000)
	_set_stat(cleric, "mp", 50000)
	_set_hp(warrior, 10000)
	await battle._activate(cleric, cleric.ability_by_tag(&"Ability.Heal"), warrior)
	var once := warrior.stat(BattleUnit.HP) - 10000
	var mp := cleric.stat(BattleUnit.MP)
	await battle._drain_triggers()
	var echoed := warrior.stat(BattleUnit.HP) - 10000 - once
	check(echoed > 0 and echoed < once, "the heal casts again, smaller (%d, then %d)" % [once, echoed])
	eq(cleric.stat(BattleUnit.MP), mp, "for free")
	var crown := _battle(["echo_crown", "echo_of_nothing"])
	var fired := []
	crown.trigger_activated.connect(func(unit, tag, _event): fired.append("%s %s" % [unit, tag]))
	var caster := crown.unit_by_id(&"P1")
	_set_stat(caster, "energy", 10000)
	var ult: BattleAbility = caster.ultimate_abilities()[0]
	var candidates := crown.target_candidates(caster, ult)
	await crown._activate(caster, ult, candidates[0] if ult.needs_target() else null)
	await crown._drain_triggers()
	check(fired.has("P1 Ability.Passive.EchoCrownSelf") and fired.has("P2 Ability.Passive.EchoCrownAlly"), "every ally follows an ult: %s" % [fired])
	check(caster.stat(BattleUnit.ENERGY) > 0 and caster.stat(BattleUnit.ENERGY) < 10000, "part of the charge comes back, never all of it")


func test_dots() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(["venom_spur", "plague_crown"])
	await _act(battle, &"P1", &"Ability.Strike", &"E1")
	var poisoned := func(unit: BattleUnit) -> bool: return unit.asc.has_tag_exact(&"Status.Debuff.Poison")
	check(poisoned.call(battle.unit_by_id(&"E1")), "a hit poisons")
	check(not poisoned.call(battle.unit_by_id(&"E2")), "its target only")
	battle.unit_by_id(&"E1").asc.turn_start()
	await battle._drain_triggers()
	check(poisoned.call(battle.unit_by_id(&"E2")), "a tick spreads it")


func test_void_heart_and_gear() -> void:
	if not _ready_to_test():
		return
	var heart := _battle(["void_heart"])
	var warrior := heart.unit_by_id(&"P1")
	_set_hp(warrior, 10000)
	await heart._activate(heart.unit_by_id(&"P2"), heart.unit_by_id(&"P2").ability_by_tag(&"Ability.Heal"), warrior)
	eq(warrior.stat(BattleUnit.HP), 10000, "the Void Heart's holder can't be healed")
	_check_heals_read_heal_taken()
	var sword := _battle([], ["executioners_greatsword"])
	var slime := sword.unit_by_id(&"E1")
	_set_hp(slime, 400000)
	await _act(sword, &"P1", &"Ability.Strike", &"E1")
	check(slime.stat(BattleUnit.HP) > 0, "above a quarter: nothing")
	_set_hp(slime, 200000)
	await _act(sword, &"P1", &"Ability.Strike", &"E1")
	eq(slime.stat(BattleUnit.HP), 0, "below it: finished")
	var boss := _battle([], ["executioners_greatsword"])
	boss.unit_by_id(&"E1").asc.add_tag(&"Enemy.Boss")
	_set_hp(boss.unit_by_id(&"E1"), 200000)
	await _act(boss, &"P1", &"Ability.Strike", &"E1")
	check(boss.unit_by_id(&"E1").stat(BattleUnit.HP) > 0, "never a boss")
	var mirrored := _battle()
	var finisher := GameplayEffectSpec.new(load(DEMO + "effects/greatsword_finish.tres"),
		GameplayEffectContext.new(mirrored.unit_by_id(&"E1"), mirrored.unit_by_id(&"E1")), 1)
	_set_hp(mirrored.unit_by_id(&"P1"), 100)
	mirrored.unit_by_id(&"P1").asc.apply_effect_spec(finisher)
	eq(mirrored.unit_by_id(&"P1").stat(BattleUnit.HP), 100, "never a party member (a mirror boss copies the sword)")
	var blade := _battle([], ["bloodthirst_blade"])
	_set_hp(blade.unit_by_id(&"P1"), 10000)
	await _act(blade, &"P1", &"Ability.Strike", &"E1")
	check(blade.unit_by_id(&"P1").stat(BattleUnit.HP) > 10000, "the blade drinks")
	var plate := _battle([], ["thornheart_plate"])
	var attacker := plate.unit_by_id(&"E1")
	var before := attacker.stat(BattleUnit.HP)
	var wearer_before := plate.unit_by_id(&"P1").stat(BattleUnit.HP)
	await plate._activate(attacker, attacker.action_abilities()[0], plate.unit_by_id(&"P1"))
	var taken := wearer_before - plate.unit_by_id(&"P1").stat(BattleUnit.HP)
	await plate._drain_triggers()
	var reflected := before - attacker.stat(BattleUnit.HP)
	check(reflected > 0 and reflected < taken, "the plate reflects a part (%d of %d)" % [reflected, taken])
	var crown := _battle([], ["warlords_crown"])
	var atk := crown.unit_by_id(&"P2").stat("atk")
	await _start_events(crown)
	check(crown.unit_by_id(&"P2").stat("atk") > atk, "the Warlord's Crown covers the party")
	var sentinel := _battle([], ["sentinel_plate"])
	await _start_events(sentinel)
	check(sentinel.unit_by_id(&"P1").asc.has_tag_exact(Battle.TAUNTING_TAG), "the Sentinel taunts")
	var mantle := _battle(["quick_draw"], ["mantle_of_haste"])
	var av: int = mantle.turn_manager.av[mantle.unit_by_id(&"P1")]
	await _start_events(mantle)
	check(int(mantle.turn_manager.av[mantle.unit_by_id(&"P1")]) < av, "a head start")


func test_philosophers_coin_in_a_run() -> void:
	if not _ready_to_test():
		return
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_run(_content_index(), ["demo.character.warrior", "demo.character.cleric"], "7"), "", "run starts")
	run.state.member(2)["items"].append(&"demo.item.philosophers_coin")
	run._run_hooks("on_floor_start")
	run._run_hooks("on_floor_start")
	eq(run.state.member(2)["items"].count(&"demo.item.philosophers_gold"), 2, "a piece of gold per floor, to its holder")
	run.free()


## The user's call (2026-11-24): healing really does nothing for the Void Heart's holder: every heal a party member can get
## reads heal_taken. Revives (and the two heals that also revive) do not: they must still raise its holder.
func _check_heals_read_heal_taken() -> void:
	var heals := ["corrupted_bounty", "corrupted_vampire_heal", "mirror_heal", "mimic_mend", "heartstring_heal", "holy_heal",
		"lv_shield_wall", "food_heal_15", "food_heal_25", "food_heal_30", "events/heal_15", "events/heal_20", "events/heal_30",
		"events/heal_full", "spring_bathe", "spring_drink"]
	var effects := {}
	for name in heals:
		effects[name] = load(DEMO + "effects/%s.tres" % name)
	for chest in ["wooden", "gilded"]:
		for reward in (load(DEMO + "chests/%s_chest.tres" % chest) as ChestDefinition).rewards:
			for outcome in reward.outcomes:
				if outcome is ApplyPartyEffect:
					effects[chest] = outcome.effect
	eq(effects.size(), 18, "18 heals")
	for name in effects:
		var plain := 0
		for items in [[], ["blessed_amulet"], ["void_heart"]]:
			var battle := _battle(items)
			var warrior := battle.unit_by_id(&"P1")
			_set_stat(warrior, "max_hp", 1000000)
			_set_hp(warrior, 10000)
			warrior.asc.apply_gameplay_effect(effects[name], warrior.asc, 1)
			var healed := warrior.stat(BattleUnit.HP) - 10000
			if items.is_empty():
				check(healed > 0, "%s heals" % name)
				plain = healed
			elif items == ["void_heart"]:
				eq(healed, 0, "%s does nothing for the Void Heart's holder" % name)
			else:  # capped at the maximum HP
				eq(healed, mini(plain * 5 / 4, 990000), "%s reads the Blessed Amulet's +25%%" % name)
	for name in ["revive", "salts_revive", "second_heart_revive", "resurrection_revive", "undying_ember_rise", "waystation_heal",
			"medic_heal"]:
		var battle := _battle(["void_heart"])
		var warrior := battle.unit_by_id(&"P1")
		_set_hp(warrior, 0)
		warrior.asc.apply_gameplay_effect(load(DEMO + "effects/%s.tres" % name), warrior.asc, 1)
		check(warrior.stat(BattleUnit.HP) > 0, "%s still raises the Void Heart's holder" % name)


## The user's call (2026-11-24): a mirror boss skips the Philosopher's Gold like food, but still counts each piece.
func test_mirrors_skip_philosophers_gold() -> void:
	if not _ready_to_test():
		return
	for boss in ["collector", "reflection"]:
		var definition: EnemyDefinition = _content_index().units[StringName("demo.enemy." + boss)]
		var stats := func(items: Array) -> Dictionary:
			var battle := Battle.new()
			host.add_child(battle)
			_battles.append(battle)
			var encounter := "demo.encounter.collector" if boss == "collector" else "demo.encounter.event_reflection"
			eq(battle.setup({"schemaVersion": 2, "battleId": "demo-gold", "seed": "5", "encounterId": encounter,
				"party": [{"slot": 1, "unitDefId": "demo.character.warrior", "level": 1, "skills": [], "equipmentIds": [],
					"items": items, "useSlots": []}]}, _content_index()), "", boss + " sets up")
			var result := {}
			for attribute in ["atk", "def", "max_hp"]:
				for unit in ["E1", "P1"]:
					result[unit + attribute] = battle.unit_by_id(StringName(unit)).stat(attribute)
			return result
		var gold: Array = ["demo.item.philosophers_gold", "demo.item.philosophers_gold"]
		var bare: Dictionary = stats.call([])
		var rich: Dictionary = stats.call(gold)
		var counted := 400 if definition.per_item_effect != null else 0  # +2% of base per piece held, 2 pieces
		for attribute in ["atk", "def", "max_hp"]:
			var base: int = definition.stats_x100[attribute]
			eq(rich["E1" + attribute] - bare["E1" + attribute], Fixed.pct(base, counted),
				"%s %s: only the piece count, no copied Gold" % [boss, attribute])
			check(rich["P1" + attribute] > bare["P1" + attribute], "the holder still gets its %s" % attribute)
