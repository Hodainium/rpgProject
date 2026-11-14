## Spec playable-demo 3.11: XP from won battles and level-ups (D28), class growth in battle, GainXp and GainLevel, the
## rest stop between floors (D29) and Castlevania-style drops (D31). Fixtures only; changed content in memory.
extends TestCase

const BattleV2 := preload("res://tests/combat/test_battle_v2.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]

var _runs: Array[RunController] = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


## A test controller: one dev decision (kill a side) first, then the scripted policy.
class KillFirst extends ScriptedController:
	var _done := false

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		if not _done:
			_done = true
			return {"dev": &"Dev.Kill", "effect": RunController.dev_effect("dev_kill"), "targets": "enemies"}
		return super(battle, unit)


static func _leveled_run(rest: EventDefinition = null) -> RunStructure:
	var base: RunStructure = fixtures().runs.values()[0]
	var run: RunStructure = base.duplicate()
	run.xp_per_enemy = 30
	run.xp_per_boss = 100
	var curve: Array[int] = [50, 120, 400]
	run.xp_to_level = curve
	run.rest_event = rest
	return run


func _start(content: ContentIndex) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	eq(run.start_run(content, PARTY, "7"), "", "the run starts")
	return run


## Puts a battle against the fixture pack in the current room.
func _inject(run: RunController, encounter_id: StringName = &"fixture.encounter.pack") -> void:
	var encounter: EncounterDefinition = run.content.encounters[encounter_id]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, run.state.floor_index)
	var enemies: Array = generator.resolve_enemies(encounter, null, true, null, RunSeeds.rng(1, "test"))
	run.state.map.cells[run.state.current_cell]["content"]["enemies"] = enemies
	run.pending_battle = {"cell": run.state.current_cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}


func test_xp_and_levels() -> void:
	var structure := _leveled_run()
	var run := _start(fixtures().overlay([structure]))
	_inject(run)
	await run.fight(KillFirst.new())
	eq(run.state.status, RunState.ACTIVE, "the battle is won")
	for member in run.state.party:
		eq(member["xp"], 60, "two enemies × 30 XP")
		eq(member["level"], 2, "60 XP reaches level 2 (50)")
	check("\n".join(run.state.canonical_lines()).contains("|xp=60"), "XP is part of the run hash")
	run.gain_xp(100, null)
	eq(run.state.member(1)["level"], 3, "160 XP: level 3 (120); not 4 (400)")
	run.gain_levels(1, fixtures().characters[&"fixture.character.medic"])
	eq(run.state.member(2)["level"], 4, "a free level for the medic only")
	eq(run.state.member(2)["xp"], 400, "its XP rises to the new level's start")
	eq(run.state.member(1)["level"], 3, "the knight keeps its level")
	var plain := _start(fixtures())
	_inject(plain)
	await plain.fight(KillFirst.new())
	eq(plain.state.member(1)["xp"], 0, "a run without a curve gains no XP")
	check(not "\n".join(plain.state.canonical_lines()).contains("xp="), "and its hash has no XP")


func test_level_effect_in_battle() -> void:
	var knight: CharacterDefinition = fixtures().characters[&"fixture.character.knight"].duplicate()
	# A saved effect (the state hash only accepts .tres effects): the fixture Whetstone, +20% ATK, FREE stacking.
	knight.level_effect = load("res://tests/fixtures/effects/whetstone.tres")
	var content := fixtures().overlay([knight])
	var atk := []
	for level in [1, 3]:
		var snap: Dictionary = BattleV2.v2_snapshot("7")
		snap["party"][0]["level"] = level
		var battle := Battle.new()
		host.add_child(battle)
		eq(battle.setup(snap, content), "", "builds at level %d" % level)
		atk.append(battle.unit_by_id(&"P1").stat("atk"))
		battle.free()
	check(atk[1] > atk[0], "level 3 has more ATK than level 1 (%d > %d)" % [atk[1], atk[0]])
	var snap3: Dictionary = BattleV2.v2_snapshot("7")
	snap3["party"][0]["level"] = 3
	var battle3 := Battle.new()
	host.add_child(battle3)
	battle3.setup(snap3, content)
	var controller := ScriptedController.new()
	await battle3.run(controller)
	var request3 := {"snapshot": snap3, "actionLog": ActionRecorder.build_log(controller.entries, battle3.outcome, battle3.final_hash)}
	battle3.queue_free()
	var verified: Dictionary = await ReplayRunner.new().run_on(JSON.parse_string(WireJson.stringify(request3)), content, host)
	eq(verified.get("verdict"), "Verified", "growth is rebuilt from the snapshot's level on replay: %s" % verified)


func test_rest_stop_between_floors() -> void:
	var rest := EventDefinition.new()
	rest.id = &"fixture.event.rest"
	var page := EventPage.new()
	page.text = "A quiet stop."
	var level_up := GainLevel.new()
	var rest_choice := EventChoice.new()
	rest_choice.label = "Train"
	rest_choice.outcomes.assign([level_up])
	var leave := EventChoice.new()
	leave.label = "Move on"
	page.choices.assign([rest_choice, leave])
	rest.pages.assign([page])
	var structure := _leveled_run(rest)
	var run := _start(fixtures().overlay([rest, structure]))
	run.state.boss_cleared = true
	eq(run.next_floor(), "", "the stairs")
	eq(run.state.floor_index, 0, "the rest stop comes before the next floor")
	eq(run.state.event.get("event"), &"fixture.event.rest", "the rest event is open")
	eq(run.state.event.get("cell"), -1, "off the map")
	check(not run.can_enter(run.state.map.sorted_indices()[0]), "the map waits")
	var logged := run.run_log.size()
	check(run.next_floor() != "", "the stairs are closed while the rest stop is open")
	eq(run.run_log.size(), logged, "and nothing more is logged")
	eq(run.choose(0), "", "train")
	eq(run.state.floor_index, 1, "the next floor starts when the rest stop ends")
	eq(run.state.member(1)["level"], 2, "the training level is kept")
	eq(run.state.event, {}, "no event left open")
	var types := run.run_log.map(func(entry) -> String: return entry["type"])
	check(types.find("next_floor") < types.rfind("choose"), "logged: next_floor, then the rest choice")


func test_enemy_drops() -> void:
	var food: ItemDefinition = fixtures().items.values().filter(func(item) -> bool: return not item.is_usable())[0]
	var grunt: EnemyDefinition = fixtures().units[&"fixture.enemy.grunt"].duplicate()
	grunt.drop_item = food
	grunt.drop_chance_x100 = Fixed.from_typed(100)
	var run := _start(fixtures().overlay([grunt]))
	_inject(run)
	await run.fight(KillFirst.new())
	# Spec food-items Q2: every drop waits for the player's choice (give_to), in roll order.
	eq(run.state.pending_gifts.count(food.id), 2, "both grunts drop at 100%, waiting for their holder")
	for gift in run.state.pending_gifts.duplicate():
		eq(run.give_to(run.state.party[0]["slot"]), "", "give_to")
	var held := 0
	for member in run.state.party:
		held += member["items"].count(food.id)
	eq(held, 2, "both drops are held once given")
	grunt.drop_chance_x100 = 0
	var none := _start(fixtures().overlay([grunt]))
	_inject(none)
	await none.fight(KillFirst.new())
	held = 0
	for member in none.state.party:
		held += member["items"].count(food.id)
	eq(held, 0, "no drop at 0%")
	check(none.state.pending_gifts.is_empty(), "and nothing waits")
