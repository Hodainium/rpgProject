## Floor generation (spec 3.2, 3.3): determinism, Isaac rules over many seeds, pools, layouts, failure messages.
extends TestCase

const GAME_GOLDEN: String = GOLDEN + "game/"


func _generator(seed_value: int, depth: int = 0) -> FloorGenerator:
	var content := fixtures()
	return FloorGenerator.new(content, content.runs.values()[0], seed_value, depth)


func _pools() -> Dictionary:
	return {"party": [&"fixture.character.knight"], "held": [], "seen": []}


func _chapter(name: String) -> ChapterDefinition:
	return fixtures().chapters[StringName("fixture.chapter." + name)]


func _map_hash(map: FloorMap) -> String:
	return StateHasher.sha256_hex("\n".join(map.canonical_lines()))


func test_seed_derive_golden() -> void:
	var cases := {"1|floor/0/layout": RunSeeds.derive(1, "floor/0/layout"),
		"42|a": RunSeeds.derive(42, "a"),
		"9223372036854775807|floor/3/combat/40": RunSeeds.derive(9223372036854775807, "floor/3/combat/40")}
	var text := WireJson.stringify({"derive": cases})
	if update_goldens:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GAME_GOLDEN))
		_write(GAME_GOLDEN + "seed_derive.json", text)
	eq(text, FileAccess.get_file_as_string(GAME_GOLDEN + "seed_derive.json"), "seed derivation matches its golden")
	for key in cases:
		check(cases[key] >= 0, "%s derives a non-negative seed" % key)
	check(RunSeeds.derive(1, "a") != RunSeeds.derive(1, "b"), "labels give independent streams")


func test_generation_deterministic_and_golden() -> void:
	for seed_value in [7, 123456789]:
		var first: Dictionary = _generator(seed_value).generate(_chapter("a"), false, _pools())
		var second: Dictionary = _generator(seed_value).generate(_chapter("a"), false, _pools())
		eq(first["error"], "", "seed %d generates" % seed_value)
		if first["map"] == null:
			continue
		eq(_map_hash(second["map"]), _map_hash(first["map"]), "seed %d: same map twice" % seed_value)
		var path := GAME_GOLDEN + "floor_%d.txt" % seed_value
		var text := "\n".join(first["map"].canonical_lines())
		if update_goldens:
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GAME_GOLDEN))
			_write(path, text)
		eq(text, FileAccess.get_file_as_string(path), "seed %d matches its golden map" % seed_value)


func test_generation_rules_over_many_seeds() -> void:
	var rules: FloorGenRules = _chapter("a").floor_gen_rules
	for seed_value in 200:
		var depth := seed_value % 2
		var result: Dictionary = _generator(seed_value, depth).generate(_chapter("a"), false, _pools())
		if result["error"] != "":
			failures.append("seed %d: %s" % [seed_value, result["error"]])
			continue
		var map: FloorMap = result["map"]
		var count := map.cells.size()
		var low := rules.base_rooms + rules.rooms_per_depth * depth
		check(count >= low and count <= mini(rules.max_rooms, low + rules.random_extra_rooms), "seed %d: %d rooms" % [seed_value, count])
		eq(map.cell_of(map.start), Vector2i(rules.grid_size.x / 2, rules.grid_size.y / 2), "seed %d start at the centre" % seed_value)
		eq(map.distances().size(), count, "seed %d connected" % seed_value)
		var distances := map.distances()
		var specials := 0
		for index in map.sorted_indices():
			var data: Dictionary = map.cells[index]
			var neighbours := map.neighbours(index).size()
			if data["role"] in [FloorMap.ROLE_BOSS, FloorMap.ROLE_SPECIAL]:
				eq(neighbours, 1, "seed %d: %s room on a dead end" % [seed_value, data["role"]])
			if data["role"] == FloorMap.ROLE_SPECIAL:
				specials += 1
			if index != map.start and neighbours == 1:
				check(distances[index] <= distances[map.boss], "seed %d: boss is the farthest dead end" % seed_value)
			var room: RoomDefinition = fixtures().rooms[data["room"]]
			check(room.fits(data["doors"]), "seed %d: room %s fits doors %d" % [seed_value, room.id, data["doors"]])
		eq(specials, rules.special_room_tags.size(), "seed %d: every special room placed once" % seed_value)


func test_generation_pools() -> void:
	for seed_value in 30:
		var map: FloorMap = _generator(seed_value).generate(_chapter("b"), false, _pools())["map"]
		for index in map.sorted_indices():
			var room: RoomDefinition = fixtures().rooms[map.cells[index]["room"]]
			check(TagMatch.has(room.tags, &"Fixture.Chapter.B"), "chapter B uses B rooms only, got %s" % room.id)
	var seen_a_only := false
	for seed_value in 60:
		var map: FloorMap = _generator(seed_value).generate(_chapter("b"), true, _pools())["map"]
		for index in map.sorted_indices():
			var room: RoomDefinition = fixtures().rooms[map.cells[index]["room"]]
			if not TagMatch.has(room.tags, &"Fixture.Chapter.B"):
				seen_a_only = true
	check(seen_a_only, "Delirium mode draws rooms from chapter A into chapter B floors")


func test_streams_independent_of_exploration_order() -> void:
	var a := start_run(host, "99")
	var b := start_run(host, "99")
	var map: FloorMap = a.state.map
	var reachable := []
	for index in map.neighbours(map.start):
		reachable.append(index)
	check(reachable.size() >= 1, "the start has a neighbour")
	for index in reachable:
		eq(_map_hash(b.state.map), _map_hash(a.state.map), "same seed, same floor")
	a.pending_battle = {"cell": reachable[0], "encounter": &"x", "enemies": [], "label": ""}
	b.pending_battle = a.pending_battle.duplicate()
	eq(b.battle_snapshot()["seed"], a.battle_snapshot()["seed"], "a room's battle seed does not depend on what was visited")
	a.queue_free()
	b.queue_free()


func test_layout_load_and_validation() -> void:
	var layout: FloorLayout = fixtures().layouts[&"fixture.layout.line"]
	var result: Dictionary = _generator(5).from_layout(layout, _chapter("a"), _pools())
	eq(result["error"], "", "the fixture layout loads")
	if result["map"] != null:
		eq(result["map"].cells.size(), 4, "every layout cell is on the map")
		eq(result["map"].cells[result["map"].boss]["content"]["kind"], "encounter", "query rooms still get content")
	var broken: FloorLayout = layout.duplicate()
	broken.cells = [layout.cells[0], layout.cells[3]]
	broken.cells[1] = layout.cells[3].duplicate()
	broken.cells[1].cell = Vector2i(7, 7)
	check(_generator(5).from_layout(broken, _chapter("a"), _pools())["error"].contains("not every cell is connected"),
		"a disconnected layout is refused")
	var outside: FloorLayout = layout.duplicate()
	outside.cells = layout.cells.duplicate()
	outside.cells[1] = layout.cells[1].duplicate()
	outside.cells[1].cell = Vector2i(20, 4)
	check(_generator(5).from_layout(outside, _chapter("a"), _pools())["error"].contains("outside"), "a cell outside the grid is refused")


func test_generation_failures_name_the_problem() -> void:
	var chapter: ChapterDefinition = _chapter("a").duplicate()
	chapter.room_query = GameplayTagQuery.new()
	chapter.room_query.require_all_tags.assign([&"Fixture.Chapter.Nowhere"])
	var result: Dictionary = _generator(1).generate(chapter, false, _pools())
	check(result["error"].contains("no room for cell"), "no candidates names the cell: %s" % result["error"])
	var rules: FloorGenRules = chapter.floor_gen_rules.duplicate()
	# A new array: duplicate() shares Array properties, and assign() would change the cached fixture rules.
	var too_many: Array[StringName] = [&"A", &"B", &"C", &"D", &"E", &"F", &"G", &"H", &"I", &"J"]
	rules.special_room_tags = too_many
	rules.max_attempts = 5
	chapter.floor_gen_rules = rules
	chapter.room_query = _chapter("a").room_query
	result = _generator(1).generate(chapter, false, _pools())
	check(result["error"].contains("after 5 attempts"), "exhausted attempts names the rules: %s" % result["error"])


func test_seed_parse() -> void:
	eq(RunSeeds.parse("42"), 42, "a plain number")
	eq(RunSeeds.parse("9223372036854775807"), 9223372036854775807, "the largest int64")
	for bad in ["", "-1", "+1", "abc", "9223372036854775808", "1.5"]:
		eq(RunSeeds.parse(bad), -1, "'%s' is refused" % bad)


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
