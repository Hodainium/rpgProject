## Seed runner (spec dev-tools 2.5): the report for many seeds (golden), one seed matches a real run's floor, rules
## can be tuned on a copy, and the tool scenes open without errors.
extends TestCase

const REPORT_GOLDEN: String = GOLDEN + "game/seed_report.json"


func test_seed_report() -> void:
	var report := SeedReport.many(fixtures(), 1, 50, 0)
	var text := WireJson.stringify(report)
	if update_goldens:
		var file := FileAccess.open(REPORT_GOLDEN, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(REPORT_GOLDEN), "the report for fixture seeds 1..50 matches its golden")
	eq(report["failures"], [], "every fixture seed generates")
	check(not report["rooms_used"].is_empty() and not report["encounters"].is_empty(), "rooms and encounters are counted")
	check(not SeedReport.text(report).is_empty(), "text()")


func test_seed_report_matches_a_run() -> void:
	for seed_value in [3, 21]:
		var run := RunController.new()
		host.add_child(run)
		run.start_run(fixtures(), [&"fixture.character.knight"], str(seed_value))
		var shown: FloorMap = SeedReport.floor_of(fixtures(), seed_value, 0)["map"]
		for index in run.state.map.sorted_indices():
			eq(shown.cells[index]["room"], run.state.map.cells[index]["room"], "seed %d cell %d: same room as the run" % [seed_value, index])
		run.free()
	var second := SeedReport.floor_of(fixtures(), 3, 1)
	eq(second["error"], "", "floor 1 is generated after floor 0")


func test_seed_report_rules_copy() -> void:
	var chapter: ChapterDefinition = fixtures().runs.values()[0].floors[0].chapters[0]
	var rules: FloorGenRules = chapter.floor_gen_rules.duplicate()
	rules.base_rooms = 2
	rules.random_extra_rooms = 0
	rules.rooms_per_depth = 0
	var tuned := SeedReport.many(fixtures(), 1, 5, 0, rules)
	check(tuned["rooms"].get("max", 99) <= 3 or not tuned["failures"].is_empty(), "the tuned copy is used")
	check(chapter.floor_gen_rules.base_rooms != 2, "the original rules are untouched")


func test_dev_tool_scenes() -> void:
	for path in ["res://game/dev/seed_runner.tscn", "res://game/dev/play_main.tscn"]:
		var scene: Node = load(path).instantiate()
		host.add_child(scene)
		for frame in 10:
			await host.get_tree().process_frame
		check(is_instance_valid(scene) and scene.get_script() != null and scene.get_script().can_instantiate(),
			"%s opens with its script" % path)
		scene.free()
