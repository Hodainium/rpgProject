## Spec floor-chests 6: a chest stays in the room where it dropped and opens there like a shop; its items and armor wait on the
## floor beside it as free pickups, everything else is given at once; chests left behind are counted; the snapshot, the wire, the
## map tint, the UI state and the validator follow. Fixtures only (the keyed run of KeysWorld, chests built in memory).
extends TestCase

var _runs: Array[Node] = []
var _handles: Array = []


func after_each() -> void:
	for handle in _handles:
		handle.unregister()
	_handles.clear()
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _keyed(tweak: Callable = Callable()) -> RunController:
	var run := KeysWorld.start(host, "7", tweak)
	_runs.append(run)
	return run


func _chest(name: String) -> ChestDefinition:
	return fixtures().chests[StringName("fixture.chest." + name)]


func _item(name: String) -> ItemDefinition:
	return fixtures().items[StringName("fixture.item." + name)]


## A chest built in memory whose one reward runs `outcomes` (an item, coins, another chest...), added to `run`'s content.
func _custom_chest(run: RunController, id: String, outcomes: Array) -> ChestDefinition:
	var reward := ChestReward.new()
	reward.outcomes.assign(outcomes)
	var chest := ChestDefinition.new()
	chest.id = StringName(id)
	chest.display_name = id.get_slice(".", 2).capitalize()
	chest.description = "test chest"
	chest.rewards.assign([reward])
	run.content = run.content.overlay([chest])
	return chest


func _give(item: ItemDefinition) -> GiveItem:
	var gift := GiveItem.new()
	gift.item = item
	return gift


func test_a_cleared_room_keeps_its_chest() -> void:
	var run := _keyed()
	var cell := KeysWorld.normal(run)
	var found := []
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.RUN_CHEST_FOUND, func(_c, message): found.append(message)))
	run._clear_room(cell, true)
	eq(run.state.map.cells[cell]["chests"].size(), 1, "the drop lands in the room just cleared")
	check(not run.state.map.cells[run.state.current_cell].has("chests"), "not in the room the party stands in")
	eq([found.size(), int(found[0].data["cell"]), int(found[0].data["serial"])] if not found.is_empty() else [], [1, cell, 0],
		"Message.Run.ChestFound names its room and serial")
	eq(run.room_chests(), [] as Array[Dictionary], "room_chests() lists only the current room's")
	check(Array(run.state.map.canonical_lines()).any(func(line: String) -> bool: return line.contains("chests")),
		"the room's chests are hashed with the map")


func test_open_needs_the_room() -> void:
	var run := _keyed()
	var cell := KeysWorld.normal(run)
	run._clear_room(cell, true)
	var serial: int = run.state.map.cells[cell]["chests"][0]["serial"]
	var before := run.state.run_hash()
	eq(run.open_chest(serial), "no chest %d here" % serial, "a chest in another room cannot be opened from here")
	eq(run.state.run_hash(), before, "and nothing changed")
	# An uncleared room: a cheat drops a chest into a room whose battle is still to come.
	run.state.map.cells[run.state.current_cell]["cleared"] = false
	run.give_chest(_chest("crate"))
	eq(run.open_chest(run.state.chest_serial - 1), "clear the room first", "a chest in an uncleared room waits")


func test_items_wait_beside_the_chest_and_other_rewards_are_given() -> void:
	var run := _keyed()
	var coins := GainCoins.new()
	coins.amount = 5
	var wooden := _custom_chest(run, "fixture.chest.mixed", [_give(_item("whetstone")), coins])
	run.give_chest(wooden)
	var before := run.state.coins
	eq(run.open_chest(0), "", "opens")
	eq(run.state.coins, before + 5, "the coins are given at once")
	var put_out := run.chest_pickups(run.state.current_cell, 0)
	eq(put_out.map(func(pickup: Dictionary) -> Array: return [pickup["item"], pickup["price"], pickup["chest"],
		pickup["placement"]]), [[&"fixture.item.whetstone", 0, 0, RunController.CHEST_PLACEMENT]],
		"the item is a free pickup carrying its chest, numbered from 2000")
	eq(run.room_chests()[0]["filled"], true, "the chest reads filled while its item is left")
	eq(RunWire.offers(run.state, run.state.current_cell).map(func(offer: Dictionary) -> String: return offer["source"]),
		["Chest"], "its offer's source is Chest")
	# Leave and come back: the item is still there.
	var other: int = run.state.map.neighbours(run.state.current_cell).filter(func(index: int) -> bool:
		return run.can_enter(index) and not run.room_locked(index))[0]
	var home := run.state.current_cell
	run.state.map.cells[other]["cleared"] = true
	run.state.map.cells[other]["content"] = {"kind": "empty", "encounter": &"", "event": &"", "enemies": []}
	eq(run.enter_room(other), "", "leave the room")
	eq(run.enter_room(home), "", "come back")
	eq(run.chest_pickups(home, 0)[0]["taken"], false, "the item waits in the chest's room")
	eq(run.take(RunController.CHEST_PLACEMENT, 1), "", "taken by the knight")
	eq([run.state.holder_of(&"fixture.item.whetstone"), run.room_chests()[0]["filled"]], [1, false], "held; the chest is empty")


func test_a_chest_from_a_chest_appears_closed() -> void:
	var run := _keyed()
	var give := GiveChest.new()
	give.chest = _chest("crate")
	var outer := _custom_chest(run, "fixture.chest.nest", [give])
	run.give_chest(outer)
	eq(run.open_chest(0), "", "the outer chest opens")
	eq(run.room_chests().map(func(chest: Dictionary) -> Array: return [chest["chest"], chest["opened"]]),
		[[&"fixture.chest.nest", true], [&"fixture.chest.crate", false]], "the inner one stands in the room, closed")
	eq(run.open_chest(1), "", "and opens on its own")


func test_chests_left_behind_are_counted() -> void:
	var run := _keyed()
	run.give_chest(_chest("crate"))
	run.give_chest(_chest("crate"))
	run.open_chest(1)  # its piece of gear stays beside it
	var summary := run.run_summary()
	eq([summary["chestsLeft"], summary["chestItemsLeft"]], [1, 1], "on this floor: one closed chest, one item left")
	run.dev_boss_done()
	eq(run.next_floor(), "", "the stairs")
	check(run.room_chests().is_empty(), "the chests stayed on the floor left behind")
	summary = run.run_summary()
	eq([summary["chestsLeft"], summary["chestItemsLeft"]], [1, 1], "and are still counted")


func test_snapshot_round_trip_and_old_saves() -> void:
	var run := _keyed()
	var coins := GainCoins.new()
	coins.amount = 1
	var chest := _custom_chest(run, "fixture.chest.pair", [_give(_item("whetstone")), _give(_item("crest")), coins])
	run.give_chest(chest)
	run.give_chest(_chest("strongbox"))
	run.open_chest(0)
	run.take(RunController.CHEST_PLACEMENT, 1)  # half emptied: the crest is still beside it
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(run.snapshot()))
	var loaded := RunController.new()
	host.add_child(loaded)
	_runs.append(loaded)
	eq(loaded.load_snapshot(run.content, saved), "", "a snapshot with room chests loads")
	eq(loaded.state.run_hash(), run.state.run_hash(), "to the same hash")
	eq(loaded.room_chests().map(func(held: Dictionary) -> Array: return [held["chest"], held["opened"], held["inside"]]),
		[[&"fixture.chest.pair", true, 1], [&"fixture.chest.strongbox", false, 0]], "the chests as they were")
	check(loaded.room_chests()[0]["chest"] is StringName, "ids come back as StringNames")
	eq(typeof(loaded.chest_pickups(loaded.state.current_cell, 0)[1]["chest"]), TYPE_INT, "serials as ints")
	var old: Dictionary = saved.duplicate(true)
	old["run"]["chests"] = [{"chest": "fixture.chest.crate", "serial": 0}]
	var refused := RunController.new()
	host.add_child(refused)
	_runs.append(refused)
	check(refused.load_snapshot(run.content, old).ends_with(RunSnapshot.OLD_SAVE_PROBLEM),
		"a save holding a chest inventory is refused (Q1)")
	eq(RunSnapshot.shape_problem(old), RunSnapshot.OLD_SAVE_PROBLEM, "and its shape check says so too")


func test_open_chest_on_the_wire() -> void:
	var run := _keyed()
	var chest := _custom_chest(run, "fixture.chest.wire", [_give(_item("whetstone"))])
	run.give_chest(chest)
	run.open_chest(0)
	var wire := RunWire.action(run, run.run_log[-1], {})
	eq(wire, {"type": "open_chest", "floor": 0, "cell": run.state.current_cell, "chestId": "fixture.chest.wire", "serial": 0,
		"coinsAfter": run.state.coins, "offers": [{"placement": RunController.CHEST_PLACEMENT, "itemId": "fixture.item.whetstone",
		"price": 0, "source": "Chest", "kind": "Item"}]}, "cell, chest, serial and what it put out, in the record's order")
	var replay := _keyed()
	_custom_chest(replay, "fixture.chest.wire", [_give(_item("whetstone"))])
	replay.give_chest(replay.content.chests[&"fixture.chest.wire"])
	var elsewhere: Dictionary = wire.duplicate()
	elsewhere["cell"] = run.state.current_cell + 1
	check((await RunWire.apply(replay, elsewhere)) != "", "a chest claimed in another room is refused")
	eq(await RunWire.apply(replay, wire), "", "the logged action replays")
	eq(replay.state.run_hash(), run.state.run_hash(), "to the same hash")


func test_map_tint_and_pickup_state() -> void:
	var run := _keyed()
	var here := run.state.current_cell
	var cells := MapCells.of(run)
	check(not cells[here]["leftover"], "an empty start room is not tinted")
	check(not UIState.compute("run", run).has(UIState.PICKUP), "no pickup panel in an empty room")
	run.give_chest(_chest("crate"))
	check(MapCells.of(run)[here]["leftover"], "a closed chest tints the room")
	check(UIState.compute("run", run).has(UIState.PICKUP), "and shows the pickup panel (its Open row)")
	run.open_chest(0)
	check(MapCells.of(run)[here]["leftover"], "so does the gear it put out")
	run.take(RunController.CHEST_PLACEMENT, 0)
	check(not MapCells.of(run)[here]["leftover"], "an emptied room is not")
	check(not MapCells.has_leftover({"pickups": [{"placement": 1, "item": &"x", "price": 4, "taken": false}]}),
		"a shop's priced stock never counts")
	check(MapCells.has_leftover({"pickups": [{"placement": 1, "item": &"x", "price": 0, "taken": false}]}),
		"a free pedestal item does")
	check(not MapCells.has_leftover({"pickups": [{"placement": 1, "item": &"x", "price": 0, "taken": false,
		"priceItem": &"curse"}]}), "an altar's priced item does not")


func test_validator_and_rest_stop() -> void:
	var give := GiveChest.new()
	give.chest = _chest("crate")
	var choice := EventChoice.new()
	choice.outcomes.assign([give])
	var page := EventPage.new()
	page.choices.assign([choice])
	var rest := EventDefinition.new()
	rest.id = &"fixture.event.rest_chest"
	rest.pages.assign([page])
	var structure: RunStructure = fixtures().runs[&"fixture.run.two_floors"].duplicate()
	structure.id = &"fixture.run.rest_chest"
	structure.rest_event = rest
	var codes := ContentValidator.validate(fixtures().overlay([rest, structure]), {"tags": false}).map(
		func(issue: ValidationIssue) -> String: return issue.code)
	check(codes.has("give_chest_outside_room"), "a GiveChest at the rest stop is an error (Q2)")
	check(not ContentValidator.validate(fixtures(), {"tags": false}).any(func(issue: ValidationIssue) -> bool:
		return issue.code == "give_chest_outside_room"), "the fixtures have none")
	# Should one slip through: an error and nothing given.
	var run := _keyed()
	run.state.event = {"cell": -1, "event": rest.id, "page": 0, "rest_to": 1}
	run.give_chest(_chest("crate"))  # push_error (logged, never a test failure) and a run warning
	eq(run.state.chest_serial, 0, "no chest is made")
	check(Array(run.warnings).any(func(text: String) -> bool: return text.contains("no room to land in")), "and it warns")
	eq(run.dev_chest(_chest("crate")), "no room here for a chest", "the cheat refuses too")


## Review fixes: a malformed open_chest or chest entry is a refused request (exit 3), never a missing-key runner error; a chest's
## item taken toasts with its chest's serial; the bots give a chest's food to the most wounded member, as a gift was.
func test_review_fixes() -> void:
	var run := _keyed()
	run.give_chest(_chest("crate"))
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(run.snapshot()))
	for cell in saved["map"]["cells"]:
		if cell.has("chests"):
			cell["chests"][0].erase("opened")
	check(RunSnapshot.shape_problem(saved).contains("chest"), "a chest entry with no opened is a shape problem")
	var request := {"schemaVersion": StepRunner.REQUEST_SCHEMA_VERSION, "runId": "r", "runStructureId": "s",
		"kind": "Segment", "characterIds": ["c"], "floorSeeds": {"0": "1"}, "fromSeq": 2, "toSeq": 2,
		"startSnapshot": JSON.parse_string(WireJson.stringify(run.snapshot())), "startStateHash": "h",
		"actions": [{"seq": 2, "stateHash": "h", "action": {"type": "open_chest", "floor": 0, "serial": 0}}]}
	check(StepRunner.validate(request).contains("open_chest"), "an open_chest with no cell is malformed (%s)" % StepRunner.validate(request))
	request["actions"][0]["action"]["cell"] = run.state.current_cell
	eq(StepRunner.validate(request), "", "with its cell it is well formed")
	# ItemTaken names the chest.
	var taken := []
	_handles.append(GameplayMessages.listen(GameplayMessageRouter.RUN_ITEM_TAKEN, func(_c, message): taken.append(message)))
	var food: ItemDefinition = _item("whetstone").duplicate()
	food.id = &"fixture.item.chest_food"
	food.tags = [&"Pool.Food"] as Array[StringName]  # a new array: duplicate() shares the cached fixture's
	var chest := _custom_chest(run, "fixture.chest.food", [_give(food)])
	run.content = run.content.overlay([food])
	run.give_chest(chest)
	run.open_chest(1)
	run.state.member(2)["hp"] = 1  # the medic is the most wounded
	await RunPlayer.play(run, 1)
	eq(run.state.holder_of(food.id), 2, "the bot gives a chest's food to the most wounded member")
	var food_taken := taken.filter(func(message) -> bool: return message.target == food.id)
	eq(int(food_taken[0].data.get("chest", -1)) if not food_taken.is_empty() else -1, 1, "Message.Run.ItemTaken names the chest")
