## Spec playable-demo 6: the demo run "The Descent" on res://content/ (direction only, never tuned numbers, so your
## tuning can't fail it). Skipped when the run isn't built yet (game/tools/build_demo_run.tscn).
extends TestCase

const CONTENT: String = "res://content/"
const DESCENT: StringName = &"demo.run.descent"

var _demo_index: ContentIndex


func _demo() -> ContentIndex:
	if _demo_index == null:
		_demo_index = ContentIndex.new(CONTENT)
	return _demo_index if _demo_index.runs.has(DESCENT) else null


func _party(content: ContentIndex) -> Array:
	var ids: Array = []
	for id in content.characters:
		if content.characters[id].selectable:
			ids.append(String(id))
	ids.sort()
	return ids.slice(0, 2)


func _start(content: ContentIndex, seed_text: String = "1") -> RunController:
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_run(content, _party(content), seed_text), "", "a run of the default run starts")
	return run


func test_demo_run_two_floors() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	eq(RunController.pick_run(content)["run"].id, DESCENT, "The Descent is the default run")
	var structure: RunStructure = content.runs[DESCENT]
	eq(structure.floors.size(), 2, "two floors")
	eq(structure.floors[0].chapters.map(func(chapter): return chapter.id), [&"demo.chapter.cellar"], "floor 1 is the Cellar")
	eq(structure.floors[1].chapters.map(func(chapter): return chapter.id), [&"demo.chapter.crypt"], "floor 2 is the Crypt")
	var bosses := [{"room": &"demo.room.boss", "encounter": "demo.encounter.golem"},
		{"room": &"demo.room.sanctum", "encounter": "demo.encounter.lich"}]
	for seed_value in range(1, 21):
		for floor_index in 2:
			var result := SeedReport.floor_of(content, seed_value, floor_index)
			eq(result["error"], "", "seed %d floor %d generates" % [seed_value, floor_index + 1])
			if result["error"] != "":
				continue
			var map: FloorMap = result["map"]
			var kinds := {}
			for index in map.sorted_indices():
				var cell: Dictionary = map.cells[index]
				var room: RoomDefinition = content.rooms[cell["room"]]
				for tag in [&"Room.Type.Treasure", &"Room.Type.Shop"]:
					if room.tags.has(tag):
						kinds[tag] = true
				if cell["role"] == FloorMap.ROLE_BOSS:
					eq(cell["room"], bosses[floor_index]["room"], "seed %d floor %d boss room" % [seed_value, floor_index + 1])
					eq(String(cell["content"]["encounter"]), bosses[floor_index]["encounter"],
						"seed %d floor %d boss" % [seed_value, floor_index + 1])
			eq(kinds.size(), 2, "seed %d floor %d has a treasure room and a shop" % [seed_value, floor_index + 1])
	var cellar: Dictionary = SeedReport.many(content, 1, 30, 0)["encounters"]
	var crypt: Dictionary = SeedReport.many(content, 1, 30, 1)["encounters"]
	for id in crypt:
		check(content.encounters[StringName(id)].tags.has(&"Chapter.Crypt"), "the Crypt draws only Crypt encounters: " + id)
	for id in cellar:
		check(not content.encounters[StringName(id)].tags.has(&"Chapter.Crypt"), "the Cellar draws no Crypt encounter: " + id)
	for id in ["demo.encounter.crypt_guard", "demo.encounter.wisp_choir", "demo.encounter.ember_watch",
			"demo.encounter.bound_dead"]:
		check(crypt.has(id), "%s appears on the Crypt in 30 seeds" % id)


## The auto policy plays whole runs to an end (won or lost; never a runner error, a dead end or the step cap), and a
## run that beats the Golem takes the stairs.
func test_demo_run_completes() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var report := await PlayReport.many(content, host, 1, 10, {"check": true})
	eq(report["stopped"], 0, "every run ends")
	eq(report["violations"], [], "every battle replays Verified and breaks no invariant")
	for record in report["runs"]:
		check(record["status"] in [RunState.WON, RunState.LOST], "seed %d ends won or lost" % record["seed"])
		if record["status"] == RunState.WON:
			eq(record["floorReached"], 2, "seed %d: a won run cleared both floors" % record["seed"])


func test_demo_events() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	# Cursed chest: an item arrives and the party loses HP.
	var run := _start(content)
	var hp_before := _party_hp(run)
	var held_before := _held(run)
	_open(run, &"demo.event.cursed_chest")
	eq(run.choose(0), "", "open the chest")
	check(_held(run) > held_before, "the chest gives an item")
	check(_party_hp(run) < hp_before, "the chains take HP")
	run.free()
	# Wounded knight: paying needs 15 coins and gives the helm; challenging starts the duel.
	run = _start(content)
	_open(run, &"demo.event.wounded_knight")
	check(not run.choice_enabled(0), "paying needs 15 coins")
	run.add_coins(15)
	eq(run.choose(0), "", "pay")
	eq(run.state.coins, 0, "15 coins paid")
	check(run.state.armor.has(&"demo.equipment.warden_helm"), "the helm goes to the armor inventory (D9: never worn on its own)")
	eq(run.state.event.get("page"), 1, "the thank-you page")
	run.free()
	run = _start(content)
	_open(run, &"demo.event.wounded_knight")
	eq(run.choose(1), "", "challenge him")
	eq(run.pending_battle.get("encounter"), &"demo.encounter.knight_duel", "the duel starts")
	run.free()
	# Librarian: read, then take one of two books.
	run = _start(content)
	held_before = _held(run)
	_open(run, &"demo.event.librarian")
	eq(run.choose(0), "", "look at the books")
	eq(run.state.event.get("page"), 1, "the books page")
	eq(run.choose(1), "", "take the Hourglass")
	eq(_held(run), held_before + 1, "one book is taken")
	run.free()


func _open(run: RunController, event_id: StringName) -> void:
	run.state.event = {"cell": run.state.current_cell, "event": event_id, "page": 0}


func _held(run: RunController) -> int:
	var count := 0
	for member in run.state.party:
		count += member["items"].size() + member["use_slots"].size()
	return count


func _party_hp(run: RunController) -> int:
	var total := 0
	var stats := run.party_stats()
	for slot in stats:
		total += int(stats[slot].get(BattleUnit.HP, 0))
	return total


## Puts a battle against `encounter_id` in the run's current room (bypasses the map so the test picks the fight).
func _inject(run: RunController, encounter_id: StringName) -> void:
	var encounter: EncounterDefinition = run.content.encounters[encounter_id]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, run.state.floor_index)
	var enemies: Array = generator.resolve_enemies(encounter, null, false, null, RunSeeds.rng(1, "test"))
	run.state.map.cells[run.state.current_cell]["content"]["enemies"] = enemies
	run.pending_battle = {"cell": run.state.current_cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}


## Spec playable-demo 3.7: the Wisp choir drains Ice, Bound dead's first Toad lashes with Entangle (its row delay
## fires), and beating the wounded knight drops his helm into the armor inventory.
func test_demo_encounter_features() -> void:
	var content := _demo()
	if content == null:
		print("    skipped: %s not built" % DESCENT)
		return
	var run := _start(content)
	_inject(run, &"demo.encounter.wisp_choir")
	var battle := Battle.new()
	host.add_child(battle)
	eq(battle.setup(run.battle_snapshot(), content), "", "the Wisp choir builds")
	for unit in battle.units():
		if not unit.is_party():
			check(unit.asc.has_tag_exact(&"Drain.Ice"), "%s drains Ice (the encounter's grant)" % unit.unit_id)
	battle.free()
	_inject(run, &"demo.encounter.bound_dead")
	battle = Battle.new()
	host.add_child(battle)
	eq(battle.setup(run.battle_snapshot(), content), "", "Bound dead builds")
	var lasher := battle.unit_by_id(&"E1")
	check(lasher.ability_by_tag(&"Ability.Entanglelash") != null, "the first Toad has Entangle Lash")
	check(battle.unit_by_id(&"E3").ability_by_tag(&"Ability.Entanglelash") == null, "the other Toad does not")
	check(lasher.brain_override is PatternBrain, "and its slot's PatternBrain")
	var delays := [0]
	battle.action_delayed.connect(func(_unit, percent): if percent > 0: delays[0] += 1)
	# The party usually kills it first, so its turn is taken directly: the pattern opens with Entangle Lash.
	var action: Dictionary = await battle._take_action(lasher, ScriptedController.new())
	eq(action.get("ability"), &"Ability.Entanglelash", "its pattern opens with Entangle Lash")
	check(delays[0] > 0, "Entangle Lash's row delay pushes the target's turn back")
	battle.free()
	run.free()
	var duel := _start(content)
	_inject(duel, &"demo.encounter.knight_duel")
	await duel.fight(_KillFirst.new())
	check(duel.state.armor.has(&"demo.equipment.warden_helm"), "the duel's reward helm is in the armor inventory")
	duel.free()


class _KillFirst extends ScriptedController:
	var _done := false

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		if not _done:
			_done = true
			return {"dev": &"Dev.Kill", "effect": RunController.dev_effect("dev_kill"), "targets": "enemies"}
		return super(battle, unit)
