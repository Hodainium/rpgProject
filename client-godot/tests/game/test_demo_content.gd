## Smoke test for the example set (spec game-skeleton 3.8): res://content/ loads with no problems, a run starts, and its
## floor generates for 50 seeds. It never checks balance, so tuning can't fail it; it is skipped when content/demo/ is
## absent (deleted, or build_demo not run yet).
extends TestCase

const DEMO: String = "res://content/demo/"


func test_demo_content() -> void:
	if not DirAccess.dir_exists_absolute(DEMO) or not DirAccess.dir_exists_absolute(DEMO + "runs"):
		print("    skipped: no example set under ", DEMO)
		return
	var content := ContentIndex.new("res://content/")
	eq(Array(content.problems), [], "the content root loads cleanly")
	eq(content.runs.size(), 1, "one RunStructure")
	if content.runs.size() != 1 or not content.problems.is_empty():
		return
	var structure: RunStructure = content.runs.values()[0]
	var party: Array = []
	for id in content.characters:
		if party.size() < 4 and content.characters[id].selectable:
			party.append(String(id))
	var run := RunController.new()
	host.add_child(run)
	eq(run.start_run(content, party, "1"), "", "a run starts on the example set")
	run.free()
	for seed_value in 50:
		var chapter: ChapterDefinition = structure.floors[0].chapters[0]
		var generator := FloorGenerator.new(content, structure, seed_value, 0)
		var result: Dictionary = generator.generate(chapter, false, {"party": [], "held": [], "seen": []})
		eq(result["error"], "", "seed %d generates" % seed_value)
