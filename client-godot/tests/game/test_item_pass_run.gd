## Spec item-pass 3.5: equipment slots from the run structure, armor on pedestals and shelves (one pool with items),
## the armor inventory with equip / unequip, and the console commands for them. Fixtures only (the armory room, which
## no chapter generates).
extends TestCase

const PARTY: Array = [&"fixture.character.knight", &"fixture.character.medic"]
const HEAD: StringName = &"Fixture.Equipment.Slot.Head"
const HELM: StringName = &"fixture.equipment.helm"
const CAP: StringName = &"fixture.equipment.cap"
const MAIL: StringName = &"fixture.equipment.mail"

var _games: Array[GameMain] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


func _armory(seed_value: int = 7) -> RunController:
	var request := SandboxRequest.new()
	request.party = PARTY
	request.seed = seed_value
	request.room = fixtures().rooms[&"fixture.room.armory"]
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_sandbox(fixtures(), request), "", "the armory sandbox starts")
	return run


static func _pickups(run: RunController) -> Array:
	return run.state.map.cells[run.state.current_cell]["pickups"]


static func _placement_of(run: RunController, id: StringName) -> int:
	for pickup in _pickups(run):
		if pickup["item"] == id:
			return pickup["placement"]
	return -1


static func _def(run: RunController, slot: int) -> int:
	var battle := run._field_battle(0)
	var value := battle.unit_by_id(StringName("P%d" % slot)).stat("def")
	battle.free()
	return value


func test_equipment_slots() -> void:
	var run := _armory()
	eq(run.equipment_slots(), [&"Fixture.Equipment.Slot.Weapon", HEAD, &"Fixture.Equipment.Slot.Body"],
		"the run structure lists the slots, in order")
	var gear: Dictionary = DevReport.state_of(run)["party"][0]["gear"]
	eq(gear, {"Fixture.Equipment.Slot.Weapon": "fixture.equipment.blade", "Fixture.Equipment.Slot.Head": null,
		"Fixture.Equipment.Slot.Body": null}, "the report shows every slot, filled or empty")
	run.free()


func test_equipment_pickups() -> void:
	var run := _armory()
	var offered := {}
	for pickup in _pickups(run):
		offered[pickup["item"]] = pickup.get("kind", "item")
	eq(offered, {&"fixture.item.armory_ring": "item", CAP: "equipment", HELM: "equipment", MAIL: "equipment"},
		"pedestals pick items and equipment from one pool, no repeats; the shelf offers its fixed piece")
	var again := _armory()
	eq(_pickups(again), _pickups(run), "the same seed offers the same pickups")
	var ordered := []
	for seed_value in [1, 2, 3, 4, 5]:
		var other := _armory(seed_value)
		ordered.append(_pickups(other).map(func(pickup): return pickup["item"]))
		other.free()
	check(ordered.any(func(ids): return ids != ordered[0]), "different seeds order the pool differently")
	run.free()
	again.free()


func test_armor_inventory() -> void:
	var run := _armory()
	var def_before := _def(run, 1)
	eq(run.take(_placement_of(run, HELM), 2), "", "armor is taken (the slot argument is ignored)")
	eq(run.state.armor, [HELM], "it goes to the armor inventory")
	eq(run.run_log[-1]["kind"], "equipment", "the take is logged as equipment")
	check(not run.run_log[-1].has("slot"), "with no character")
	eq(run.take(_placement_of(run, HELM), 1), "already taken", "and can't be taken twice")
	check(run.state.canonical_lines().has("armor=%s" % HELM), "the inventory is in the run hash")

	eq(run.equip(1, HELM), "", "equip from the inventory")
	eq(run.state.member(1)["equipment"][HEAD], HELM, "the piece is worn")
	eq(run.state.armor, [], "and left the inventory")
	eq(_def(run, 1), def_before + def_before / 10, "its grants apply through GAS (+10% DEF)")
	eq(run.run_log[-1], {"type": "equip", "floor": run.state.floor_index, "slot": 1, "equipment": String(HELM)}, "logged")

	eq(run.take(_placement_of(run, CAP), 1), "", "a second head piece")
	eq(run.equip(1, CAP), "", "equipped over the first")
	eq(run.state.member(1)["equipment"][HEAD], CAP, "the new piece is worn")
	eq(run.state.armor, [HELM], "the replaced piece is back in the inventory")
	eq(run.unequip(1, HEAD), "", "unequip")
	eq(run.state.armor, [HELM, CAP], "back to the inventory")
	check(not run.state.member(1)["equipment"].has(HEAD), "the slot is empty")

	var logged := run.run_log.size()
	check(run.equip(1, MAIL) != "", "a piece not in the inventory is refused")
	check(run.unequip(2, HEAD) != "", "an empty slot is refused")
	run.pending_battle = {"cell": run.state.current_cell}
	check(run.equip(2, HELM) != "", "no equipping during a battle")
	run.pending_battle = {}
	eq(run.run_log.size(), logged, "refusals are not logged")

	eq(run.take(_placement_of(run, MAIL), 1), "not enough coins", "the shelf sells armor")
	run.add_coins(5)
	eq(run.take(_placement_of(run, MAIL), 1), "", "bought")
	eq([run.state.coins, run.run_log[-1]["type"]], [3, "buy"], "for its price")
	eq(run.equip(2, MAIL), "", "anyone can wear it")
	run.free()


func test_armor_never_repeats() -> void:
	var run := _armory()
	run.take(_placement_of(run, HELM), 1)
	var generator := FloorGenerator.new(run.content, run.structure, run.state.run_seed, 0)
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([&"Fixture.Pool.Armory"])
	var pools := run._pools()
	pools["seen"] = []  # only what the party has counts here
	for seed_value in 20:
		var picked: Resource = generator.pick_pickup(null, null, query, RunSeeds.rng(seed_value, "test"), pools)
		check(picked.id != HELM, "a piece in the inventory is never offered again")
	run.free()


func test_give_equipment_replaced_goes_to_inventory() -> void:
	var run := _armory()
	var knight: CharacterDefinition = fixtures().characters[&"fixture.character.knight"]
	run.give_equipment(fixtures().equipment[CAP], knight)
	run.give_equipment(fixtures().equipment[HELM], knight)
	eq(run.state.member(1)["equipment"][HEAD], HELM, "GiveEquipment equips directly")
	eq(run.state.armor, [CAP], "and the replaced piece goes to the inventory instead of being lost")
	run.free()


func test_wear_commands_and_items() -> void:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands()
	console.attach(game)
	var ok := func(line: String) -> Dictionary:
		var result: Dictionary = await console.execute(line)
		check(result["ok"], "'%s' works: %s" % [line, result["text"]])
		return result
	await ok.call("room fixture.room.armory")
	var run := game.run
	await ok.call("take %d 1" % _placement_of(run, HELM))
	await ok.call("wear %s 1" % HELM)
	eq(run.state.member(1)["equipment"].get(HEAD), HELM, "wear equips")
	await ok.call("unwear 1 %s" % HEAD)
	eq(run.state.armor, [HELM], "unwear puts it back")
	check(not (await console.execute("wear %s 1" % MAIL))["ok"], "wear refuses a piece not in the inventory")
	var listed: String = (await ok.call("items Fixture.Pool.Armory"))["text"]
	eq(listed.split("\n").size(), 3, "items <tag> lists the matching items and equipment")
	check(listed.contains("equipment %s" % HEAD) and listed.contains("Fixture armor: helm."), "with slot and description")
	await ok.call("spawn item %s 0" % MAIL)
	check(_pickups(run).any(func(pickup): return pickup["item"] == MAIL and pickup.get("kind") == "equipment" \
		and pickup["placement"] >= 1000), "spawn item takes equipment ids")
	var report: Dictionary = JSON.parse_string((await ok.call("state json"))["text"])
	eq(report["armor"], [String(HELM)], "state json shows the armor inventory")
