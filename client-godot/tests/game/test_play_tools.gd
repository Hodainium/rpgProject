## Spec playable-demo: the run picker (2.2), run_summary() (3.1), the play report and `autorun` (2.3). Fixtures only;
## a second run lives in memory (ContentIndex.overlay), never on disk.
extends TestCase

const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]

var _nodes: Array[Node] = []


func after_each() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	super()


## The fixtures plus a copy of their run under `id` (default_run as given).
static func _two_runs(id: String, default_run: bool) -> ContentIndex:
	var base: RunStructure = fixtures().runs.values()[0]
	var second: RunStructure = base.duplicate()
	second.id = StringName(id)
	second.default_run = default_run
	return fixtures().overlay([second])


func _run_on(content: ContentIndex, run_id: StringName = &"", seed_text: String = "7") -> Array:
	var run := RunController.new()
	host.add_child(run)
	_nodes.append(run)
	return [run, run.start_run(content, PARTY, seed_text, run_id)]


func test_run_picker() -> void:
	var only: RunStructure = fixtures().runs.values()[0]
	eq(RunController.pick_run(fixtures())["run"], only, "one run: it is picked")
	var single := _run_on(fixtures())
	eq(single[1], "", "one run starts without an id")
	check(not single[0].run_log[0].has("run"), "one run: the start_run entry has no run field (old logs unchanged)")

	var undecided := _two_runs("fixture.run.second", false)
	var refused := _run_on(undecided)
	check(str(refused[1]).contains("several runs and none is default"), "two runs, none default: refused: " + str(refused[1]))
	check(refused[0].state == null, "the refused run never starts")
	var named := _run_on(undecided, &"fixture.run.second")
	eq(named[1], "", "a named run starts")
	eq(named[0].state.run_structure_id, &"fixture.run.second", "the named run is played")
	eq(named[0].run_log[0].get("run"), "fixture.run.second", "with several runs the start_run entry names the run")
	check(str(_run_on(undecided, &"fixture.run.nope")[1]).contains("unknown run 'fixture.run.nope'"), "an unknown id is refused")

	var decided := _two_runs("fixture.run.second", true)
	var picked := _run_on(decided)
	eq(picked[1], "", "two runs, one default: starts without an id")
	eq(picked[0].state.run_structure_id, &"fixture.run.second", "the default run is picked")
	eq(RunController.pick_run(undecided, &"", true)["run"].id, &"fixture.run.second", "lenient (sandbox): the first id, sorted")


## Same seed and party, one run vs the same run named among two: same run hash apart from the log's run field.
func test_run_picker_keeps_hash() -> void:
	var alone := _run_on(fixtures())
	var among := _run_on(_two_runs("fixture.run.zzz", false), fixtures().runs.keys()[0])
	eq(among[0].state.run_hash(), alone[0].state.run_hash(), "naming the run doesn't change the run hash")


func test_new_command_run_id() -> void:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_nodes.append(game)
	game.content_root = FIXTURES
	game.load_content()
	game.content = _two_runs("fixture.run.second", false)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)  # built-ins only: user://dev_commands/ is shared with parallel shards
	console.attach(game)
	var listed := game.runs()
	eq(listed.size(), 2, "GameMain.runs() lists both")
	check(listed.all(func(entry: Dictionary) -> bool: return not entry["default"]), "neither is default")
	var refused: Dictionary = await console.execute("new " + ",".join(PARTY) + " 7")
	check(not refused["ok"], "new without run= is refused when no run is default")
	var started: Dictionary = await console.execute("new " + ",".join(PARTY) + " 7 run=fixture.run.second")
	check(started["ok"], "new ... run=<id> starts it: " + started["text"])
	eq(game.run.state.run_structure_id, &"fixture.run.second", "the named run is played")
	var again: Dictionary = await console.execute("seed 8")
	check(again["ok"], "seed restarts: " + again["text"])
	eq(game.run.state.run_structure_id, &"fixture.run.second", "seed keeps the run")
	var bad: Dictionary = await console.execute("new " + ",".join(PARTY) + " 7 run=fixture.run.nope")
	check(not bad["ok"] and bad["text"].contains("unknown run"), "an unknown run= is refused: " + bad["text"])


## run_summary() counts agree with the run log of a whole scripted run.
func test_run_summary() -> void:
	var run := start_run(host, "7")
	_nodes.append(run)
	await RunPlayer.play(run)
	var summary := run.run_summary()
	var won := 0
	var lost := 0
	var choices := 0
	for entry in run.run_log:
		if entry["type"] == "battle":
			if entry["outcome"] == Battle.VICTORY:
				won += 1
			else:
				lost += 1
		elif entry["type"] == "choose":
			choices += 1
	eq(summary["status"], run.state.status, "status")
	eq(summary["battlesWon"], won, "battles won")
	eq(summary["battlesLost"], lost, "battles lost")
	eq(summary["eventChoices"], choices, "event choices")
	eq(summary["seed"], RunSeeds.display(7), "seed code")
	eq(summary["floorReached"], run.state.floor_index + 1, "floor reached")
	check(summary["enemiesDefeated"] >= won, "at least one enemy per battle won")
	eq(summary["coins"], summary["coinsEarned"] - summary["coinsSpent"], "coins = earned - spent (a run starts with 0)")
	if run.state.status == RunState.LOST:
		check(summary["endedIn"]["encounter"] != "", "a lost run names the encounter it ended in")


const PLAY_GOLDEN: String = GOLDEN + "game/seed_report_play.json"


static func _read_missing(values: Dictionary) -> Variant:
	return values.nope


## A script error while a seed plays goes into that seed's record and the report's "errors" (and its text), also
## through a shard merge; a clean report has none. The error comes from a message listener on the first floor of seed 2.
func test_play_report_counts_errors() -> void:
	var armed := [false]  # [armed]: the next floor entered raises one error, then disarms
	var handle := GameplayMessages.listen(GameplayMessageRouter.RUN_FLOOR_ENTERED, func(_channel, _message):
		if armed[0]:
			armed[0] = false
			_read_missing({}))
	expect_error("Invalid access to property or key 'nope'")
	var clean := await PlayReport.many(fixtures(), host, 1, 1, {"party": PARTY})
	armed[0] = true
	var report := await PlayReport.many(fixtures(), host, 2, 1, {"party": PARTY}, true)
	handle.unregister()
	eq(clean["errors"], [], "a clean report has no errors")
	eq(report["errors"].size(), 1, "one error in seed 2")
	check(not report["errors"].is_empty() and report["errors"][0]["seed"] == 2
		and report["errors"][0]["error"].contains("'nope'"), "attributed to seed 2: %s" % [report["errors"]])
	check(PlayReport.text(report).contains("script or engine errors: 1"), "the text says so")
	var merged := PlayReport.merge([{"options": report["options"], "records": report["records"]}])
	eq(merged["errors"], report["errors"], "a merged report keeps them")


## Spec playable-demo 2.3: the auto policy over fixture seeds, deterministic, pinned by a golden.
func test_seed_report_play() -> void:
	var options := {"party": PARTY, "check": true}
	var report := await PlayReport.many(fixtures(), host, 1, 5, options)
	var again := await PlayReport.many(fixtures(), host, 1, 5, options)
	eq(report["failures"], [], "no failing battle")
	report.erase("failures")
	again.erase("failures")
	var text := WireJson.stringify(report)
	eq(WireJson.stringify(again), text, "the same seeds give the same report")
	if update_goldens:
		var file := FileAccess.open(PLAY_GOLDEN, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	eq(text, FileAccess.get_file_as_string(PLAY_GOLDEN), "the play report for fixture seeds 1..5 matches its golden")
	eq(report["won"] + report["lost"] + report["stopped"], 5, "every seed is counted once")
	eq(report["stopped"], 0, "no run stops on a runner error, a dead end or the step cap")
	eq(report["violations"], [], "auto play with checks: no violation (invariants, record → replay)")
	check(not report["turnsPerBattle"].is_empty(), "turns per encounter are recorded")
	check(not PlayReport.text(report).is_empty(), "text()")
	# The policy is the scripted run's: seed 7 played here ends like test_run_scripted's run.
	var one := await PlayReport.play_one(fixtures(), host, 7, {"party": ["fixture.character.knight",
		"fixture.character.medic", "fixture.character.rogue"]})
	var scripted := start_run(host, "7")
	_nodes.append(scripted)
	await RunPlayer.play(scripted)
	eq(one["runHash"], scripted.state.run_hash(), "the report's auto policy is RunPlayer's (same run hash)")


func test_autorun_command() -> void:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_nodes.append(game)
	game.content_root = FIXTURES
	game.load_content()
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands(false)  # built-ins only: user://dev_commands/ is shared with parallel shards
	console.attach(game)
	check((await console.execute("new " + ",".join(PARTY) + " 7"))["ok"], "a run starts")
	var played: Dictionary = await console.execute("autorun")
	check(played["ok"], "autorun plays: " + played["text"])
	check(game.run.state.status != RunState.ACTIVE, "the run is over: " + game.run.state.status)
	check(played["text"].contains(game.run.state.status), "the reply names the outcome: " + played["text"])
	check(game.run.battle_requested.is_connected(game._on_battle_requested), "the screens fight battles again afterwards")
	check((await console.execute("new " + ",".join(PARTY) + " 8"))["ok"], "another run")
	var chaos: Dictionary = await console.execute("autorun policy=chaos illegal=50")
	check(chaos["ok"] and chaos["text"].contains("violations: 0"), "autorun policy=chaos checks every battle: " + chaos["text"])
	check(not (await console.execute("autorun policy=wild"))["ok"], "an unknown policy is refused")


## Spec playable-demo 3.10 (D24): without a fixed party each seed draws its own, of the asked size (or 1 to 4), from
## different selectable characters; the report counts runs and wins by size, class and party.
func test_party_draws() -> void:
	var selectable := fixtures().characters.values().filter(func(character) -> bool: return character.selectable).size()
	var sized := await PlayReport.many(fixtures(), host, 1, 6, {"party_size": 2})
	for record in sized["runs"]:
		eq(record["party"].size(), mini(2, selectable), "seed %d: a party of two" % record["seed"])
		eq(record["party"], _unique(record["party"]), "seed %d: different characters" % record["seed"])
	eq(sized["bySize"].keys(), ["2"], "every run counted under size 2")
	var mixed := await PlayReport.many(fixtures(), host, 1, 12, {"party_size": "mixed"})
	var sizes := {}
	for record in mixed["runs"]:
		check(record["party"].size() >= 1 and record["party"].size() <= mini(4, selectable), "a size of 1 to 4")
		sizes[record["party"].size()] = true
	check(sizes.size() >= 2, "mixed draws more than one size over 12 seeds")
	var total := 0
	for key in mixed["bySize"]:
		total += mixed["bySize"][key]["runs"]
	eq(total, 12, "bySize counts every run once")
	var again := await PlayReport.many(fixtures(), host, 1, 12, {"party_size": "mixed"})
	eq(again["runs"].map(func(run): return run["party"]), mixed["runs"].map(func(run): return run["party"]),
		"the same seeds draw the same parties")
	check(not mixed["byCharacter"].is_empty() and not mixed["byParty"].is_empty(), "by class and by party")


static func _unique(values: Array) -> Array:
	var result: Array = []
	for value in values:
		if not result.has(value):
			result.append(value)
	return result


## Spec playable-demo 2.3d: a report split into shards (each through JSON, as the shard files are) and merged is the
## report of one process over the same seeds.
func test_sharded_report_merges() -> void:
	var options := {"policy": "smart", "party_size": "mixed", "check": true}
	var whole := await PlayReport.many(fixtures(), host, 1, 6, options)
	whole.erase("failures")
	var shards: Array = []
	for range_spec in [[1, 2], [3, 3], [6, 1]]:
		var shard := await PlayReport.many(fixtures(), host, range_spec[0], range_spec[1], options, true)
		shards.append(JSON.parse_string(JSON.stringify({"options": shard["options"], "records": shard["records"]})))
	var merged := PlayReport.merge(shards)
	eq(WireJson.stringify(merged), WireJson.stringify(whole), "three shards merge into the one-process report")
