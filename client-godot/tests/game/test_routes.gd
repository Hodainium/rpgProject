## Spec playable-demo 3.8: route choice at the stairs (CHOICE and ROUTE floor slots), boss rotation within a chapter,
## and pickups paid with a curse item. Fixtures only; changed content lives in memory (ContentIndex.overlay).
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]

var _runs: Array[RunController] = []


func after_each() -> void:
	for run in _runs:
		if is_instance_valid(run):
			run.free()
	_runs.clear()
	super()


static func _chapter(id: String, route: StringName) -> ChapterDefinition:
	var chapter: ChapterDefinition = fixtures().chapters[&"fixture.chapter.a"].duplicate()
	chapter.id = StringName(id)
	chapter.route_tag = route
	return chapter


static func _slot(chapters: Array, pick: FloorSlot.Pick) -> FloorSlot:
	var slot := FloorSlot.new()
	slot.chapters.assign(chapters)
	slot.pick = pick
	return slot


## Floors: fixture chapter A, then a choice of light or dark, then the matching route.
static func _routed() -> Array:
	var light_9 := _chapter("fixture.chapter.light_9", &"Route.Light")
	var dark_9 := _chapter("fixture.chapter.dark_9", &"Route.Dark")
	var light_10 := _chapter("fixture.chapter.light_10", &"Route.Light")
	var dark_10 := _chapter("fixture.chapter.dark_10", &"Route.Dark")
	var base: RunStructure = fixtures().runs.values()[0]
	var run: RunStructure = base.duplicate()
	run.floors = [_slot([fixtures().chapters[&"fixture.chapter.a"]], FloorSlot.Pick.RANDOM),
		_slot([light_9, dark_9], FloorSlot.Pick.CHOICE), _slot([light_10, dark_10], FloorSlot.Pick.ROUTE)] as Array[FloorSlot]
	return [fixtures().overlay([light_9, dark_9, light_10, dark_10, run]), run]


func _start(content: ContentIndex, seed_text: String = "7") -> RunController:
	var run := RunController.new()
	host.add_child(run)
	_runs.append(run)
	eq(run.start_run(content, PARTY, seed_text), "", "the run starts")
	return run


func test_route_choice_and_follow() -> void:
	var setup := _routed()
	var run := _start(setup[0])
	run.state.boss_cleared = true
	eq(run.next_floor_choices().map(func(chapter): return chapter.id), [&"fixture.chapter.light_9", &"fixture.chapter.dark_9"],
		"the stairs offer both routes")
	check(run.next_floor().begins_with("pick the next floor"), "a choice floor needs a pick")
	eq(run.state.floor_index, 0, "and nothing moves without one")
	eq(run.next_floor(&"fixture.chapter.dark_9"), "", "the dark route")
	eq(run.state.chapter_id, &"fixture.chapter.dark_9", "floor 2 is the chosen chapter")
	var entries := run.run_log.filter(func(entry) -> bool: return entry["type"] == "next_floor")
	eq(entries.back().get("chapter"), "fixture.chapter.dark_9", "the choice is logged")
	run.state.boss_cleared = true
	eq(run.next_floor_choices(), [], "a route floor is no choice")
	eq(run.next_floor(), "", "on to the last floor")
	eq(run.state.chapter_id, &"fixture.chapter.dark_10", "the route floor follows the dark route")
	var last_step: Dictionary = run.run_log.filter(func(entry) -> bool: return entry["type"] == "next_floor").back()
	check(not last_step.has("chapter"), "no pick logged on a route floor")
	# Same seed, the light route: floor 3 follows it.
	var light := _start(setup[0])
	light.state.boss_cleared = true
	light.next_floor(&"fixture.chapter.light_9")
	light.state.boss_cleared = true
	light.next_floor()
	eq(light.state.chapter_id, &"fixture.chapter.light_10", "the route floor follows the light route")
	# The seed report follows a given route, and RunPlayer picks one from its own stream.
	eq(SeedReport.floor_of(setup[0], 7, 2, null, setup[1].id, &"fixture.chapter.dark_9")["chapter"], &"fixture.chapter.dark_10",
		"the seed report follows --route")
	eq(SeedReport.floor_of(setup[0], 7, 2, null, setup[1].id)["chapter"], &"fixture.chapter.light_10",
		"without --route the first chapter of a choice")
	var played := _start(setup[0], "3")
	await RunPlayer.play(played)
	check(played.state.floor_index == 2 or played.state.status == RunState.LOST, "RunPlayer takes the stairs through the choice")


func test_dev_stage_on_route_floors() -> void:
	var setup := _routed()
	var run := _start(setup[0])
	eq(run.dev_stage(2), "", "stage onto a route floor from off-route falls back to its first chapter")
	eq(run.state.chapter_id, &"fixture.chapter.light_10", "the first chapter")
	eq(run.dev_stage(1, &"fixture.chapter.dark_9"), "", "stage onto a choice floor with a chapter")
	eq(run.state.chapter_id, &"fixture.chapter.dark_9", "the named chapter")


func test_boss_rotation() -> void:
	var rotating: ChapterDefinition = fixtures().chapters[&"fixture.chapter.a"].duplicate()
	rotating.boss_rotation = true
	var second_boss: EncounterDefinition = fixtures().encounters[&"fixture.encounter.boss"].duplicate(true)
	second_boss.id = &"fixture.encounter.boss_two"
	var base: RunStructure = fixtures().runs.values()[0]
	var run: RunStructure = base.duplicate()
	run.floors = [_slot([rotating], FloorSlot.Pick.RANDOM), _slot([rotating], FloorSlot.Pick.RANDOM)] as Array[FloorSlot]
	var content := fixtures().overlay([rotating, second_boss, run])
	var firsts := {}
	for seed_value in range(1, 31):
		var a := FloorGenerator.new(content, run, seed_value, 0).rotated_boss(rotating)
		var b := FloorGenerator.new(content, run, seed_value, 1).rotated_boss(rotating)
		check(a != null and b != null and a.id != b.id, "seed %d: the chapter's two floors meet different bosses" % seed_value)
		firsts[a.id] = true
		eq(FloorGenerator.new(content, run, seed_value, 0).rotated_boss(rotating), a, "seed %d: the same pick again" % seed_value)
	eq(firsts.size(), 2, "each boss opens the chapter on some seeds")
	# Off by default: the fixture chapter picks as before.
	check(not fixtures().chapters[&"fixture.chapter.a"].boss_rotation, "rotation is off unless set")


## A treasure-room copy whose pedestal costs a curse item (−10% max HP, FREE stacking).
static func _priced_content() -> Array:
	var curse := ItemDefinition.new()
	curse.id = &"fixture.item.scar"
	curse.display_name = "Scar"
	var drain := GameplayEffect.new()
	drain.policy = GameplayEffect.DurationPolicy.INFINITE
	var modifier := CombatModifier.new()
	modifier.attribute_name = "max_hp"
	modifier.operation = GameplayEffectModifier.Operation.PERCENT_ADD
	modifier.value_x100 = Fixed.from_typed(-10)
	drain.modifiers.append(modifier)
	var grants := AbilitySet.new()
	grants.effects.append(drain)
	curse.grants = grants
	return [curse]


func test_price_item_pickups() -> void:
	var curse: ItemDefinition = _priced_content()[0]
	var content := fixtures().overlay([curse])
	var run := _start(content)
	var cell := run.state.current_cell
	var item: StringName = fixtures().items.keys().filter(func(id) -> bool:
		return not fixtures().items[id].is_usable() and id != &"fixture.item.crumb")[0]
	var entries: Array = [FloorGenerator.pickup_entry(1, fixtures().items[item], 0),
		FloorGenerator.pickup_entry(2, fixtures().items[item], 0)]
	for entry in entries:
		entry["priceItem"] = curse.id
	run.state.map.cells[cell]["pickups"] = entries
	run.state.map.cells[cell]["cleared"] = true
	var lines_before := "\n".join(run.state.map.canonical_lines())
	check(lines_before.contains("priceItem=fixture.item.scar"), "a priced pickup's price item is part of the map hash")
	var max_before := int(run.party_stats()[1][BattleUnit.MAX_HP])
	eq(run.take(1, 1), "", "take the first priced pickup")
	eq(run.take(2, 1), "", "and the second")
	eq(run.state.member(1)["items"].count(curse.id), 2, "the taker holds two curses")
	eq(run.run_log.back()["type"], "buy", "a priced pickup is logged as a buy")
	eq(run.state.coins, 0, "no coins were spent")
	var max_after := int(run.party_stats()[1][BattleUnit.MAX_HP])
	check(max_after < max_before, "the curses lower max HP (%d → %d)" % [max_before, max_after])
	check(max_before - max_after >= int(max_before * 0.19), "both copies count (about 20%)")
