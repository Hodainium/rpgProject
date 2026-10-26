## Content test for the item pass (spec item-pass 6): every new demo item and armor piece does what its description
## says, checked by direction only (a stat goes up, a passive fires, a coin is gained), never by the tuned number, so
## tuning can't fail it. Like test_demo_content it reads res://content/ and is skipped when the demo isn't there.
extends TestCase

const DEMO: String = "res://content/demo/"
const CONTENT_ROOT: String = "res://content/"

static var _demo: ContentIndex


static func _demo_content() -> ContentIndex:
	if _demo == null:
		_demo = ContentIndex.new(CONTENT_ROOT)
	return _demo


## Skips (with a note) unless the example set and the item-pass attributes exist.
func _ready_to_test() -> bool:
	if not ResourceLoader.exists(DEMO + "items/iron_ring.tres"):
		print("    skipped: no item-pass content under ", DEMO)
		return false
	var probe: AttributeSet = _demo_content().characters[&"demo.character.warrior"].attribute_set.new()
	if probe.get("weakness_dmg") == null:
		print("    skipped: generate the Unit AttributeSet (GodotGAS dashboard) to add weakness_dmg / toughness_dmg / broken_dmg")
		return false
	return true


## Warrior (P1, holding `items`, wearing `gear`) and Cleric (P2) against `encounter`.
static func _snapshot(items: Array = [], encounter: String = "slime_pair", gear: Array = [], use_slots: Array = []) -> Dictionary:
	return {
		"schemaVersion": 2, "battleId": "demo-items", "seed": "5", "encounterId": "demo.encounter." + encounter,
		"party": [
			{"slot": 1, "unitDefId": "demo.character.warrior", "level": 1, "skills": ["Ability.Iceblast"],
				"equipmentIds": ["demo.equipment.iron_sword"] + gear, "items": items, "useSlots": use_slots},
			{"slot": 2, "unitDefId": "demo.character.cleric", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": []},
		],
	}


func _battle(snap: Dictionary) -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup(snap, _demo_content())
	check(error == "", "demo battle setup: " + error)
	return battle


## Triggered passives that fired: [ability tag, ...].
static func _fired(battle: Battle) -> Array:
	var fired := []
	battle.trigger_activated.connect(func(_unit, ability, _event): fired.append(ability))
	return fired


func _act(battle: Battle, actor: StringName, ability: StringName, target: StringName) -> void:
	var unit := battle.unit_by_id(actor)
	await battle._activate(unit, unit.ability_by_tag(ability), battle.unit_by_id(target))
	battle._check_deaths()
	await battle._drain_triggers()


func test_stat_items_and_armor() -> void:
	if not _ready_to_test():
		return
	var base := _battle(_snapshot())
	var cases := [
		["items", "iron_ring", "def", 1], ["items", "swift_charm", "spd", 1], ["items", "lucky_coin", "crit_rate", 1],
		["items", "glass_lens", "crit_dmg", 1], ["items", "glass_lens", "max_hp", -1], ["items", "mana_crystal", "max_mp", 1],
		["items", "heart_locket", "max_hp", 1], ["items", "shatter_hammer", "toughness_dmg", 1],
		["items", "predators_fang", "broken_dmg", 1],
		["gear", "leather_cap", "def", 1], ["gear", "leather_cap", "max_hp", 1], ["gear", "seers_circlet", "crit_rate", 1],
		["gear", "chain_vest", "def", 1], ["gear", "mage_robe", "max_mp", 1], ["gear", "mage_robe", "atk", 1],
		["gear", "bracers", "atk", 1], ["gear", "swift_boots", "spd", 1], ["gear", "greaves", "def", 1],
		["gear", "greaves", "spd", -1],
	]
	for case in cases:
		var snap := _snapshot(["demo.item." + case[1]] if case[0] == "items" else [], "slime_pair",
			["demo.equipment." + case[1]] if case[0] == "gear" else [])
		var battle := _battle(snap)
		var change: int = signi(battle.unit_by_id(&"P1").stat(case[2]) - base.unit_by_id(&"P1").stat(case[2]))
		eq(change, case[3], "%s changes %s the right way" % [case[1], case[2]])
	for case in [["war_drum", "spd"], ["guardian_totem", "def"]]:
		var party := _battle(_snapshot(["demo.item." + case[0]]))
		check(party.unit_by_id(&"P2").stat(case[1]) > base.unit_by_id(&"P2").stat(case[1]), "%s reaches the whole party" % case[0])


func test_triggered_items() -> void:
	if not _ready_to_test():
		return
	# Taking a hit: Thorn Mail strikes back; Glass Heart heals on a critical hit taken.
	var hit := _battle(_snapshot(["demo.item.thorn_mail", "demo.item.glass_heart"]))
	var fired := _fired(hit)
	hit.unit_by_id(&"E1").asc.initialize_attribute_overrides({"crit_rate": 10000.0})
	await _act(hit, &"E1", &"Ability.Bite", &"P1")
	check(fired.has(&"Ability.Passive.Thornmail"), "Thorn Mail strikes back when hit")
	check(fired.has(&"Ability.Passive.Glassheart"), "Glass Heart heals on a critical hit taken")

	# Dealing damage: Vampire Fang, Frost Needle (Physical → Ice), Sharp Eye / Executioner's Seal on a crit.
	var strike := _battle(_snapshot(["demo.item.vampire_fang", "demo.item.frost_needle", "demo.item.sharp_eye",
		"demo.item.executioners_seal"]))
	var struck := _fired(strike)
	strike.unit_by_id(&"P1").asc.initialize_attribute_overrides({"crit_rate": 10000.0})
	await _act(strike, &"P1", &"Ability.Strike", &"E1")
	for tag in [&"Ability.Passive.Vampirefang", &"Ability.Passive.Frostneedle", &"Ability.Passive.Sharpeye",
			&"Ability.Passive.Executioner"]:
		check(struck.has(tag), "%s fires from a critical Physical hit" % tag)

	# Battle start and turn start.
	var timed := _battle(_snapshot(["demo.item.battle_horn", "demo.item.hourglass"]))
	var ticks := _fired(timed)
	var warrior := timed.unit_by_id(&"P1")
	warrior.asc.initialize_attribute_overrides({"hp": 10000.0})
	warrior.asc.send_gameplay_event(Battle.EVENT_BATTLE_START, {"source": warrior, "target": warrior})
	warrior.asc.send_gameplay_event(Battle.EVENT_TURN_START, {"source": warrior, "target": warrior})
	await timed._drain_triggers()
	check(ticks.has(&"Ability.Passive.Battlehorn") and warrior.stat(BattleUnit.ENERGY) > 0, "Battle Horn charges the ult at battle start")
	check(ticks.has(&"Ability.Passive.Hourglass") and warrior.stat(BattleUnit.HP) > 10000, "Hourglass heals at turn start")

	# A kill: Bounty Mark.
	var kill := _battle(_snapshot(["demo.item.bounty_mark"]))
	var killed := _fired(kill)
	kill.unit_by_id(&"E1").asc.initialize_attribute_overrides({"hp": 100.0})
	await _act(kill, &"P1", &"Ability.Strike", &"E1")
	check(killed.has(&"Ability.Passive.Bountymark"), "Bounty Mark fires on a kill")


func test_weakness_break_and_follow_up_items() -> void:
	if not _ready_to_test():
		return
	var items := ["demo.item.hunters_mark", "demo.item.scholars_tome", "demo.item.momentum_charm", "demo.item.breakers_oath",
		"demo.item.cinder_glove", "demo.item.encore_ribbon"]
	var battle := _battle(_snapshot(items, "slime_pair", ["demo.equipment.hunters_gloves"],
		[{"itemId": "demo.item.fire_bomb", "ready": true}]))
	var fired := _fired(battle)
	var hits := []
	battle.damage_dealt.connect(func(_s, target, _a, hit_tags): hits.append([target, hit_tags]))
	await _act(battle, &"P1", &"Ability.Item.Firebomb", &"E1")
	var slime := battle.unit_by_id(&"E1")
	check(hits.any(func(entry): return entry[1].has(&"Hit.Weakness")), "Fire on a Slime is a weakness hit")
	check(slime.asc.has_tag_exact(Battle.BROKEN_TAG), "the Fire Bomb's 60 toughness damage breaks a Slime")
	check(slime.asc.has_tag_exact(&"Status.Debuff.Burn"), "Cinder Glove sets it ablaze")
	for tag in [&"Ability.Passive.Huntersmark", &"Ability.Passive.Scholarstome", &"Ability.Passive.Momentum",
			&"Ability.Passive.Breakersoath", &"Ability.Passive.Huntersgloves", &"Ability.Passive.Cinderglove"]:
		check(fired.has(tag), "%s fires" % tag)
	check(battle.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Buff.AttackUp"), "Breaker's Oath grants its ATK buff")
	check(hits.any(func(entry): return entry[1].has(&"Hit.FollowUp")), "Hunter's Mark's follow-up hits are follow-ups")
	eq(battle.one_more_queue, [battle.unit_by_id(&"P1")], "the break earns a One More")
	await battle._extra_action(battle.unit_by_id(&"P1"), ScriptedController.new())
	check(fired.has(&"Ability.Passive.Encore"), "Encore Ribbon fires on the One More")
	eq(battle.used_items.map(func(entry): return entry["item"]), [&"demo.item.fire_bomb"], "the bomb is used up")


## Spec content-pass 3.8 (item-pass gaps): on a Slime (weak to Fire) a Physical hit is a plain hit that leaves its
## toughness alone, while a Fire hit is a weakness hit that breaks it; the Broken Slime recovers full toughness at its
## next turn start, as the battle's turn loop does it.
func test_demo_slime_fire_vs_physical_and_recovery() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(_snapshot([], "slime_pair", [], [{"itemId": "demo.item.fire_bomb", "ready": true}]))
	var slime := battle.unit_by_id(&"E1")
	var other := battle.unit_by_id(&"E2")
	var hits := []
	battle.damage_dealt.connect(func(_s, target, _a, hit_tags): hits.append([target, hit_tags]))
	var toughness := slime.stat(Battle.TOUGHNESS)
	# The Physical check on the second Slime: a softened Slime would die to the bomb, and a kill is never a break.
	await _act(battle, &"P1", &"Ability.Strike", &"E2")
	check(not hits.is_empty() and not hits[-1][1].has(&"Hit.Weakness"), "a Physical Strike is no weakness hit on a Slime")
	eq(other.stat(Battle.TOUGHNESS), other.stat(Battle.MAX_TOUGHNESS), "and deals no toughness damage")
	await _act(battle, &"P1", &"Ability.Item.Firebomb", &"E1")
	check(hits[-1][1].has(&"Hit.Weakness"), "Fire is")
	check(slime.asc.has_tag_exact(Battle.BROKEN_TAG), "and breaks it")
	check(slime.stat(Battle.TOUGHNESS) < toughness, "its toughness is spent")
	battle._recover(slime)
	check(not slime.asc.has_tag_exact(Battle.BROKEN_TAG), "at its next turn start the Slime recovers")
	eq(slime.stat(Battle.TOUGHNESS), slime.stat(Battle.MAX_TOUGHNESS), "with full toughness")


func test_armor_passives() -> void:
	if not _ready_to_test():
		return
	# The Golem (2000 HP) survives a bomb, so the timed weakness stays visible (the dead drop timed effects).
	var battle := _battle(_snapshot([], "golem", ["demo.equipment.duelists_band", "demo.equipment.ember_pendant"],
		[{"itemId": "demo.item.fire_bomb", "ready": true}]))
	var fired := _fired(battle)
	battle.unit_by_id(&"P1").asc.initialize_attribute_overrides({"crit_rate": 10000.0})
	await _act(battle, &"P1", &"Ability.Strike", &"E1")
	check(fired.has(&"Ability.Passive.Duelistsband"), "Duelist's Band follows up a critical hit")
	battle.unit_by_id(&"P1").asc.initialize_attribute_overrides({"crit_rate": 0.0})
	await _act(battle, &"P1", &"Ability.Item.Firebomb", &"E1")
	check(fired.has(&"Ability.Passive.Emberpendant"), "Ember Pendant fires on Fire damage")
	check(battle.unit_by_id(&"E1").asc.has_tag_exact(&"Weakness.Fire"), "and makes the target weak to Fire")


func test_usable_items() -> void:
	if not _ready_to_test():
		return
	var slots := ["frost_bomb", "ether", "rally_horn", "smelling_salts"].map(
		func(name): return {"itemId": "demo.item." + name, "ready": true})
	var snap := _snapshot(["demo.item.satchel", "demo.item.satchel"], "bat_swarm")
	snap["party"][0]["items"] = []
	snap["party"][0]["useSlots"] = slots
	var battle := _battle(snap)
	var bat := battle.unit_by_id(&"E1")
	await _act(battle, &"P1", &"Ability.Item.Frostbomb", &"E1")
	check(not bat.alive or bat.asc.has_tag_exact(Battle.BROKEN_TAG), "a Frost Bomb breaks (or kills) a Bat")
	var cleric := battle.unit_by_id(&"P2")
	cleric.asc.initialize_attribute_overrides({"mp": 0.0})
	await _act(battle, &"P1", &"Ability.Item.Ether", &"P2")
	check(cleric.stat(BattleUnit.MP) > 0, "Ether restores MP")
	var atk_before := cleric.stat("atk")
	await _act(battle, &"P1", &"Ability.Item.Rally", &"")
	check(cleric.stat("atk") > atk_before, "Rally Horn raises the party's ATK")
	cleric.asc.initialize_attribute_overrides({"hp": 0.0})
	battle._check_deaths()
	await _act(battle, &"P1", &"Ability.Item.Salts", &"P2")
	check(cleric.alive and cleric.stat(BattleUnit.HP) > 0, "Smelling Salts revive")
	# Analyzer Lens on the Golem, minus its own Physical weakness, so only the lens can provide it.
	var lens := _battle(_snapshot([], "golem", [], [{"itemId": "demo.item.analyzer_lens", "ready": true}]))
	var golem := lens.unit_by_id(&"E1")
	golem.asc.clear_tag(&"Weakness.Physical")
	await _act(lens, &"P1", &"Ability.Item.Analyzer", &"E1")
	check(golem.asc.has_tag_exact(&"Weakness.Physical") and golem.asc.has_tag_exact(&"Status.Debuff.Exposed"),
		"Analyzer Lens exposes a weakness to Physical")


func test_run_hook_items() -> void:
	if not _ready_to_test():
		return
	var request := SandboxRequest.new()
	request.party = [&"demo.character.warrior", &"demo.character.cleric"]
	request.seed = 3
	request.room = _demo_content().rooms[&"demo.room.start"]
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_sandbox(_demo_content(), request), "", "a demo sandbox starts")
	var coins := run.state.coins
	run.dev_give(_demo_content().items[&"demo.item.golden_idol"], 1)
	eq(run.state.coins, coins + 10, "Golden Idol pays out on pickup")
	# Coin Purse before the box, so the box can't roll a second purse (held items are never offered).
	run.dev_give(_demo_content().items[&"demo.item.coin_purse"], 2)
	coins = run.state.coins
	run._run_hooks("on_room_cleared")
	eq(run.state.coins, coins + 1, "Coin Purse pays per cleared room")
	run.dev_give(_demo_content().items[&"demo.item.mystery_box"], 1)
	check(run.state.holder_of(&"demo.item.mystery_box") == 0, "the Mystery Box is gone once opened")
	var held: int = run.state.held_items().size()
	check(held >= 2, "and turned into another item (%d held)" % held)
	run.dev_give(_demo_content().items[&"demo.item.hearty_stew"], 1)
	run.state.party[0]["hp"] = 10000
	run._run_hooks("on_floor_start")
	check(int(run.state.party[0]["hp"]) > 10000, "Hearty Stew heals at floor start")
	run.free()


func test_demo_items_replay() -> void:
	if not _ready_to_test():
		return
	var snap := _snapshot(["demo.item.hunters_mark", "demo.item.frost_needle", "demo.item.thorn_mail"], "slime_pair",
		["demo.equipment.ember_pendant"])
	var battle := _battle(snap)
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "the demo battle runs: " + battle.runner_error)
	var request := {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
	var result: Dictionary = await ReplayRunner.new().run(request, CONTENT_ROOT, host)
	eq(result.get("verdict"), "Verified", "a battle with new items and armor replays (%s)" % result.get("mismatch"))
