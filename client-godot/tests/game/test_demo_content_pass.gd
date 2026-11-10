## Content test for the content pass (spec content-pass 6): each new enemy, boss, item, armor piece and character kit
## does the thing it was made to cover (3.6), checked by direction only (a status lands, a hit is drained, a phase
## starts), never by the tuned number. Reads res://content/ and is skipped when the content isn't there.
extends TestCase

const DemoItems := preload("res://tests/game/test_demo_items.gd")
const DEMO: String = "res://content/demo/"
const CONTENT_ROOT: String = "res://content/"


func _ready_to_test() -> bool:
	if not ResourceLoader.exists(DEMO + "enemies/lich.tres"):
		print("    skipped: no content-pass content under ", DEMO)
		return false
	var probe: AttributeSet = DemoItems._demo_content().characters[&"demo.character.warrior"].attribute_set.new()
	if probe.get("debuff_turns") == null:
		print("    skipped: generate the Unit AttributeSet to add debuff_turns / resist_dmg")
		return false
	return true


func _battle(encounter: String, items: Array = [], gear: Array = [], use_slots: Array = []) -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup(DemoItems._snapshot(items, encounter, gear, use_slots), DemoItems._demo_content())
	check(error == "", "demo battle setup: " + error)
	return battle


func _act(battle: Battle, actor: StringName, ability: StringName, target: StringName) -> void:
	var unit := battle.unit_by_id(actor)
	await battle._activate(unit, unit.ability_by_tag(ability), battle.unit_by_id(target))
	battle._check_deaths()
	await battle._drain_triggers()


static func _apply(source: BattleUnit, target: BattleUnit, effect_name: String) -> void:
	target.asc.apply_gameplay_effect(load(DEMO + "effects/%s.tres" % effect_name), source.asc, 1)


static func _sturdy(unit: BattleUnit) -> void:
	unit.asc.initialize_attribute_overrides({"max_hp": 1000000.0, "hp": 1000000.0})


func test_status_enemies() -> void:
	if not _ready_to_test():
		return
	var court := _battle("fire_court", [], [], [{"itemId": "demo.item.fire_bomb", "ready": true}])
	var hits := []
	court.damage_dealt.connect(func(_s, target, _a, tags): hits.append([target, tags]))
	await _act(court, &"E1", &"Ability.Firebolt", &"P1")
	check(court.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Debuff.Burn"), "the Fire Imp's bolt burns")
	_sturdy(court.unit_by_id(&"E1"))
	await _act(court, &"P1", &"Ability.Item.Firebomb", &"E1")
	check(hits.any(func(hit): return hit[0] == &"E1" and hit[1].has(&"Hit.Resisted")), "the Fire Imp resists Fire")

	var bog := _battle("bog")
	var warrior := bog.unit_by_id(&"P1")
	_sturdy(warrior)
	await _act(bog, &"E1", &"Ability.Spit", &"P1")
	await _act(bog, &"E1", &"Ability.Spit", &"P1")
	var stacks: Array = warrior.statuses().filter(func(status): return status["tag"] == "Status.Debuff.Poison")
	check(not stacks.is_empty() and stacks[0]["stacks"] == 2, "the Bog Toad's poison stacks")
	await _act(bog, &"E2", &"Ability.Chill", &"P1")
	check(warrior.asc.has_tag_exact(&"Status.Debuff.Slow"), "the Frost Wisp's chill slows")
	var frozen := false
	for attempt in 12:
		await _act(bog, &"E2", &"Ability.Freezetouch", &"P1")
		frozen = frozen or warrior.asc.has_tag_exact(&"State.Controlled")
	check(frozen, "the Frost Wisp's touch freezes (a 50% roll, 12 tries)")
	check(not warrior.asc.can_activate_ability(warrior.ability_by_tag(&"Ability.Ult.Cleave")) or not frozen,
		"a frozen Warrior can't ult")

	var vanguard := _battle("vanguard")
	var knight := vanguard.unit_by_id(&"E1")
	_apply(vanguard.unit_by_id(&"P1"), knight, "freeze")
	check(not knight.asc.has_tag_exact(&"State.Controlled"), "the Knight is immune to control")
	await _act(vanguard, &"P1", &"Ability.Provoke", &"")
	check(vanguard.unit_by_id(&"P1").asc.has_tag_exact(&"State.Taunting"), "Provoke taunts")
	await _act(vanguard, &"E2", &"Ability.Dispel", &"")
	check(not vanguard.unit_by_id(&"P1").asc.has_tag(&"Status.Buff"), "the Shaman's dispel strips the party's buffs")
	await _act(vanguard, &"E2", &"Ability.Hex", &"P1")
	check(vanguard.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Debuff.Vulnerable"), "the Shaman's hex makes Vulnerable")
	await _act(vanguard, &"E2", &"Ability.Mend", &"E1")
	check(knight.asc.has_tag_exact(&"Status.Buff.Regen"), "the Shaman mends an ally")


func test_boss_phases() -> void:
	if not _ready_to_test():
		return
	var fight := _battle("lich")
	var lich := fight.unit_by_id(&"E1")
	var phases := []
	fight.phase_changed.connect(func(_unit, phase): phases.append(phase))
	lich.asc.initialize_attribute_overrides({"energy": 10000.0})
	var brain: TacticalBrain = lich.definition.brain
	eq(brain.choose_interrupt(lich, fight), {}, "the Lich holds its ult while healthy")
	check(lich.asc.can_activate_ability(lich.ability_by_tag(&"Ability.Bleedblast")), "phase 1: Bleed Blast")
	DemoItemsHurt.hurt(fight.unit_by_id(&"P1"), lich, lich.stat(BattleUnit.MAX_HP) * 55 / 100)  # to 45%
	fight._check_deaths()
	eq(phases, [1], "below 60%: phase 2")
	check(lich.asc.can_activate_ability(lich.ability_by_tag(&"Ability.Hexall")), "phase 2: Hex All")
	check(not lich.asc.can_activate_ability(lich.ability_by_tag(&"Ability.Bleedblast")), "and no more Bleed Blast")
	check(not brain.choose_interrupt(lich, fight).is_empty(), "below 50% the Lich casts its Death Ray")
	_apply(fight.unit_by_id(&"P1"), lich, "poison")
	DemoItemsHurt.hurt(fight.unit_by_id(&"P1"), lich, lich.stat(BattleUnit.MAX_HP) * 25 / 100)  # to 20%
	fight._check_deaths()
	eq(phases, [1, 2], "below 25%: phase 3")
	check(lich.asc.can_activate_ability(lich.ability_by_tag(&"Ability.Doom")), "phase 3: Doom")
	check(not lich.asc.has_tag(&"Status.Debuff"), "the last phase sheds its debuffs")

	var golem_fight := _battle("golem")
	var golem := golem_fight.unit_by_id(&"E1")
	var pattern: PatternBrain = golem.definition.brain
	var before := []
	for i in 3:
		before.append(String(pattern.choose(golem, golem_fight)["ability"]))
	eq(before[2], "Ability.Crush", "before phase 2 Rockfall can't activate, so the third step falls back to the first move")
	DemoItemsHurt.hurt(golem_fight.unit_by_id(&"P1"), golem, golem.stat(BattleUnit.MAX_HP) * 6 / 10)
	golem_fight._check_deaths()
	check(golem.asc.has_tag_exact(&"State.Phase.Two"), "below 50% the Golem enters phase 2")
	# Spec skill-points: the fourth step is Tremor, the Golem's secret skill; a level-1 Golem lacks it and falls back.
	var after := []
	for i in 4:
		after.append(String(pattern.choose(golem, golem_fight)["ability"]))
	eq(after, ["Ability.Crush", "Ability.Crush", "Ability.Bite", "Ability.Rockfall"],
		"then its pattern (Tremor falling back to Crush) reaches Rockfall")


func test_affinity_items() -> void:
	if not _ready_to_test():
		return
	var court := _battle("fire_court", ["demo.item.salamander_heart", "demo.item.siphon_sigil", "demo.item.frostguard_charm"])
	var warrior := court.unit_by_id(&"P1")
	warrior.asc.initialize_attribute_overrides({"hp": 50000.0})
	var drained := []
	court.damage_drained.connect(func(_s, target, amount, _tags): drained.append([target, amount]))
	var energy := warrior.stat(BattleUnit.ENERGY)
	await _act(court, &"E1", &"Ability.Firebolt", &"P1")
	check(not drained.is_empty() and drained[0][0] == &"P1", "Salamander Heart drains the Fire bolt")
	check(warrior.stat(BattleUnit.HP) > 50000, "which heals")
	check(warrior.stat(BattleUnit.ENERGY) > energy, "Siphon Sigil charges the ult on a drain")
	check(warrior.asc.has_tag_exact(&"Weakness.Ice") and warrior.asc.has_tag_exact(&"Resist.Ice"), "the implant and the charm")
	var bog := _battle("bog", ["demo.item.salamander_heart", "demo.item.frostguard_charm"])
	var hits := []
	bog.damage_dealt.connect(func(_s, target, _a, tags): hits.append([target, tags]))
	_sturdy(bog.unit_by_id(&"P1"))
	await _act(bog, &"E2", &"Ability.Chill", &"P1")
	check(hits.any(func(hit): return hit[0] == &"P1" and hit[1].has(&"Hit.Weakness") and not hit[1].has(&"Hit.Resisted")),
		"the implant's Ice weakness wins over Frostguard (Drain > Weak > Resist)")
	var leech := _battle("bog", ["demo.item.leech_hide"])
	var leeched := []
	leech.damage_drained.connect(func(_s, target, _a, _tags): leeched.append(target))
	await _act(leech, &"E1", &"Ability.Spit", &"P1")
	eq(leeched, [&"P1"], "Leech Hide drains Physical")
	var tactical := TacticalBrain.new()
	var imp := court.unit_by_id(&"E1")
	eq(tactical.target_pool(imp, court, imp.ability_by_tag(&"Ability.Firebolt")).map(func(unit): return unit.unit_id), [&"P2"],
		"the Fire Imp's brain stops aiming Fire at the drainer")


func test_status_items() -> void:
	if not _ready_to_test():
		return
	var items := ["demo.item.frost_lantern", "demo.item.serrated_edge", "demo.item.toxic_echo", "demo.item.overcharge_coil",
		"demo.item.interrupters_badge", "demo.item.shatterpoint", "demo.item.mirror_ward", "demo.item.last_rites",
		"demo.item.hexbreaker_charm", "demo.item.witchs_eye"]
	var battle := _battle("fire_court", items, [], [{"itemId": "demo.item.plague_flask", "ready": true}])
	var warrior := battle.unit_by_id(&"P1")
	var fired := DemoItems._fired(battle)
	eq(warrior.stat("debuff_turns"), 100, "Witch's Eye: +1 debuff turn")
	warrior.asc.send_gameplay_event(Battle.EVENT_BATTLE_START, {"source": warrior, "target": warrior})
	await battle._drain_triggers()
	check(warrior.asc.has_tag_exact(&"Immune.Control"), "Hexbreaker Charm: Ward at battle start")
	for unit_id in [&"E1", &"E2"]:
		_sturdy(battle.unit_by_id(unit_id))
	await _act(battle, &"P1", &"Ability.Item.Plague", &"")
	var poison: Array = battle.unit_by_id(&"E1").statuses().filter(func(status): return status["tag"] == "Status.Debuff.Poison")
	check(not poison.is_empty() and poison[0]["stacks"] == 2, "Plague Flask: 2 stacks on every enemy")
	var poison_turns: int = (load(DEMO + "effects/poison.tres") as GameplayEffect).duration_turns
	check(not poison.is_empty() and poison[0]["turns"] == poison_turns + 1, "Witch's Eye: the Poison lasts 1 more turn")
	# Spec skill-points: Ice Blast costs more SP than a level-1 Warrior's pool; this test is about the items, so top it up.
	warrior.asc.initialize_attribute_overrides({"max_mp": 10000.0, "mp": 10000.0})
	await _act(battle, &"P1", &"Ability.Iceblast", &"E1")  # Ice on an Imp: a weakness hit on a poisoned enemy
	check(fired.has(&"Ability.Passive.Frostlantern"), "Frost Lantern rolls on Ice damage")
	check(fired.has(&"Ability.Passive.Toxicecho"), "Toxic Echo follows up a weakness hit")
	check(fired.has(&"Ability.Passive.Shatterpoint") == battle.unit_by_id(&"E1").asc.has_tag_exact(Battle.BROKEN_TAG)
		or fired.has(&"Ability.Passive.Shatterpoint"), "Shatterpoint fires on an Ice break")
	warrior.asc.initialize_attribute_overrides({"crit_rate": 10000.0})
	await _act(battle, &"P1", &"Ability.Strike", &"E2")
	check(battle.unit_by_id(&"E2").asc.has_tag_exact(&"Status.Debuff.Bleed"), "Serrated Edge: a crit makes it Bleed")
	warrior.asc.initialize_attribute_overrides({"crit_rate": 0.0, "energy": 10000.0})
	await battle._interrupt(warrior, {"ability": &"Ability.Ult.Cleave", "target": &""}, ScriptedController.new())
	check(fired.has(&"Ability.Passive.Overcharge"), "Overcharge Coil refunds charge after an ult")
	check(fired.has(&"Ability.Passive.Interrupter") and warrior.asc.has_tag_exact(&"Status.Buff.AttackUp"),
		"Interrupter's Badge: ATK up after an out-of-turn ult")
	var long_shot := ExecutionRow.new()
	long_shot.effect = load(DEMO + "effects/burn.tres")
	long_shot.chance_x100 = 1  # 0.01%: this seed's roll misses
	battle._status_lands(battle.unit_by_id(&"E1"), warrior, long_shot)
	await battle._drain_triggers()
	check(fired.has(&"Ability.Passive.Mirrorward"), "Mirror Ward heals when a status against you misses")
	battle.unit_by_id(&"E2").asc.initialize_attribute_overrides({"hp": 100.0})
	await _act(battle, &"P1", &"Ability.Strike", &"E2")
	check(fired.has(&"Ability.Passive.Lastrites") and warrior.asc.has_tag_exact(&"Status.Buff.Regen"), "Last Rites: Regen on a kill")


func test_armor_and_bell() -> void:
	if not _ready_to_test():
		return
	var battle := _battle("bog", [], ["demo.equipment.warden_helm", "demo.equipment.thornbark_mail",
		"demo.equipment.tacticians_ring"], [{"itemId": "demo.item.purifying_bell", "ready": true}])
	var warrior := battle.unit_by_id(&"P1")
	_sturdy(warrior)
	warrior.asc.send_gameplay_event(Battle.EVENT_BATTLE_START, {"source": warrior, "target": warrior})
	await battle._drain_triggers()
	check(warrior.asc.has_tag_exact(&"State.Taunting"), "Tactician's Ring taunts at battle start")
	for attempt in 6:
		await _act(battle, &"E2", &"Ability.Freezetouch", &"P1")
	check(not warrior.asc.has_tag_exact(&"State.Controlled"), "Warden Helm: never frozen")
	check(battle.unit_by_id(&"E2").asc.has_tag_exact(&"Status.Debuff.Poison"), "Thornbark Mail poisons the attacker")
	await _act(battle, &"E1", &"Ability.Spit", &"P1")
	await _act(battle, &"P1", &"Ability.Item.Bell", &"")
	check(not warrior.asc.has_tag(&"Status.Debuff"), "Purifying Bell cleanses the party")


func test_character_kits_and_break_effects() -> void:
	if not _ready_to_test():
		return
	var battle := _battle("slime_pair", [], [], [{"itemId": "demo.item.fire_bomb", "ready": true}])
	var fired := DemoItems._fired(battle)
	await _act(battle, &"P1", &"Ability.Provoke", &"")
	check(battle.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Buff.Taunt") and battle.unit_by_id(&"P1").asc.has_tag_exact(&"Status.Buff.DefenseUp"),
		"the Warrior's Provoke: Taunt and Defense Up")
	var slime := battle.unit_by_id(&"E1")
	_sturdy(slime)
	await _act(battle, &"P1", &"Ability.Item.Firebomb", &"E1")
	check(slime.asc.has_tag_exact(Battle.BROKEN_TAG), "Fire breaks a Slime")
	check(fired.has(&"Ability.Passive.Break.Fire"), "the Fire break effect fires for the breaker")
	check(not fired.has(&"Ability.Passive.Break.Ice"), "and only that one")
	check(slime.asc.has_tag_exact(&"Status.Debuff.Burn"), "it burns the broken Slime")
	var cleric := battle.unit_by_id(&"P2")
	_apply(slime, cleric, "poison")
	await _act(battle, &"P2", &"Ability.Purify", &"")
	check(not cleric.asc.has_tag(&"Status.Debuff") and cleric.asc.has_tag_exact(&"Status.Buff.Regen"), "the Cleric's Purify: cleanse and Regen")


## A recorded fight against the Lich (statuses, phases, ults locked by control) replays Verified on the demo content.
func test_demo_content_pass_replay() -> void:
	if not _ready_to_test():
		return
	var snap := DemoItems._snapshot(["demo.item.salamander_heart", "demo.item.plague_flask"], "lich")
	snap["battleId"] = "demo-lich"
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	check(battle.setup(snap, DemoItems._demo_content()) == "", "setup")
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "no runner error: " + battle.runner_error)
	var request := {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
	var result: Dictionary = await ReplayRunner.new().run(copy(request), CONTENT_ROOT, host)
	eq(result.get("verdict"), "Verified", "the Lich fight replays: %s" % result)


## Lowers a unit's HP through an instant GAS effect (the boss phase checks read it).
class DemoItemsHurt:
	static func hurt(source: BattleUnit, unit: BattleUnit, amount: int) -> void:
		preload("res://tests/combat/test_bosses.gd").hurt(source, unit, amount)
