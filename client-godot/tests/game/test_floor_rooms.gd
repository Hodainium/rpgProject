## Spec floor-rooms 8.1: challenge rooms (waves, nothing until the last wave, the room's one roll), the armory (equipment only,
## locked like the shop), item rooms with items only, the pedestal filter, resume between waves, the offer sources, the
## bots, step verification and its tampering, and the validator. Fixtures only: the run is built in memory (FloorRoomsWorld).
extends TestCase

const StepRunnerTest := preload("res://tests/game/test_step_runner.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const WHETSTONE: StringName = &"fixture.item.whetstone"

var _runs: Array[RunController] = []
var _helpers: Array[TestCase] = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	for helper in _helpers:
		helper.after_each()
	_helpers.clear()
	super()


func _run(seed_text: String = "7", tweak: Callable = Callable()) -> RunController:
	var run := FloorRoomsWorld.start(host, seed_text, tweak)
	_runs.append(run)
	return run


## Enters `index` from wherever the party is (marks a neighbour visited so the Isaac adjacency rule allows it).
func _go(run: RunController, index: int) -> String:
	run.state.map.cells[run.state.map.neighbours(index)[0]]["visited"] = true
	return run.enter_room(index)


func _fight(run: RunController) -> String:
	return await run.fight(ScriptedController.new())


func _xp(run: RunController) -> Array:
	return run.state.party.map(func(member: Dictionary) -> int: return int(member["xp"]))


func _holds(run: RunController, item_id: StringName) -> bool:
	return run.state.party.any(func(member: Dictionary) -> bool: return member["items"].has(item_id))


# --- Generation ---------------------------------------------------------------------------------------------------------

func test_every_floor_of_the_rules_places_one_challenge_room_and_one_armory() -> void:
	var content := FloorRoomsWorld.content()
	var chapter: ChapterDefinition = content.chapters[&"fixture.chapter.floor_rooms"]
	var plain: ChapterDefinition = content.chapters[&"fixture.chapter.a"]
	for seed_value in range(1, 61):
		var generator := FloorGenerator.new(content, content.runs[FloorRoomsWorld.RUN_ID], seed_value, 0)
		var built := generator.generate(chapter, false, {"party": [], "held": [], "seen": []})
		eq(built["error"], "", "seed %d generates" % seed_value)
		if built["error"] != "":
			continue
		var tags: Array = built["map"].cells.values().map(func(data: Dictionary) -> StringName: return data["special_tag"])
		eq(tags.count(FloorRoomsWorld.CHALLENGE_TAG), 1, "seed %d: one challenge room" % seed_value)
		eq(tags.count(FloorRoomsWorld.ARMORY_TAG), 1, "seed %d: one armory" % seed_value)
		var other := FloorGenerator.new(content, content.runs[&"fixture.run.two_floors"], seed_value, 0)
		var old := other.generate(plain, false, {"party": [], "held": [], "seen": []})
		var old_tags: Array = old["map"].cells.values().map(func(data: Dictionary) -> StringName: return data["special_tag"])
		check(not old_tags.has(FloorRoomsWorld.CHALLENGE_TAG) and not old_tags.has(FloorRoomsWorld.ARMORY_TAG),
			"seed %d: rules that list neither place neither" % seed_value)


func test_waves_resolve_in_order_without_repeating_an_encounter() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	var room_content: Dictionary = run.state.map.cells[cell]["content"]
	eq(room_content["kind"], "waves", "a challenge cell holds waves")
	var waves: Array = room_content["waves"]
	eq(waves.size(), 3, "three waves")
	eq(waves[0]["encounter"], &"fixture.encounter.loot_pack", "wave 1 is the fixed encounter")
	eq(room_content["encounter"], waves[0]["encounter"], "the content's encounter is wave 1's")
	var ids: Array = waves.map(func(wave: Dictionary) -> String: return String(wave["encounter"]))
	ids.sort()
	eq(ids, ["fixture.encounter.lone", "fixture.encounter.loot_pack", "fixture.encounter.pack"],
		"waves 2 and 3 are chapter A's two encounters, never the same one twice")
	for wave in waves:
		check(not wave["enemies"].is_empty(), "every wave has its enemies resolved")


func test_a_query_with_one_encounter_repeats_it() -> void:
	var only_pack := GameplayTagQuery.new()
	only_pack.require_all_tags.assign([&"Fixture.Chapter.A", &"Fixture.Chapter.B"])
	only_pack.ignore_tags.assign([&"Fixture.Encounter.Boss"])
	var run := _run("7", func(parts: Dictionary) -> void:
		for wave in parts["challenge"].waves:
			wave.encounter = null
			wave.content_query = only_pack)
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	var ids: Array = run.state.map.cells[cell]["content"]["waves"].map(func(wave: Dictionary) -> StringName:
		return wave["encounter"])
	eq(ids, [&"fixture.encounter.pack", &"fixture.encounter.pack", &"fixture.encounter.pack"], "the one candidate, three times")


# --- Playing a challenge ------------------------------------------------------------------------------------------------

func test_entering_starts_the_waves_and_only_the_last_one_gives_anything() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	check(not run.room_locked(cell), "the challenge room is never locked")
	eq(_go(run, cell), "", "entering is allowed")
	eq(run.pending_battle.get("label"), "/w1", "entering starts wave 1 at once")
	check(str(run.battle_snapshot()["battleId"]).ends_with("/c%d/w1" % cell), "wave 1's battle id")
	check(run.next_floor() != "", "nothing else while a wave waits")
	var coins := run.state.coins
	var keys := run.state.keys
	var xp := _xp(run)
	for wave in [2, 3]:
		eq(await _fight(run), "", "wave %d's battle plays" % (wave - 1))
		eq(run.state.status, RunState.ACTIVE, "the party survives wave %d" % (wave - 1))
		eq(run.pending_battle.get("label"), "/w%d" % wave, "wave %d starts inside the same action" % wave)
		eq(run.state.coins, coins, "no coins after wave %d (not even the encounter's reward)" % (wave - 1))
		eq(run.state.keys, keys, "no key after wave %d" % (wave - 1))
		eq(_xp(run), xp, "no XP after wave %d" % (wave - 1))
		check(run.state.pending_gifts.is_empty() and not _holds(run, WHETSTONE), "no drop after wave %d" % (wave - 1))
		check(not run.state.map.cells[cell]["cleared"], "the room is not cleared yet")
	eq(run.state.map.cells[cell]["wave"], 2, "the cell knows the wave it reached")
	# What one cleared battle room rolls, on the room's own stream, over every wave's enemies.
	var expected := coins
	var scaling: ScalingRules = run.chapter().scaling
	var drop_rng := run.state.seeds().floor_rng(run.state.floor_index, "drop/%d" % cell)
	if RunSeeds.roll(drop_rng, scaling.coin_drop_chance_x100):
		expected += drop_rng.randi_range(mini(scaling.coin_drop_min, scaling.coin_drop_max), scaling.coin_drop_max)
	for enemy in RunController.room_enemies(run.state.map.cells[cell]):
		if enemy["variantId"] != null:
			expected += run.content.variants[StringName(str(enemy["variantId"]))].coin_bonus
	eq(await _fight(run), "", "the last wave plays")
	check(run.pending_battle.is_empty(), "no fourth wave")
	check(run.state.map.cells[cell]["cleared"], "the last wave clears the room")
	eq(run.state.coins, expected, "the room's coin roll once, as one room (no encounter reward)")
	eq(run.state.keys, keys + 1, "one key roll for the room, not one per wave")
	var after := _xp(run)
	for index in after.size():
		check(after[index] > xp[index] or not run.state.party[index]["alive"], "XP arrives after the last wave (slot %d)" % index)
	check(run.state.pending_gifts.is_empty() and not _holds(run, WHETSTONE), "no enemy ever drops in a challenge room")
	check(not run.state.map.cells[cell]["pickups"].is_empty(), "the reward pedestal is there")
	var summary := run.run_summary()
	eq(summary.get("challengesEntered"), 1, "the summary counts the challenge entered")
	eq(summary.get("challengesCleared"), 1, "and cleared")
	var battles: Array = run.run_log.filter(func(entry: Dictionary) -> bool: return entry["type"] == "battle")
	eq(battles.map(func(entry: Dictionary) -> String: return str(entry["battleId"]).get_slice("/c", 1)),
		["%d/w1" % cell, "%d/w2" % cell, "%d/w3" % cell], "three logged battles, one per wave")
	eq(RunWire.offers(run.state, cell)[0]["source"], "Challenge", "the reward uploads as a Challenge offer")


func test_a_snapshot_between_waves_resumes_the_next_wave() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	_go(run, cell)
	await _fight(run)
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var resumed := RunController.new()
	host.add_child(resumed)
	_runs.append(resumed)
	eq(resumed.load_snapshot(run.content, saved), "", "the snapshot between waves loads")
	eq(resumed.state.run_hash(), run.state.run_hash(), "to the same hash")
	eq(resumed.pending_battle.get("label"), "/w2", "with wave 2 pending")
	eq(resumed.state.map.cells[cell]["wave"], 1, "and the wave reached")
	for played in [run, resumed]:
		await _fight(played)
		await _fight(played)
	eq(resumed.state.run_hash(), run.state.run_hash(), "both finish the challenge the same way")
	check(resumed.state.map.cells[cell]["cleared"], "the resumed run clears the room")
	# The wave index and the waves are hashed.
	var skipped: Dictionary = saved.duplicate(true)
	var probe := RunController.new()
	host.add_child(probe)
	_runs.append(probe)
	for entry in skipped["map"]["cells"]:
		if int(entry["index"]) == cell:
			entry["wave"] = 2
	eq(probe.load_snapshot(run.content, skipped), "", "a snapshot at another wave loads")
	check(probe.state.run_hash() != run.state.run_hash(), "the wave index is in the run hash")
	for entry in skipped["map"]["cells"]:
		if int(entry["index"]) == cell:
			entry["wave"] = 7
	check(RunSnapshot.shape_problem(skipped) != "", "a wave outside the room's waves is refused as malformed")


func test_a_fixed_later_wave_counts_as_picked_for_an_earlier_query() -> void:
	var only_a := GameplayTagQuery.new()
	only_a.require_all_tags.assign([&"Fixture.Chapter.A"])
	only_a.ignore_tags.assign([&"Fixture.Encounter.Boss"])
	for seed_value in range(1, 21):
		var run := _run(str(seed_value), func(parts: Dictionary) -> void:
			var first := RoomWave.new()
			first.content_query = only_a
			var fixed := RoomWave.new()
			fixed.encounter = TestCase.fixtures().encounters[&"fixture.encounter.lone"]
			var waves: Array[RoomWave] = [first, fixed]
			parts["challenge"].waves = waves)
		var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
		eq(run.state.map.cells[cell]["content"]["waves"][0]["encounter"], &"fixture.encounter.pack",
			"seed %d: the query wave avoids the later fixed wave's encounter" % seed_value)
		_runs.erase(run)
		run.free()


func test_a_waves_cell_without_waves_is_malformed() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	for entry in saved["map"]["cells"]:
		if int(entry["index"]) == cell:
			entry["content"].erase("waves")
	check(RunSnapshot.shape_problem(saved) != "", "a cell of kind waves with no waves is refused, never a script error")


func test_a_weightless_fresh_encounter_lets_a_wave_repeat() -> void:
	var run := _run("7", func(parts: Dictionary) -> void:
		var lone: EncounterDefinition = TestCase.fixtures().encounters[&"fixture.encounter.lone"].duplicate()
		lone.weight_x100 = 0  # kept for events only
		var only_a := GameplayTagQuery.new()
		only_a.require_all_tags.assign([&"Fixture.Chapter.A"])
		only_a.ignore_tags.assign([&"Fixture.Encounter.Boss"])
		parts["lone"] = lone
		for wave in parts["challenge"].waves:
			wave.encounter = null
			wave.content_query = only_a)
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	eq(run.runner_error, "", "the floor generates")
	var ids: Array = run.state.map.cells[cell]["content"]["waves"].map(func(wave: Dictionary) -> StringName:
		return wave["encounter"])
	check(not ids.has(&"fixture.encounter.lone"), "the weight-0 encounter is never picked (%s)" % [ids])


func test_a_battle_in_a_cleared_challenge_room_is_not_a_wave() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	_go(run, cell)
	for wave in 3:
		await _fight(run)
	var cleared := int(run.run_summary().get("challengesCleared", 0))
	check(not run.is_wave(cell, "x/f0/c%d/w3" % cell), "after the last wave no battle there is a wave")
	eq(run.dev_spawn(TestCase.fixtures().encounters[&"fixture.encounter.lone"]), "", "a dev battle spawns there")
	await _fight(run)
	eq(int(run.run_summary().get("challengesCleared", 0)), cleared, "the room is not cleared a second time")


func test_only_one_fight_runs_at_a_time() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	_go(run, cell)
	var running := Battle.new()  # stands in for wave 1 still on screen when a chained wave or a rebuild asks again
	run.current_battle = running
	eq(await run.fight(ScriptedController.new()), "a battle is already being fought", "a second fight is refused")
	eq(run.pending_battle.get("label"), "/w1", "and the pending wave is untouched")
	run.current_battle = null
	running.free()
	eq(await _fight(run), "", "once it is over the wave plays")


func test_a_run_lost_in_a_challenge_names_its_wave() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.CHALLENGE_TAG)
	_go(run, cell)
	await _fight(run)
	check(not run.run_summary()["endedIn"].has("wave"), "no wave while the run is still on")
	run.state.status = RunState.LOST  # the summary only reads the status: stands in for a party beaten in wave 2
	eq(run.run_summary()["endedIn"].get("wave"), 2, "a run lost in a challenge names the wave it fell in")
	run.state.map.cells[cell]["cleared"] = true
	check(not run.run_summary()["endedIn"].has("wave"), "a loss in a cleared challenge room names no wave")


# --- Armory, item rooms, the pedestal filter ------------------------------------------------------------------------------

func test_the_armory_is_locked_like_the_shop_and_offers_equipment_only() -> void:
	var run := _run()
	var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.ARMORY_TAG)
	check(run.room_locked(cell), "the armory is locked like the shop and the item room")
	eq(_go(run, cell), "Locked: you need a key", "no key, no entry")
	run.dev_keys(1)
	eq(_go(run, cell), "", "a key opens it")
	var pickups: Array = run.state.map.cells[cell]["pickups"]
	eq(pickups.size(), 1, "one pedestal")
	eq(pickups[0].get("kind"), FloorGenerator.EQUIPMENT_KIND, "it offers a piece of equipment")
	eq(RunWire.offers(run.state, cell)[0]["source"], "Armory", "uploaded as an Armory offer")
	eq(run.run_summary().get("armoriesVisited"), 1, "the summary counts the armory")


func test_the_pedestal_filter() -> void:
	var content := FloorRoomsWorld.content()
	var structure: RunStructure = content.runs[FloorRoomsWorld.RUN_ID]
	var anything := GameplayTagQuery.new()
	var O := RoomPlacement.Offers
	var kinds := {"items": 0, "equipment": 0}
	for seed_value in range(1, 41):
		var generator := FloorGenerator.new(content, structure, seed_value, 0)
		var stream := RunSeeds.rng(seed_value, "offers")
		check(generator.pick_pickup(null, null, anything, stream, {}, O.ITEMS) is ItemDefinition, "ITEMS picks an item")
		check(generator.pick_pickup(null, null, anything, stream, {}, O.EQUIPMENT) is EquipmentDefinition,
			"EQUIPMENT picks a piece")
		var any_pick: Resource = generator.pick_pickup(null, null, anything, stream, {})
		kinds["equipment" if any_pick is EquipmentDefinition else "items"] += 1
	check(kinds["items"] > 0 and kinds["equipment"] > 0, "ANY draws both (%s)" % kinds)
	# The same draws as before when nothing is filtered.
	var generator := FloorGenerator.new(content, structure, 3, 0)
	eq(generator.pick_pickup(null, null, anything, RunSeeds.rng(3, "x"), {}).id,
		generator.pick_pickup(null, null, anything, RunSeeds.rng(3, "x"), {}, O.ANY).id, "ANY is the default pick")
	# Nothing left: an equipment pedestal stays empty, an item pedestal gets the fallback item.
	var crate := GameplayTagQuery.new()
	crate.require_all_tags.assign([&"Fixture.Pool.Crate"])
	var held := {"held": [&"fixture.equipment.dagger", &"fixture.equipment.hood"]}
	eq(generator.pick_pickup(null, null, crate, RunSeeds.rng(1, "x"), held, O.EQUIPMENT), null,
		"no piece left: no pickup, never an item")
	eq(generator.pick_pickup(null, null, crate, RunSeeds.rng(1, "x"), held, O.ITEMS), structure.fallback_item,
		"no item left: the fallback item")


func test_the_item_room_offers_items_only() -> void:
	for seed_value in range(1, 31):
		var run := _run(str(seed_value))
		var cell := FloorRoomsWorld.special(run, FloorRoomsWorld.TREASURE_TAG)
		for pickup in run.state.map.cells[cell]["pickups"]:
			check(pickup.get("kind", "") != FloorGenerator.EQUIPMENT_KIND, "seed %d: the item room offers an item" % seed_value)
		_runs.erase(run)
		run.free()


# --- The bots and the verifier ------------------------------------------------------------------------------------------

func _helper() -> TestCase:
	var helper: TestCase = StepRunnerTest.new()
	helper.host = host
	_helpers.append(helper)
	return helper


func test_a_run_with_challenge_rooms_verifies_step_by_step_and_tampering_is_rejected() -> void:
	var content := FloorRoomsWorld.content()
	var helper := _helper()
	var played: Dictionary = await helper._play(content, FloorRoomsWorld.RUN_ID, false, 600)
	var run: RunController = played["run"]
	eq(run.runner_error, "", "the run plays")
	var summary := run.run_summary()
	check(int(summary.get("challengesCleared", 0)) >= 1, "the bots cleared a challenge room (%s)" % summary)
	var steps: Array[Dictionary] = helper._steps(content, FloorRoomsWorld.RUN_ID, played)
	var wave_steps: Array[Dictionary] = []
	for step in steps:
		var verdict: Dictionary = await helper._verify(content, step)
		eq(verdict.get("status"), "Verified", "step %s..%s (%s): %s" % [step["fromSeq"], step["toSeq"], step["kind"],
			verdict.get("mismatch", verdict)])
		var last: Dictionary = step["actions"].back() if not step["actions"].is_empty() else {}
		if last.get("action", {}).get("type", "") == "battle" and str(last["action"]["battle"]["battleId"]).ends_with("/w2"):
			wave_steps.append(step)
	check(not wave_steps.is_empty(), "a step ends on a wave 2 battle")
	failures.append_array(helper.failures)
	if wave_steps.is_empty():
		return
	var step: Dictionary = wave_steps[0]
	# A start that skips a wave: the claimed snapshot is not its hash.
	var skipped: Dictionary = step.duplicate(true)
	for entry in skipped["startSnapshot"]["map"]["cells"]:
		if entry.has("wave") or str(entry["content"].get("kind", "")) == "waves":
			entry["wave"] = 2
	var verdict: Dictionary = await helper._verify(content, skipped)
	eq(verdict.get("status"), "Rejected", "a skipped wave is rejected")
	eq(verdict.get("errorCode"), 2002, "with code 2002")
	# Wave 2 played against other enemies: the conditions are not what the run produces.
	var edited: Dictionary = step.duplicate(true)
	var battle: Dictionary = edited["actions"].back()["action"]["battle"]
	battle["conditions"]["enemies"] = battle["conditions"]["enemies"].slice(0, 1)
	battle["conditions"]["enemies"][0]["unitDefId"] = "fixture.enemy.chief"
	verdict = await helper._verify(content, edited)
	eq(verdict.get("status"), "Rejected", "edited wave enemies are rejected")
	eq(verdict.get("mismatch", {}).get("reason"), "ConditionsMismatch", "as ConditionsMismatch: %s" % verdict.get("mismatch"))
	# Rewards claimed after a wave: the state hash after it is not the replay's.
	var claimed: Dictionary = step.duplicate(true)
	claimed["actions"].back()["action"]["coinsAfter"] = 999
	claimed["actions"].back()["stateHash"] = "0".repeat(64)
	verdict = await helper._verify(content, claimed)
	eq(verdict.get("status"), "Rejected", "a hash claiming more after a wave is rejected")
	eq(verdict.get("errorCode"), 2002, "with code 2002")
	failures.append_array(helper.failures)


# --- Validator ----------------------------------------------------------------------------------------------------------

func _codes(content: ContentIndex) -> Array:
	return ContentValidator.validate(content, {"tags": false}).map(func(issue: ValidationIssue) -> String: return issue.code)


func test_validator_floor_rooms_rules() -> void:
	var clean := _codes(FloorRoomsWorld.content())
	for code in ["waves_too_few", "waves_outside_mode", "offers_mismatch", "offers_equipment_no_pool",
			"armory_without_item_room", "floor_rules_too_small"]:
		check(not clean.has(code), "the floor-rooms world raises no %s" % code)
	var broken := _codes(FloorRoomsWorld.content(func(parts: Dictionary) -> void:
		var one: Array[RoomWave] = [RoomWave.new()]
		parts["challenge"].waves = one
		parts["armory"].placements[0].item_query.require_all_tags.assign([&"Fixture.Pool.Nothing"])
		parts["vault"].waves = one
		parts["vault"].placements[0].equipment = TestCase.fixtures().equipment[&"fixture.equipment.blade"]
		var rules: FloorGenRules = parts["rules"]
		var only_armory: Array[StringName] = [FloorRoomsWorld.ARMORY_TAG, FloorRoomsWorld.CHALLENGE_TAG]
		rules.special_room_tags = only_armory
		rules.locked_room_tags = [] as Array[StringName]
		rules.base_rooms = 2
		rules.random_extra_rooms = 0
		var throne: RoomDefinition = TestCase.fixtures().rooms[&"fixture.room.throne"].duplicate()
		throne.content_mode = RoomDefinition.ContentMode.WAVES
		var two: Array[RoomWave] = [RoomWave.new(), RoomWave.new()]
		throne.waves = two
		parts["throne"] = throne
		var start: RoomDefinition = TestCase.fixtures().rooms[&"fixture.room.start"].duplicate()
		start.content_mode = RoomDefinition.ContentMode.WAVES
		start.waves = two
		parts["start"] = start))
	for code in ["waves_too_few", "waves_outside_mode", "offers_mismatch", "offers_equipment_no_pool",
			"armory_without_item_room", "floor_rules_too_small", "waves_boss_room", "waves_start_room"]:
		check(broken.has(code), "%s is raised" % code)
