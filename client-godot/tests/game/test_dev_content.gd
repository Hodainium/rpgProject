## Content creation (spec dev-tools 2.2-2.4, 3.5, 3.8): templates, room grid operations, Play requests and the sandbox.
## Fixtures and user:// only.
extends TestCase

const SCRATCH: String = "user://test_dev_content/"
const SANDBOX_GOLDEN: String = GOLDEN + "game/sandbox_room.json"
const PARTY: Array = [&"fixture.character.knight", &"fixture.character.medic"]


func _sandbox(room_name: String, seed_value: int = 7) -> RunController:
	var request := SandboxRequest.new()
	request.party = PARTY
	request.seed = seed_value
	request.room = fixtures().rooms[StringName("fixture.room." + room_name)]
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_sandbox(fixtures(), request), "", "sandbox %s starts" % room_name)
	return run


func test_content_templates() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var content := fixtures()
	for type in ContentTemplates.TYPES:
		var id := "test.%s.new_%s" % [type, type]
		var path := SCRATCH + "new_%s.tres" % type
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		var result := ContentTemplates.save_new(type, id, SCRATCH, content)
		eq(result["error"], "", "%s template saves" % type)
		if result["error"] != "":
			continue
		var loaded := ResourceLoader.load(result["path"], "", ResourceLoader.CACHE_MODE_IGNORE)
		if "id" in loaded:  # animation sets have no id: their file is their name
			eq(String(loaded.get("id")), id, "%s keeps its id" % type)
		else:
			check(loaded is UnitAnimationSet, "%s is the only template without an id" % type)
		eq(ContentTemplates.save_new(type, id, SCRATCH, content)["error"].contains("already exists"), true,
			"%s: an existing file is refused" % type)
	var character: CharacterDefinition = ResourceLoader.load(SCRATCH + "new_character.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	eq(character.attribute_set, ContentTemplates.common_attribute_set(content), "the attribute set most units use")
	var expected := ContentTemplates.stats_of(character.attribute_set)
	check(not expected.is_empty(), "the attribute set has attributes")
	eq(character.stats_x100.keys().size(), expected.keys().size(), "every attribute is pre-filled")
	var room: RoomDefinition = ResourceLoader.load(SCRATCH + "new_room.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	eq(room.doors, 15, "a new room has all four doors")
	eq(room.placements.size(), 4, "and four player spawns")
	eq(ContentTemplates.save_new("room", "fixture.room.cross", SCRATCH, content)["error"].contains("already used"), true,
		"an id already in the content is refused")
	eq(ContentTemplates.save_new("nope", "x", SCRATCH, content)["error"].contains("unknown type"), true, "unknown type")
	eq(ContentTemplates.display_name_of("demo.enemy.big_slime"), "Big Slime", "display name from the id")


func test_room_grid_ops() -> void:
	var room: RoomDefinition = fixtures().rooms[&"fixture.room.vault"].duplicate(true)
	var before := room.placements.size()
	RoomGridOps.paint(room, Vector2i(2, 2), RoomPlacement.Kind.ENEMY_SPAWN, 2)
	eq(room.placements.size(), before + 1, "paint adds a placement")
	eq(RoomGridOps.label(room.placements[RoomGridOps.placement_at(room, Vector2i(2, 2))]), "E2", "enemy spawn 2")
	RoomGridOps.paint(room, Vector2i(2, 2), RoomPlacement.Kind.PLAYER_SPAWN, 1)
	eq(room.placements.size(), before + 1, "painting another kind replaces")
	eq(room.placements[RoomGridOps.placement_at(room, Vector2i(2, 2))].kind, RoomPlacement.Kind.PLAYER_SPAWN, "replaced kind")
	RoomGridOps.paint(room, Vector2i(20, 2), RoomPlacement.Kind.PLAYER_SPAWN, 1)
	eq(room.placements.size(), before + 1, "outside the grid does nothing")
	var original := room.placements.duplicate()
	var result := RoomGridOps.paint_result(room, Vector2i(5, 5), RoomPlacement.Kind.SHOP_SLOT, 1)
	eq(room.placements, original, "paint_result leaves the room alone (undo-able)")
	eq(result.size(), original.size() + 1, "paint_result has the new placement")
	RoomGridOps.erase(room, Vector2i(2, 2))
	eq(room.placements.size(), before, "erase removes it")
	var doors := room.doors
	RoomGridOps.toggle_door(room, RoomDefinition.DOOR_N)
	eq(room.doors, doors ^ RoomDefinition.DOOR_N, "toggle the north door")
	eq(ContentValidator.error_count(ContentValidator.check_room(room, fixtures())), 0, "the edited room is still valid")
	check(RoomGridOps.text(room).split("\n").size() == RoomDefinition.GRID.y + 2, "text() draws the grid with walls")


func test_play_request() -> void:
	var play := {"party": [], "seed": "7", "depth": 0, "chapter": "", "content_root": FIXTURES, "folders": {}}
	var room := PlayRequest.build(fixtures(), "room", "fixture.room.cross", play)
	eq(room["error"], "", "play a room")
	eq(room["sandbox"].room.id, &"fixture.room.cross", "the room itself")
	eq(room["sandbox"].party.size(), 2, "default party: the first two selectable characters")
	var encounter := PlayRequest.build(fixtures(), "encounter", fixtures().encounters.keys()[0], play)
	eq(encounter["error"], "", "play an encounter")
	check(encounter["sandbox"].room != null and encounter["sandbox"].encounter != null, "in a battle room, as override")
	var enemy := PlayRequest.build(fixtures(), "enemy", "fixture.enemy.grunt", play)
	eq(enemy["error"], "", "play an enemy")
	eq(enemy["sandbox"].encounter.slots.size(), 1, "a one-slot encounter built in memory")
	var character := PlayRequest.build(fixtures(), "character", "fixture.character.rogue", play)
	eq(character["run"]["party"][0], &"fixture.character.rogue", "the character goes in slot 1")
	var layout := PlayRequest.build(fixtures(), "layout", fixtures().layouts.keys()[0], play)
	check(layout["sandbox"].layout != null, "play a layout")
	var by_path := PlayRequest.build(fixtures(), "room", FIXTURES + "rooms/vault.tres", play)
	eq(by_path["sandbox"].room.id, &"fixture.room.vault", "by path")
	check(PlayRequest.build(fixtures(), "room", "nope", play)["error"] != "", "unknown id")
	check(PlayRequest.build(fixtures(), "enemy", "fixture.character.knight", play)["error"] != "", "a character is not an enemy")
	# The request file is consumed once.
	PlayRequest.write("room", "fixture.room.cross")
	eq(PlayRequest.take(), {"kind": "room", "target": "fixture.room.cross"}, "take() reads the request")
	eq(PlayRequest.take(), {}, "and deletes it")


func test_sandbox_room() -> void:
	var results := {}
	for name in ["cross", "throne", "shrine", "market", "vault"]:
		var run := _sandbox(name)
		check(run.state.sandbox and run.state.dev, "%s: a sandbox run is marked" % name)
		eq(run.state.map.cells.size(), 1, "%s: one room" % name)
		if name in ["cross", "throne"]:
			check(not run.pending_battle.is_empty(), "%s: the battle starts at once" % name)
			await run.fight(ScriptedController.new())
		if name == "throne":
			check(run.state.boss_cleared or run.state.status == RunState.LOST, "the boss room resolves the boss query and fights")
			eq(run.state.status != RunState.WON, true, "a sandbox boss never ends the run as won")
		if name == "shrine":
			check(not run.state.event.is_empty(), "shrine: the event shows")
		if name == "market":
			check(run.state.map.cells[0]["cleared"] and not run.state.map.cells[0]["pickups"].is_empty(), "market: stock is on sale")
		eq(run.next_floor(), "the next floor is not open", "%s: no next floor in a sandbox" % name)
		results[name] = run.state.run_hash()
		run.free()
	var text := WireJson.stringify({"sandbox_seed_7": results})
	if update_goldens:
		var file := FileAccess.open(SANDBOX_GOLDEN, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(SANDBOX_GOLDEN), "sandbox runs match their golden")
	var again := _sandbox("cross")
	await again.fight(ScriptedController.new())
	eq(again.state.run_hash(), results["cross"], "a sandbox is deterministic")
	again.free()


func test_sandbox_unsaved_room() -> void:
	var room: RoomDefinition = fixtures().rooms[&"fixture.room.vault"].duplicate(true)
	room.id = &"test.room.unsaved"
	var request := SandboxRequest.new()
	request.party = PARTY
	request.room = room
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_sandbox(fixtures(), request), "", "an unsaved room plays from memory")
	check(not fixtures().rooms.has(&"test.room.unsaved"), "the shared content index is untouched")
	run.free()


func test_sandbox_layout() -> void:
	var request := SandboxRequest.new()
	request.party = PARTY
	request.layout = fixtures().layouts.values()[0]
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_sandbox(fixtures(), request), "", "a layout plays as floor 0")
	eq(run.state.map.cells.size(), request.layout.cells.size(), "with all its rooms")
	check(run.state.map.cells[run.state.map.start]["cleared"], "its start is cleared like a real floor")
	run.free()


func test_check_layout() -> void:
	var layout: FloorLayout = fixtures().layouts.values()[0]
	eq(FloorGenerator.check_layout(layout), "", "the fixture layout is valid")
	var broken: FloorLayout = layout.duplicate(true)
	broken.cells[0].role = FloorLayoutCell.Role.BOSS
	check(FloorGenerator.check_layout(broken) != "", "two bosses are refused")


## Dev items are loaded beside the content but never picked by a pool, so generation is unchanged (spec dev-tools 3.3).
func test_dev_items_never_pooled() -> void:
	var with_dev := fixtures().overlay([])
	with_dev.add_root(RunController.DEV_CONTENT)
	check(with_dev.items.has(&"dev.up.atk"), "the dev stat items are loaded")
	var structure: RunStructure = fixtures().runs.values()[0]
	var chapter: ChapterDefinition = structure.floors[0].chapters[0]
	for seed_value in range(1, 21):
		var plain := FloorGenerator.new(fixtures(), structure, seed_value, 0).generate(chapter, false, {"party": [], "held": [], "seen": []})
		var dev := FloorGenerator.new(with_dev, structure, seed_value, 0).generate(chapter, false, {"party": [], "held": [], "seen": []})
		eq(dev["map"].canonical_lines(), plain["map"].canonical_lines(), "seed %d: the same floor with dev content loaded" % seed_value)
	# A pool that matches everything (null query) still never picks one.
	var stream := RunSeeds.rng(1, "test/pool")
	var generator := FloorGenerator.new(with_dev, structure, 1, 0)
	for draw in 200:
		var item := generator.pick_item(null, null, stream, {"party": [], "held": [], "seen": []})
		check(item == null or not TagMatch.has(item.tags, FloorGenerator.DEV_TAG), "draw %d is not a dev item" % draw)
