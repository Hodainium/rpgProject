## Spec unique-events: a query event once per run (placed = seen), the normal-room fallback when a chapter runs dry, fixed and
## rest-stop events repeating, a drained pool giving food (the fallback item only without holdable food; the armory too),
## named items repeating, the hash line, snapshots old and new, and the seed tools generating the run's floors.
## Fixtures only: chapter A's shrine (an EVENT_QUERY Normal room) draws from the two fixture events; food is built in memory.
extends TestCase

const FoodItems := preload("res://tests/game/test_food_items.gd")
const COIN: StringName = &"fixture.event.coin"
const TOLL: StringName = &"fixture.event.toll"
const SHRINE: StringName = &"fixture.room.shrine"
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic", "fixture.character.rogue"]

var _runs: Array[RunController] = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


func _run(content: ContentIndex = null, seed_text: String = "7", structure: StringName = &"") -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	var error := run.start_run(content if content != null else fixtures(), PARTY, seed_text, structure)
	check(error == "", "the run starts: " + error)
	return run


static func _structure(content: ContentIndex) -> RunStructure:
	return content.runs[&"fixture.run.two_floors"]


static func _chapter(content: ContentIndex) -> ChapterDefinition:
	return content.chapters[&"fixture.chapter.a"]


static func _pools(seen_events: Array = []) -> Dictionary:
	return {"party": [], "held": [], "seen": [], "seen_events": seen_events.duplicate()}


## Floor `depth` of `seed_value` on chapter A.
static func _floor(content: ContentIndex, seed_value: int, depth: int, pools: Dictionary) -> FloorMap:
	var generator := FloorGenerator.new(content, _structure(content), seed_value, depth)
	var result := generator.generate(_chapter(content), false, pools)
	return result["map"]


static func _events_of(map: FloorMap) -> Array[StringName]:
	var events: Array[StringName] = []
	for index in map.sorted_indices():
		var cell_content: Dictionary = map.cells[index]["content"]
		if cell_content["kind"] == "event":
			events.append(cell_content["event"])
	return events


static func _nothing() -> GameplayTagQuery:
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([&"Fixture.Pool.Nothing"])
	return query


# --- Events -------------------------------------------------------------------------------------------------------------

## F2: two event rooms of one floor never hold the same event, and placing an event records it.
func test_events_unique_within_a_floor() -> void:
	var doubled := 0
	for seed_value in range(1, 151):
		var pools := _pools()
		var map := _floor(fixtures(), seed_value, 1, pools)
		var events := _events_of(map)
		var distinct: Array[StringName] = []
		for event in events:
			if not distinct.has(event):
				distinct.append(event)
		eq(distinct.size(), events.size(), "seed %d: the floor's events are distinct" % seed_value)
		eq(pools["seen_events"], events, "seed %d: every placed event is seen, in placement order" % seed_value)
		if events.size() >= 2:
			doubled += 1
	check(doubled > 0, "some floor holds two event rooms (%d)" % doubled)


## F3: across floors of one run, a placed event never comes back while an unseen one matches.
func test_events_unique_across_floors() -> void:
	var checked := 0
	for seed_value in range(1, 121):
		var pools := _pools()
		var first := _events_of(_floor(fixtures(), seed_value, 0, pools))
		var second := _events_of(_floor(fixtures(), seed_value, 1, pools))
		for event in second:
			check(not first.has(event), "seed %d: %s placed on floor 0 is not placed again on floor 1" % [seed_value, event])
		if not first.is_empty() and not second.is_empty():
			checked += 1
	check(checked > 0, "some seed has events on both floors (%d)" % checked)
	# The run keeps the list: it is what the next floor's pools carry.
	var run := _run()
	eq(run.state.seen_events, _events_of(run.state.map), "the run records the first floor's events")
	eq(run._pools()["seen_events"], run.state.seen_events, "and hands them to the next floor's generator")


## F1: every matching event seen: each event room becomes another Normal room of the chapter fitting its doors.
func test_exhausted_event_pool_falls_back_to_a_normal_room() -> void:
	var swapped := 0
	for seed_value in range(1, 81):
		var pools := _pools([COIN, TOLL])
		var map := _floor(fixtures(), seed_value, 1, pools)
		eq(_events_of(map), [] as Array[StringName], "seed %d: no event repeats" % seed_value)
		eq(pools["seen_events"], [COIN, TOLL], "seed %d: nothing new is recorded" % seed_value)
		var plain := _floor(fixtures(), seed_value, 1, _pools())
		for index in map.sorted_indices():
			var data: Dictionary = map.cells[index]
			if not data.get("fallback", false):
				eq(data["room"], plain.cells[index]["room"], "seed %d cell %d: a cell that kept its room is unchanged" % [seed_value, index])
				continue
			swapped += 1
			# Only an event room is swapped (the plain floor may have run out too, on its third event room: the same swap).
			check(plain.cells[index]["room"] == SHRINE or plain.cells[index].get("fallback", false), "only the event room is swapped")
			var room: RoomDefinition = fixtures().rooms[data["room"]]
			check(room.content_mode != RoomDefinition.ContentMode.EVENT_QUERY and room.fits(data["doors"]),
				"seed %d cell %d: %s is a non-event room fitting the doors" % [seed_value, index, room.id])
			check(TagMatch.has(room.tags, &"Fixture.Room.Type.Normal"), "the replacement is a Normal room")
			eq(data["content"]["kind"], "encounter", "its content resolves as usual (an encounter)")
	check(swapped > 0, "some event room was swapped (%d)" % swapped)


## F1b: no replacement fits: the room's content is none, flagged, never an error or a repeat. Chapter A's other Normal
## rooms become event rooms too, so no non-event room is left to swap in.
func test_fallback_without_a_room_is_empty() -> void:
	var dead: Array = []
	for id in [&"fixture.room.cross", &"fixture.room.hall"]:
		var room: RoomDefinition = fixtures().rooms[id].duplicate()
		room.content_mode = RoomDefinition.ContentMode.EVENT_QUERY
		dead.append(room)
	var content := fixtures().overlay(dead)
	var empty := 0
	for seed_value in range(1, 31):
		var pools := _pools([COIN, TOLL])
		var generator := FloorGenerator.new(content, _structure(content), seed_value, 0)
		var result := generator.generate(_chapter(content), false, pools)
		eq(result["error"], "", "seed %d: the floor still generates" % seed_value)
		for index in result["map"].sorted_indices():
			var data: Dictionary = result["map"].cells[index]
			if data.get("fallback", false):
				empty += 1
				check(content.rooms[data["room"]].content_mode == RoomDefinition.ContentMode.EVENT_QUERY, "the room stays")
				eq(data["content"]["kind"], "none", "its content is none")
	check(empty > 0, "some event room found no replacement (%d)" % empty)
	var codes := ContentValidator.validate(content, {"generate_seeds": 0}).map(func(issue: ValidationIssue) -> String: return issue.code)
	check(codes.has("event_fallback_room_missing"), "the validator warns in advance")
	var clean := ContentValidator.validate(fixtures(), {"generate_seeds": 0}).map(func(issue: ValidationIssue) -> String: return issue.code)
	check(not clean.has("event_fallback_room_missing"), "the fixtures' event room always has a replacement")


## The swap stream is its own: a floor that never runs out is exactly what it was, and the same seed generates twice alike.
func test_swap_leaves_other_floors_unchanged() -> void:
	for seed_value in [3, 7, 21]:
		var a := _floor(fixtures(), seed_value, 0, _pools())
		var b := _floor(fixtures(), seed_value, 0, _pools())
		eq(a.canonical_lines(), b.canonical_lines(), "seed %d: deterministic" % seed_value)
		for index in a.sorted_indices():
			check(not a.cells[index].has("fallback"), "no fallback while events are left")


## F4: a fixed event (a room's own, a layout or sandbox override) and the rest stop repeat and are not recorded.
func test_fixed_and_rest_events_repeat() -> void:
	var fixed: RoomDefinition = fixtures().rooms[SHRINE].duplicate()
	fixed.id = &"fixture.room.fixed_shrine"
	fixed.content_mode = RoomDefinition.ContentMode.EVENT
	fixed.event = fixtures().events[COIN]
	var generator := FloorGenerator.new(fixtures().overlay([fixed]), _structure(fixtures()), 7, 0)
	var pools := _pools([COIN, TOLL])
	var result := generator.single_room(fixed, _chapter(fixtures()), pools)
	eq(result["map"].cells[0]["content"]["event"], COIN, "a room's fixed event is placed although seen")
	result = generator.single_room(fixtures().rooms[SHRINE], _chapter(fixtures()), pools, null, fixtures().events[TOLL])
	eq(result["map"].cells[0]["content"]["event"], TOLL, "an override event is placed although seen")
	eq(pools["seen_events"], [COIN, TOLL], "neither is recorded again")
	# The rest stop.
	var structure: RunStructure = _structure(fixtures()).duplicate()
	structure.rest_event = fixtures().events[COIN]
	var run := _run(fixtures().overlay([structure]))
	run.state.seen_events.assign([COIN])
	eq(run.dev_boss_done(), "", "the boss is beaten")
	eq(run.next_floor(), "", "the stairs")
	eq(run.state.event.get("event"), COIN, "the rest stop opens its event, seen or not")
	eq(run.state.seen_events.count(COIN), 1, "the rest stop is not recorded")


# --- Hash and snapshots -------------------------------------------------------------------------------------------------

func test_events_seen_hash_line() -> void:
	var state := RunState.new()
	check(not "\n".join(state.canonical_lines()).contains("run.seenEvents="), "absent while empty")
	var before := state.run_hash()
	state.seen_events.assign([COIN, TOLL])
	check(state.canonical_lines().has('run.seenEvents=["%s","%s"]' % [COIN, TOLL]), "present after, in placement order")
	var forward := state.run_hash()
	check(forward != before, "it moves the hash")
	state.seen_events.assign([TOLL, COIN])
	check(state.run_hash() != forward, "order-sensitive")


## F7: a snapshot carries the seen events; the restored run hashes alike and hands them on.
func test_resume_keeps_seen_events() -> void:
	var run := _seeded_run()
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	eq(saved["run"]["seenEvents"], run.state.seen_events.map(func(id) -> String: return String(id)), "the snapshot lists them")
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(restored.load_snapshot(fixtures(), saved), "", "it restores")
	eq(restored.state.seen_events, run.state.seen_events, "the seen events come back")
	check(restored.state.seen_events.all(func(id) -> bool: return id is StringName), "as StringNames")
	eq(restored.state.run_hash(), run.state.run_hash(), "the hash matches")


## F9: an older save with no seenEvents restores with none.
func test_old_snapshot_restores() -> void:
	var run := _seeded_run()
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	saved["run"].erase("seenEvents")
	eq(RunSnapshot.shape_problem(saved), "", "its shape is fine")
	var restored := RunController.new()
	host.add_child(restored)
	_runs.append(restored)
	eq(restored.load_snapshot(fixtures(), saved), "", "it restores")
	eq(restored.state.seen_events, [] as Array[StringName], "with no seen events")
	saved["run"]["seenEvents"] = "coin"
	check(RunSnapshot.shape_problem(saved) != "", "a seenEvents that is not an array is refused")


## F8: a client that repeats an event generates different floors from the verifier's, so its hashes differ.
func test_repeated_event_hash_mismatch() -> void:
	var differs := 0
	for seed_value in range(1, 121):
		var honest := _pools()
		_floor(fixtures(), seed_value, 0, honest)
		if honest["seen_events"].is_empty():
			continue
		var floor_1 := _floor(fixtures(), seed_value, 1, honest)
		var cheat_pools := _pools()
		_floor(fixtures(), seed_value, 0, cheat_pools)
		var first: Array = cheat_pools["seen_events"].duplicate()
		cheat_pools["seen_events"] = []  # a client that forgot floor 0's events (and kept everything else)
		var cheat := _floor(fixtures(), seed_value, 1, cheat_pools)
		if floor_1.canonical_lines() != cheat.canonical_lines():
			differs += 1
			check(_events_of(cheat).any(func(event) -> bool: return first.has(event)),
				"seed %d: the cheat's floor repeats a floor-0 event" % seed_value)
	check(differs > 0, "some seed's floor 1 differs when the rule is ignored (%d)" % differs)
	var run := _seeded_run()
	var hash: String = run.state.run_hash()
	run.state.seen_events.clear()
	check(run.state.run_hash() != hash, "dropping the seen events moves the run hash")


## F10: the seed tools carry the run's pools keys: floor 1 of a seed is the run's floor 1.
func test_seed_report_matches_the_run() -> void:
	var compared := 0
	for seed_value in range(1, 40):
		var run := _run(null, str(seed_value))
		if run.state.seen_events.is_empty():
			run.free()
			continue
		eq(run.dev_boss_done(), "", "the boss is beaten")
		eq(run.next_floor(), "", "the next floor")
		var shown: Dictionary = SeedReport.floor_of(fixtures(), seed_value, 1)
		eq(shown["error"], "", "the seed report builds floor 1")
		for index in run.state.map.sorted_indices():
			eq(shown["map"].cells[index]["room"], run.state.map.cells[index]["room"], "seed %d cell %d: same room" % [seed_value, index])
			eq(shown["map"].cells[index]["content"], run.state.map.cells[index]["content"], "seed %d cell %d: same content" % [seed_value, index])
		compared += 1
		if compared >= 4:
			break
	check(compared > 0, "some seeds were compared")


## A run whose first floor placed a query event.
func _seeded_run() -> RunController:
	for seed_value in range(1, 60):
		var run := _run(null, str(seed_value))
		if not run.state.seen_events.is_empty():
			return run
	check(false, "no fixture seed places an event")
	return _run()


# --- Drained pools ------------------------------------------------------------------------------------------------------

## F5: pick_item and pick_pickup with nothing left give a food item (on the same stream), counted as drained.
func test_drained_pool_gives_food() -> void:
	var snack := FoodItems.food("snack")
	var content := fixtures().overlay([snack])
	var generator := FloorGenerator.new(content, _structure(content), 7, 0)
	eq(generator.pick_item(null, _nothing(), RunSeeds.rng(1, "t"), _pools()), snack, "pick_item gives food")
	eq(generator.pick_pickup(null, null, _nothing(), RunSeeds.rng(1, "t"), _pools()), snack, "pick_pickup gives food")
	eq(generator.pools_drained, 2, "two drained picks")
	eq(generator.pick_item(null, _nothing(), RunSeeds.rng(1, "t"), _pools(), false), null, "use_fallback false: nothing")
	# Outcomes by query: GiveItem and GiveEquipment through the run.
	var run := _run(content)
	var drained_before: int = run.run_summary().get("poolsDrained", 0)  # the floor's own pedestals may have drained
	_hurt(run)
	run.give_item(null, _nothing(), null)
	check(run.state.seen_items.has(snack.id), "GiveItem by query gives food (marked seen)")
	_hurt(run)
	var before: int = run.state.member(1)["hp"]
	run.give_equipment_from(_nothing(), false)
	check(run.state.member(1)["hp"] > before, "GiveEquipment by query gives food too (eaten by the first member)")
	eq(run.run_summary().get("poolsDrained"), drained_before + 2, "run_summary counts the drained picks")


## F5: no food some living member can hold → the run's fallback item, as before.
func test_drained_pool_without_food_gives_fallback() -> void:
	var fallback: ItemDefinition = _structure(fixtures()).fallback_item
	var generator := FloorGenerator.new(fixtures(), _structure(fixtures()), 7, 0)
	eq(generator.pick_item(null, _nothing(), RunSeeds.rng(1, "t"), _pools()), fallback, "no food at all: the fallback item")
	var snack := FoodItems.food("snack")
	var content := fixtures().overlay([snack])
	generator = FloorGenerator.new(content, _structure(content), 7, 0)
	var pools := _pools()
	pools["unholdable"] = [snack.id]
	eq(generator.pick_item(null, _nothing(), RunSeeds.rng(1, "t"), pools), fallback, "food nobody can hold: the fallback item")
	pools = _pools()
	pools["card_pool"] = [fallback.id]
	eq(generator.pick_item(null, _nothing(), RunSeeds.rng(1, "t"), pools), fallback, "food outside the card pool: the fallback item")
	var bare: RunStructure = _structure(fixtures()).duplicate()
	bare.fallback_item = null
	generator = FloorGenerator.new(fixtures(), bare, 7, 0)
	eq(generator.pick_item(null, _nothing(), RunSeeds.rng(1, "t"), _pools()), null, "neither: nothing")
	eq(generator.warnings.size(), 1, "with a warning")
	# The run: a dead party holds no food, so its unholdable list names it.
	var run := _run(content)
	for member in run.state.party:
		member["alive"] = false
	check(run._pools().get("unholdable", []).has(snack.id), "food no living member can hold is unholdable")


## F5: the armory (EQUIPMENT) gives food when no piece is left, and nothing (never the fallback item) without food.
func test_drained_armory_gives_food() -> void:
	var snack := FoodItems.food("snack")
	var content := fixtures().overlay([snack])
	var generator := FloorGenerator.new(content, _structure(content), 7, 0)
	eq(generator.pick_pickup(null, null, _nothing(), RunSeeds.rng(1, "t"), _pools(), RoomPlacement.Offers.EQUIPMENT), snack,
		"a drained armory gives food")
	generator = FloorGenerator.new(fixtures(), _structure(fixtures()), 7, 0)
	eq(generator.pick_pickup(null, null, _nothing(), RunSeeds.rng(1, "t"), _pools(), RoomPlacement.Offers.EQUIPMENT), null,
		"without food: no pickup, never the fallback item")
	eq(generator.warnings.size(), 0, "and no warning (as before)")


## F6: a named item is given even when it is held or seen.
func test_named_items_repeat() -> void:
	var whetstone: ItemDefinition = fixtures().items[&"fixture.item.whetstone"]
	var generator := FloorGenerator.new(fixtures(), _structure(fixtures()), 7, 0)
	var pools := {"party": [], "held": [whetstone.id], "seen": [whetstone.id], "seen_events": []}
	eq(generator.pick_item(whetstone, null, RunSeeds.rng(1, "t"), pools), whetstone, "a fixed pick_item")
	eq(generator.pick_pickup(whetstone, null, null, RunSeeds.rng(1, "t"), pools), whetstone, "a fixed placement")
	eq(generator.pools_drained, 0, "not a drained pick")
	var run := _run()
	run.give_item(whetstone, null, null)
	var held := run.state.holder_of(whetstone.id)
	check(held > 0, "the whetstone is held")
	run.give_item(whetstone, null, null)
	var count := 0
	for member in run.state.party:
		count += member["items"].count(whetstone.id)
	eq(count, 2, "giving it by name again gives it again")


## F6b: food standing in for drained picks repeats freely, held or seen.
func test_food_replacement_may_repeat() -> void:
	var snack := FoodItems.food("snack")
	var content := fixtures().overlay([snack])
	var generator := FloorGenerator.new(content, _structure(content), 7, 0)
	var pools := {"party": [], "held": [snack.id], "seen": [snack.id], "seen_events": []}
	for attempt in 3:
		eq(generator.pick_item(null, _nothing(), RunSeeds.rng(attempt, "t"), pools), snack, "food again (%d)" % attempt)


## The validator: the empty pool's message names food first; a chapter short of events warns.
func test_validator_messages() -> void:
	var snack := FoodItems.food("snack")
	var shrine: RoomDefinition = fixtures().rooms[SHRINE].duplicate()
	shrine.weight_x100 = 100000  # nearly every normal room an event room: far more than the two events
	var issues := ContentValidator.validate(fixtures().overlay([snack, shrine]), {"generate_seeds": 0})
	var short := issues.filter(func(issue: ValidationIssue) -> bool: return issue.code == "event_pool_short")
	check(not short.is_empty() and not short[0].is_error(), "event_pool_short is a warning")
	var plain := ContentValidator.validate(fixtures(), {"generate_seeds": 0})
	check(not plain.any(func(issue: ValidationIssue) -> bool: return issue.code == "event_pool_short"),
		"the fixtures' two events cover their floors")
	var broken := ContentValidator.validate(ContentIndex.new("res://tests/broken_fixtures/").overlay([snack]), {"generate_seeds": 0})
	var empty := broken.filter(func(issue: ValidationIssue) -> bool: return issue.code == "empty_item_pool")
	check(not empty.is_empty() and str(empty[0]).contains("food"), "empty_item_pool names food first: %s" % str(empty))


static func _hurt(run: RunController) -> void:
	for member in run.state.party:
		member["hp"] = 100


## Review fixes: a layout cell is never swapped (out of events it stays, empty); the sandbox plays the room it asked for, its
## event recorded once; a query matching no event stays an error.
func test_authored_rooms_are_not_swapped() -> void:
	var layout: FloorLayout = fixtures().layouts[&"fixture.layout.line"].duplicate(true)
	for entry in layout.cells:
		if entry.room.id == &"fixture.room.cross":
			entry.room = fixtures().rooms[SHRINE]
	var generator := FloorGenerator.new(fixtures(), _structure(fixtures()), 7, 0)
	var result := generator.from_layout(layout, _chapter(fixtures()), _pools([COIN, TOLL]))
	eq(result["error"], "", "the layout still builds")
	var shrines: Array = result["map"].cells.values().filter(func(data: Dictionary) -> bool: return data["room"] == SHRINE)
	eq(shrines.size(), 1, "the layout keeps its event room")
	eq(shrines[0]["content"]["kind"], "none", "with nothing in it (never a repeat)")
	var pools := _pools([COIN, TOLL])
	result = generator.single_room(fixtures().rooms[SHRINE], _chapter(fixtures()), pools)
	eq(result["map"].cells[0]["room"], SHRINE, "the sandbox keeps the room it asked for")
	eq(result["map"].cells[0]["content"]["kind"], "event", "and plays an event in it")
	eq(pools["seen_events"], [COIN, TOLL], "an event already seen is not recorded twice")
	var nothing: RoomDefinition = fixtures().rooms[SHRINE].duplicate()
	nothing.id = &"fixture.room.no_events"
	var query := GameplayTagQuery.new()
	query.require_all_tags.assign([&"Fixture.Event.Nothing"])
	nothing.content_query = query
	var empty_content := fixtures().overlay([nothing])
	generator = FloorGenerator.new(empty_content, _structure(fixtures()), 7, 0)
	result = generator.single_room(nothing, _chapter(fixtures()), _pools())
	eq(result["error"], "", "a query matching no event is no error (user, 2026-11-22: running out is design)")
	eq(result["map"].cells[0]["content"]["kind"], "none", "the sandbox room is empty")
	check(result["map"].cells[0].get("fallback", false), "and flagged as out of events")
	var issues := ContentValidator.validate(empty_content, {"generate_seeds": 0}).filter(
		func(issue: ValidationIssue) -> bool: return issue.code == "empty_query" and issue.path.contains("content_query"))
	check(not issues.is_empty() and not issues[0].is_error(), "the validator warns about it, not an error")


## Spec hash-id-lists: an event id holding a comma needs no shape check; it hashes differently from the two ids it joins.
func test_joined_event_ids_hash_differently() -> void:
	var split := RunState.new()
	split.seen_events.assign([COIN, TOLL])
	var joined := RunState.new()
	joined.seen_events.assign([StringName("%s,%s" % [COIN, TOLL])])
	check(split.run_hash() != joined.run_hash(), "a merged id is another hash")
	var run := _seeded_run()
	var saved: Dictionary = JSON.parse_string(WireJson.stringify(RunSnapshot.capture(run)))
	saved["run"]["seenEvents"] = ["%s,%s" % [COIN, TOLL]]
	eq(RunSnapshot.shape_problem(saved), "", "the shape check no longer looks at the ids (the hash does)")
