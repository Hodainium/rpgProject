## Spec boss-drops (section 6): what a won battle gives (its enemies' drops, its encounter's reward items and armor) lands on the
## room's floor as free pickups numbered from RunController.DROP_PLACEMENT, taken with take() and the member choice, left behind
## if the player likes, and verified step by step. Runs on the fixtures with droppers and rewards built in memory.
extends TestCase

const StepRunnerTest := preload("res://tests/game/test_step_runner.gd")
const FoodTest := preload("res://tests/game/test_food_items.gd")
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]
const DROP := RunController.DROP_PLACEMENT

var _runs: Array[RunController] = []
var _helpers: Array[TestCase] = []


func after_each() -> void:
	for helper in _helpers:
		helper.after_each()
	_helpers.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


class KillFirst extends ScriptedController:
	var _done := false

	func choose(battle: Battle, unit: BattleUnit) -> Dictionary:
		if not _done:
			_done = true
			return {"dev": &"Dev.Kill", "effect": RunController.dev_effect("dev_kill"), "targets": "enemies"}
		return super(battle, unit)


func _run(content: ContentIndex, party: Array = PARTY) -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	eq(run.start_run(content, party, "7"), "", "the run starts")
	return run


## The fixture pack (two grunts) as an encounter rewarding the whetstone and the hood, its grunts always dropping `item`.
static func _world(item: ItemDefinition = null) -> ContentIndex:
	var base := fixtures()
	if item == null:
		item = base.items[&"fixture.item.flask"]
	var grunt: EnemyDefinition = base.units[&"fixture.enemy.grunt"].duplicate()
	grunt.drop_item = item
	grunt.drop_chance_x100 = 10000
	var whetstone := GiveItem.new()
	whetstone.item = base.items[&"fixture.item.whetstone"]
	var hood := GiveEquipment.new()
	hood.equipment = base.equipment[&"fixture.equipment.hood"]
	var pack: EncounterDefinition = base.encounters[&"fixture.encounter.pack"].duplicate()
	pack.rewards = [whetstone, hood] as Array[RunOutcome]
	var overlay: Array = [grunt, pack]
	if not base.items.has(item.id):
		overlay.append(item)
	return base.overlay(overlay)


## Puts a battle against the pack in the current room (as test_progression does).
static func _inject(run: RunController) -> void:
	var encounter: EncounterDefinition = run.content.encounters[&"fixture.encounter.pack"]
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, run.state.floor_index)
	var enemies: Array = generator.resolve_enemies(encounter, null, true, null, RunSeeds.rng(1, "test"))
	run.state.map.cells[run.state.current_cell]["content"]["enemies"] = enemies
	run.pending_battle = {"cell": run.state.current_cell, "encounter": encounter.id, "enemies": enemies, "label": "/test"}


func _won(run: RunController) -> void:
	_inject(run)
	eq(await run.fight(KillFirst.new()), "", "the battle is fought")


static func _held(run: RunController, id: StringName) -> int:
	var count := 0
	for member in run.state.party:
		count += member["items"].count(id) + member["use_slots"].filter(
			func(use_slot: Dictionary) -> bool: return use_slot["item"] == id).size()
	return count


# --- Landing (6.1) ------------------------------------------------------------------------------------------------------

func test_a_won_battle_puts_rewards_then_drops_on_the_floor() -> void:
	var run := _run(_world())
	await _won(run)
	var drops := run.drop_pickups(run.state.current_cell)
	eq(drops.map(func(pickup: Dictionary) -> int: return pickup["placement"]), [DROP, DROP + 1, DROP + 2, DROP + 3],
		"rewards first, then the drops in roll order")
	eq(drops.map(func(pickup: Dictionary) -> String: return String(pickup["item"])),
		["fixture.item.whetstone", "fixture.equipment.hood", "fixture.item.flask", "fixture.item.flask"], "what landed")
	eq(drops.map(func(pickup: Dictionary) -> int: return pickup["drop"]), [0, 0, 1, 2], "rewards 0, drops their enemy's slot")
	eq(drops[1].get("kind"), FloorGenerator.EQUIPMENT_KIND, "the hood is armor")
	check(drops.all(func(pickup: Dictionary) -> bool: return pickup["price"] == 0 and not pickup["taken"]), "free, untaken")
	check(run.state.pending_gifts.is_empty(), "no gift waits")
	eq(_held(run, &"fixture.item.whetstone") + _held(run, &"fixture.item.flask"), 0, "nobody holds them yet")
	check(not run.state.armor.has(&"fixture.equipment.hood"), "the hood is not in the armor inventory yet")
	eq(run.give_to(1), "nothing to give", "nothing waits for give_to")
	var battle_entry: Dictionary = run.run_log.filter(func(entry: Dictionary) -> bool: return entry["type"] == "battle")[-1]
	eq(battle_entry.get("drops"), [DROP, DROP + 1, DROP + 2, DROP + 3], "the battle names what it dropped")
	check(MapCells.has_leftover(run.state.map.cells[run.state.current_cell]), "the map marks the room")


func test_take_gives_the_drop_to_the_member_picked() -> void:
	var run := _run(_world())
	await _won(run)
	eq(run.take(DROP + 2, 2), "", "take the first flask for the medic")
	eq(run.run_log[-1], {"type": "take", "floor": 0, "cell": run.state.current_cell, "placement": DROP + 2, "slot": 2},
		"logged as a take")
	eq(run.state.holder_of(&"fixture.item.flask"), 2, "the medic holds it")
	eq(run.take(DROP + 2, 3), "already taken", "a drop is taken once")
	eq(run.take(DROP + 1, 0), "", "take the hood")
	check(run.state.armor.has(&"fixture.equipment.hood"), "armor goes to the armor inventory")
	eq(run.take(DROP, 3), "", "take the whetstone for the rogue")
	eq(run.state.holder_of(&"fixture.item.whetstone"), 3, "the rogue holds it")


func test_food_is_eaten_by_the_taker() -> void:
	var snack := FoodTest.food()
	var run := _run(_world(snack))
	await _won(run)
	FoodTest._hurt_all(run)
	eq(run.take(DROP + 2, 3), "", "the rogue takes the snack")
	check(int(run.state.member(3)["hp"]) > 100, "the rogue ate it")
	eq(int(run.state.member(1)["hp"]), 100, "the knight did not")


# --- Nobody can hold it, leaving it (6.4, 6.5) --------------------------------------------------------------------------

func test_a_drop_nobody_can_hold_waits_on_the_floor() -> void:
	var run := _run(_world())
	var flask: ItemDefinition = run.content.items[&"fixture.item.flask"]
	for member in run.state.party:
		while member["use_slots"].size() < run.use_capacity(member["slot"]):
			member["use_slots"].append({"item": flask.id, "cooldown": 0})
	await _won(run)
	eq(run.drop_pickups(run.state.current_cell).size(), 4, "the flasks landed although nobody has a free slot")
	check(run.take(DROP + 2, 1).contains("no free use slot"), "a full member is refused")
	run.state.member(1)["use_slots"].pop_back()  # as a consumable used on the map frees its slot
	eq(run.take(DROP + 2, 1), "", "once a slot is free the take works")


func test_drops_can_be_left_behind() -> void:
	var run := _run(_world())
	await _won(run)
	eq(run.take(DROP, 1), "", "take one")
	eq(run.run_summary().get("dropsLeftBehind"), 3, "three still lie in the room")
	var map := run.state.map
	run._tally_left_behind(map)
	eq(run._tally.get("dropsLeftBehind"), 3, "counted when the floor is left")


# --- The winning battle, waves, a second battle (6.6, 6.7) -------------------------------------------------------------

func test_the_battle_that_wins_the_run_gives_as_before() -> void:
	var run := _run(_world())
	var boss := -1
	for index in run.state.map.sorted_indices():
		if run.state.map.cells[index]["role"] == FloorMap.ROLE_BOSS:
			boss = index
	run.state.floor_index = run.structure.floors.size() - 1
	run._grant_rewards(run.content.encounters[&"fixture.encounter.pack"], boss)
	run._roll_drops([{"unitDefId": "fixture.enemy.grunt", "slot": 1}], boss)
	check(run.drop_pickups(boss).is_empty(), "nothing lands in the boss room")
	eq(run.state.holder_of(&"fixture.item.whetstone"), run.state.party[0]["slot"], "the reward item goes to the first member")
	check(run.state.armor.has(&"fixture.equipment.hood"), "the reward armor goes to the armor inventory")
	eq(_held(run, &"fixture.item.flask"), 0, "and nothing drops")


func test_a_second_battle_in_the_room_numbers_on() -> void:
	var run := _run(_world())
	await _won(run)
	await _won(run)
	var placements := run.drop_pickups(run.state.current_cell).map(func(pickup: Dictionary) -> int: return pickup["placement"])
	eq(placements, range(DROP, DROP + 8), "the second battle's drops follow the first's")


# --- Names, validator (3.5, 6.8) ----------------------------------------------------------------------------------------

func test_drop_source_names() -> void:
	var run := _run(_world())
	await _won(run)
	var cell := run.state.current_cell
	var drops := run.drop_pickups(cell)
	var grunt: String = run.content.units[&"fixture.enemy.grunt"].display_name
	eq(run.drop_source_name(cell, drops[2]), grunt, "a drop names its enemy")
	eq(run.drop_source_name(cell, drops[0]), grunt, "a reward names the room's boss, else its first enemy")
	eq(run.drop_source_name(cell, {"placement": 1, "item": &"x", "price": 0, "taken": false}), "", "not a drop: no name")


func test_a_choose_reward_lands_too_and_the_validator_warns() -> void:
	var base := fixtures()
	var gift := GiveItem.new()
	gift.item = base.items[&"fixture.item.whetstone"]
	gift.recipient = GiveItem.Recipient.CHOOSE
	var pack: EncounterDefinition = base.encounters[&"fixture.encounter.pack"].duplicate()
	pack.rewards = [gift] as Array[RunOutcome]
	var content := base.overlay([pack])
	var run := _run(content)
	run._grant_rewards(pack, run.state.current_cell)
	check(run.state.pending_gifts.is_empty(), "nothing waits for give_to")
	eq(run.drop_pickups(run.state.current_cell).size(), 1, "the reward lies on the floor")
	var issues := ContentValidator.validate(content, {"tags": false})
	var codes := issues.map(func(issue: ValidationIssue) -> String: return issue.code)
	check(codes.has("reward_recipient_ignored"), "the validator warns: %s" % [codes])
	check(not codes.has("give_choose_outside_event"), "and raises no error for it")


# --- Snapshot and wire (6.9, 6.10) --------------------------------------------------------------------------------------

func test_snapshot_round_trip_keeps_the_drops() -> void:
	var run := _run(_world())
	await _won(run)
	eq(run.take(DROP + 2, 2), "", "take one")
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(RunSnapshot.restore(restored, run.content, saved), "", "the snapshot restores")
	eq(restored.state.run_hash(), run.state.run_hash(), "the same run hash")
	var drops := restored.drop_pickups(restored.state.current_cell)
	check(drops[3]["drop"] is int, "drop is an int again")
	eq(restored.take(DROP + 3, 3), "", "an untaken drop is still takeable")
	eq(restored.take(DROP + 2, 3), "already taken", "a taken one is not")


## Spec boss-drops 3.3: the run hash covers a drop's "drop" leaf (what test_snapshot_fields_are_covered does for every leaf of
## the committed runs, which hold no drops).
func test_the_run_hash_covers_the_drop_leaf() -> void:
	var run := _run(_world())
	await _won(run)
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	var changed: Dictionary = saved.duplicate(true)
	for cell in changed["map"]["cells"]:
		for pickup in cell["pickups"]:
			if pickup.has("drop") and int(pickup["drop"]) > 0:
				pickup["drop"] = int(pickup["drop"]) + 5
	var probe := RunController.new()
	host.add_child(probe)
	_runs.append(probe)
	eq(RunSnapshot.restore(probe, run.content, changed), "", "the changed snapshot restores")
	check(probe.state.run_hash() != run.state.run_hash(), "another drop slot is another run hash")


func test_the_battle_action_offers_what_it_dropped() -> void:
	var run := _run(_world())
	await _won(run)
	var battle_entry: Dictionary = run.run_log.filter(func(entry: Dictionary) -> bool: return entry["type"] == "battle")[-1]
	var action := RunWire.action(run, battle_entry, {})
	eq(action["offers"].map(func(offer: Dictionary) -> String: return offer["source"]), ["Reward", "Reward", "Drop", "Drop"],
		"Reward for the encounter's, Drop for the enemies'")
	eq(action["offers"][1]["kind"], "Equipment", "the hood is offered as equipment")
	var keys: Array = action.keys()
	check(keys.find("offers") < keys.find("battle"), "offers come before battle, as the C# record orders them")
	var plain := _run(fixtures())
	_inject(plain)
	await plain.fight(KillFirst.new())
	var quiet: Dictionary = plain.run_log.filter(func(entry: Dictionary) -> bool: return entry["type"] == "battle")[-1]
	check(not RunWire.action(plain, quiet, {}).has("offers"), "a battle that drops nothing has no offers")


# --- Verified step by step, tampering (4, 6.10) -------------------------------------------------------------------------

func _played() -> Dictionary:
	var droppers: Array = []
	for id in fixtures().units:
		var unit = fixtures().units[id]
		if unit is EnemyDefinition:
			var copy: EnemyDefinition = unit.duplicate()
			copy.drop_item = fixtures().items[&"fixture.item.whetstone"]
			copy.drop_chance_x100 = 10000
			droppers.append(copy)
	var content := fixtures().overlay(droppers)
	var helper: TestCase = StepRunnerTest.new()
	helper.host = host
	_helpers.append(helper)
	var played: Dictionary = await helper._play(content, StepRunnerTest.TWO_FLOORS)
	return {"content": content, "helper": helper, "played": played,
		"steps": helper._steps(content, StepRunnerTest.TWO_FLOORS, played)}


func test_a_run_with_drops_verifies_and_tampering_is_rejected() -> void:
	var base := await _played()
	var helper = base["helper"]
	var run: RunController = base["played"]["run"]
	var takes := run.run_log.filter(func(entry: Dictionary) -> bool:
		return entry["type"] == "take" and int(entry["placement"]) >= DROP)
	check(not takes.is_empty(), "the bots took dropped items")
	for step in base["steps"]:
		var verdict: Dictionary = await helper._verify(base["content"], step)
		eq(verdict.get("status"), "Verified", "step %s..%s (%s): %s" % [step["fromSeq"], step["toSeq"], step["kind"],
			verdict.get("mismatch", verdict)])
	# A take of a drop the battle never put out is refused by the replay: Rejected 2002.
	var taking: Dictionary = {}
	for step in base["steps"]:
		for request in step["actions"]:
			if request["action"]["type"] == "take" and int(request["action"].get("placement", 0)) >= DROP:
				taking = step.duplicate(true)
				break
		if not taking.is_empty():
			break
	check(not taking.is_empty(), "a step holds a drop's take")
	for request in taking["actions"]:
		if request["action"]["type"] == "take" and int(request["action"].get("placement", 0)) >= DROP:
			request["action"]["placement"] = DROP + 99
			break
	var refused: Dictionary = await helper._verify(base["content"], taking)
	eq(refused.get("status"), "Rejected", "a forged drop take is rejected")
	eq(refused.get("errorCode"), 2002, "with 2002")
	# A claimed start state holding a drop the replay never rolled is named at the step's start.
	var forged: Dictionary = {}
	for step in base["steps"]:
		if step["kind"] == "Segment" and step["startSnapshot"] != null:
			forged = step.duplicate(true)
			break
	check(not forged.is_empty(), "a segment step has a start snapshot")
	forged["startSnapshot"]["map"]["cells"][0]["pickups"].append({"placement": DROP + 50, "item": "fixture.item.whetstone", "price": 0, "taken": false,
		"drop": 1})
	var mismatch: Dictionary = await helper._verify(base["content"], forged)
	eq(mismatch.get("status"), "Rejected", "a smuggled drop is rejected")
	eq(mismatch.get("errorCode"), 2002, "with 2002")
	eq(mismatch.get("mismatch", {}).get("reason"), "SnapshotHashMismatch", "as a snapshot hash mismatch")
	failures.append_array(helper.failures)
