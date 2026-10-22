## Content test for the demo ults (spec ult-interrupts 3.3): Cleave and Execute (Warrior), Sanctuary and Resurrection
## (Cleric), Quake (Golem) are ults cast out of turn, and a demo battle full of them replays. Checked by direction only
## (a unit dies, HP goes up or down), never by the tuned number. Skipped when the demo ults aren't there.
extends TestCase

const DEMO: String = "res://content/demo/"
const CONTENT_ROOT: String = "res://content/"
const EXECUTE: StringName = &"Ability.Ult.Execute"
const CLEAVE: StringName = &"Ability.Ult.Cleave"
const SANCTUARY: StringName = &"Ability.Ult.Sanctuary"
const RESURRECTION: StringName = &"Ability.Ult.Resurrection"
const QUAKE: StringName = &"Ability.Ult.Quake"

static var _demo: ContentIndex


static func _demo_content() -> ContentIndex:
	if _demo == null:
		_demo = ContentIndex.new(CONTENT_ROOT)
	return _demo


func _ready_to_test() -> bool:
	if not ResourceLoader.exists(DEMO + "abilities/execute.tscn"):
		print("    skipped: no demo ults under ", DEMO)
		return false
	return true


## Warrior (P1) and Cleric (P2), both with a full ult charge, against `encounter`.
static func _snapshot(encounter: String) -> Dictionary:
	return {
		"schemaVersion": 2, "battleId": "demo-ults", "seed": "5", "encounterId": "demo.encounter." + encounter,
		"party": [
			{"slot": 1, "unitDefId": "demo.character.warrior", "level": 1, "skills": [], "equipmentIds": [],
				"items": [], "useSlots": [], "energy": 10000},
			{"slot": 2, "unitDefId": "demo.character.cleric", "level": 1, "skills": [], "equipmentIds": [], "items": [],
				"useSlots": [], "energy": 10000},
		],
	}


func _battle(snap: Dictionary) -> Battle:
	var battle := Battle.new()
	host.add_child(battle)
	_battles.append(battle)
	var error := battle.setup(snap, _demo_content())
	check(error == "", "demo battle setup: " + error)
	return battle


static func _set_stat(unit: BattleUnit, attribute_name: String, value: float) -> void:
	var values: Dictionary[String, float] = {attribute_name: value}
	unit.asc.initialize_attribute_overrides(values)


static func _tags(abilities: Array[BattleAbility]) -> Array:
	return abilities.map(func(ability: BattleAbility): return ability.ability_tag)


func test_demo_ults_are_ults() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(_snapshot("golem"))
	var warrior := battle.unit_by_id(&"P1")
	var cleric := battle.unit_by_id(&"P2")
	eq(_tags(warrior.ultimate_abilities()), [CLEAVE, EXECUTE], "the Warrior's ults")
	eq(_tags(cleric.ultimate_abilities()), [SANCTUARY, RESURRECTION], "the Cleric's ults")
	eq(_tags(battle.unit_by_id(&"E1").ultimate_abilities()), [QUAKE], "the Golem's ult")
	for unit in [warrior, cleric, battle.unit_by_id(&"E1")]:
		check(unit.action_abilities().all(func(ability: BattleAbility) -> bool: return not ability.is_ultimate()),
			"%s can't take an ult as a turn action" % unit.unit_id)


## Execute kills a bat before any bat moves; a later Execute aimed at that dead bat is retargeted to a neighbour.
func test_execute_interrupt_and_retarget() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(_snapshot("bat_swarm"))
	var recorder := ActionRecorder.new()
	var first_turn := []
	battle.turn_started.connect(func(unit_id, _turn):
		if first_turn.is_empty():
			first_turn.append(unit_id))
	recorder.action_requested.connect(func(unit_id, _turn):
		var unit := battle.unit_by_id(unit_id)
		var targets := battle.target_candidates(unit, unit.ability_by_tag(&"Ability.Strike"))
		if recorder.waiting_for == unit_id and not targets.is_empty():
			recorder.submit_action(&"Ability.Strike", targets[0].unit_id))
	recorder.submit_ult(&"P1", EXECUTE, &"E2")
	await battle.run(recorder)
	check(battle.runner_error == "", "the battle runs: " + battle.runner_error)
	var first: Dictionary = recorder.entries[0]
	eq([first["actor"], first["ability"], first["target"], first.get("interrupt")], ["P1", String(EXECUTE), "E2", true],
		"Execute fires before the first turn")
	check(first_turn.is_empty() or first_turn[0] != &"E2", "the executed bat never takes its turn")
	var request := {"snapshot": _snapshot("bat_swarm"), "actionLog": recorder.action_log(battle)}
	var result: Dictionary = await ReplayRunner.new().run(request, CONTENT_ROOT, host)
	eq(result.get("verdict"), "Verified", "an Execute interrupt replays (%s)" % result.get("mismatch"))

	var fresh := _battle(_snapshot("bat_swarm"))
	_set_stat(fresh.unit_by_id(&"E2"), BattleUnit.HP, 0.0)
	fresh._check_deaths()
	eq(fresh.resolve_press({"unit": &"P1", "ability": EXECUTE, "target": &"E2"}).get("choice", {}).get("target"), &"E1",
		"an Execute aimed at a dead bat goes to the nearest one (the lower slot on a tie)")


## Resurrection brings back a fallen ally; once nobody is down, a queued one has no target left. Sanctuary heals.
func test_cleric_ults() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(_snapshot("golem"))
	var recorder := ActionRecorder.new()
	var warrior := battle.unit_by_id(&"P1")
	var cleric := battle.unit_by_id(&"P2")
	_set_stat(warrior, BattleUnit.HP, 0.0)
	battle._check_deaths()
	recorder.submit_ult(&"P2", RESURRECTION, &"P1")
	await battle._interrupt(cleric, recorder.interrupt(battle), recorder)
	check(warrior.alive and warrior.stat(BattleUnit.HP) > 0, "Resurrection revives the Warrior")
	eq(battle.resolve_press({"unit": &"P2", "ability": RESURRECTION, "target": &"P1"}).get("problem", [""])[0],
		"InvalidTarget", "with nobody down, Resurrection has no target")

	_set_stat(cleric, BattleUnit.ENERGY, 10000.0)
	var hp_before := warrior.stat(BattleUnit.HP)
	recorder.submit_ult(&"P2", SANCTUARY)
	await battle._interrupt(cleric, recorder.interrupt(battle), recorder)
	check(warrior.stat(BattleUnit.HP) > hp_before, "Sanctuary heals the party")
	eq(recorder.entries.map(func(entry): return entry.get("interrupt")), [true, true], "both logged as interrupts")


## The Golem charges when hit and, full, quakes at the next ult window (an enemy interrupt, never logged).
func test_golem_quake() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(_snapshot("golem"))
	var golem := battle.unit_by_id(&"E1")
	var warrior := battle.unit_by_id(&"P1")
	var charge := golem.stat(BattleUnit.ENERGY)
	await battle._activate(warrior, warrior.ability_by_tag(&"Ability.Strike"), golem)
	await battle._drain_triggers()
	check(golem.stat(BattleUnit.ENERGY) > charge, "being hit charges the Golem's ult")
	_set_stat(golem, BattleUnit.ENERGY, 10000.0)
	var quaked := []
	battle.interrupt_started.connect(func(unit_id, ability): quaked.append([unit_id, ability]))
	var hp_before := warrior.stat(BattleUnit.HP)
	var recorder := ActionRecorder.new()
	await battle._ult_window(recorder)
	eq(quaked, [[&"E1", QUAKE]], "a full Golem quakes at the ult window")
	check(warrior.stat(BattleUnit.HP) < hp_before, "Quake hits the party")
	eq(recorder.entries.size(), 0, "an enemy interrupt is not logged")


## A whole boss fight with the scripted policy (ults at both windows; the Golem answers) replays.
func test_demo_ults_replay() -> void:
	if not _ready_to_test():
		return
	var battle := _battle(_snapshot("golem"))
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "the demo battle runs: " + battle.runner_error)
	check(controller.entries.any(func(entry) -> bool: return entry.get("interrupt", false)), "the party ulted out of turn")
	var request := {"snapshot": _snapshot("golem"), "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}
	var result: Dictionary = await ReplayRunner.new().run(request, CONTENT_ROOT, host)
	eq(result.get("verdict"), "Verified", "a demo battle full of ults replays (%s)" % result.get("mismatch"))
