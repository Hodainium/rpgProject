## Spec atomic-battles: one state hash per battle, and the opt-in determinism trace (points, deltas, diff, record vs
## replay, two fresh processes, locating a legal tamper the verdict reports later).
extends TestCase

const TRACE_SCENE: String = "res://combat/headless/trace_main.tscn"
const UltTests := preload("res://tests/combat/test_ult_interrupts.gd")


## A trace that also keeps every point's full canonical lines, to check the deltas against.
class FullLinesTrace extends BattleTrace:
	var full: Array[PackedStringArray] = []

	func point(battle: Battle, kind: String, actor: StringName = &"", ability: StringName = &"", target: StringName = &"") -> String:
		full.append(StateHasher.canonical_lines(battle)["lines"])
		return super(battle, kind, actor, ability, target)


## Plays `snap` with the scripted party and `trace` attached. Returns the ReplayRequest it produced.
func _record_traced(snap: Dictionary, trace: BattleTrace) -> Dictionary:
	var battle := new_battle(snap)
	battle.trace = trace
	var controller := ScriptedController.new()
	await battle.run(controller)
	check(battle.runner_error == "", "recording hit a runner error: " + battle.runner_error)
	return {"snapshot": snap, "actionLog": ActionRecorder.build_log(controller.entries, battle.outcome, battle.final_hash)}


func _replay_traced(request: Dictionary, with_lines: bool) -> BattleTrace:
	var runner := ReplayRunner.new()
	runner.trace = BattleTrace.new(with_lines)
	await runner.run(request, FIXTURES, host)
	return runner.trace


static func _golden(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + name + ".json"))


## The trace points that stand for a log entry (party turn actions, One Mores, party interrupts and dev decisions).
static func _party_points(points: Array) -> Array:
	var result: Array = []
	for entry in points:
		var party := entry["actor"] != null and str(entry["actor"]).begins_with("P")
		if party and entry["ability"] != null and entry["kind"] in ["turn", "extra", "interrupt", "dev"]:
			result.append(entry)
	return result


func test_one_hash_per_battle() -> void:
	var before := StateHasher.compute_count
	var request := await record(UltTests.ult_snapshot())
	eq(StateHasher.compute_count - before, 1, "recording a battle with interrupts and One Mores hashes once")
	before = StateHasher.compute_count
	var result := await replay(request)
	eq(result.get("verdict"), "Verified", "the recording verifies")
	eq(StateHasher.compute_count - before, 1, "replaying it hashes once")


func test_trace_does_not_change_battle() -> void:
	var plain := await record(UltTests.ult_snapshot())
	var traced := await _record_traced(UltTests.ult_snapshot(), BattleTrace.new(true))
	eq(WireJson.stringify(traced), WireJson.stringify(plain), "same log and final hash with a trace attached")


func test_trace_points() -> void:
	var trace := BattleTrace.new()
	var battle := new_battle(UltTests.ult_snapshot())
	battle.trace = trace
	var controller := ScriptedController.new()
	await battle.run(controller)
	var points := trace.points
	eq(points[0]["kind"], "start", "the first point is the battle start")
	eq(points[0]["turn"], 0, "before the first turn")
	eq(points.back()["kind"], "end", "the last point is the end")
	eq(points.back()["hash"], battle.final_hash, "the end point is the final hash")
	var turns := {}
	var kinds := {}
	for entry in points:
		kinds[entry["kind"]] = true
		if entry["kind"] in ["turn", "extra"]:
			check(not turns.has(entry["turn"]), "one turn or One More point per turn number (%d twice)" % entry["turn"])
			turns[entry["turn"]] = true
	eq(turns.size(), battle.turn, "every turn, party and enemy, has its point")
	for kind in ["turn", "extra", "interrupt"]:
		check(kinds.has(kind), "the ult trial has %s points" % kind)
	var enemy_points := points.filter(func(entry) -> bool: return entry["actor"] != null and str(entry["actor"]).begins_with("E"))
	check(enemy_points.any(func(entry) -> bool: return entry["kind"] == "interrupt"), "enemy interrupts are traced")
	check(enemy_points.any(func(entry) -> bool: return entry["kind"] == "turn"), "enemy turns are traced")
	var party := _party_points(points)
	eq(party.size(), controller.entries.size(), "one party point per log entry")
	for index in mini(party.size(), controller.entries.size()):
		var entry: Dictionary = controller.entries[index]
		var traced: Dictionary = party[index]
		eq([traced["turn"], traced["actor"], traced["ability"], traced["target"]],
			[entry["turn"], entry["actor"], entry["ability"], entry["target"]], "party point %d matches log entry %d" % [index, index])
		eq(traced["kind"] == "interrupt", entry.get("interrupt", false), "point %d interrupt flag" % index)
		eq(traced["kind"] == "extra", entry.get("extra", false), "point %d One More flag" % index)


func test_trace_lines_delta() -> void:
	var trace := FullLinesTrace.new(true)
	await _record_traced(UltTests.ult_snapshot(), trace)
	var rebuilt := BattleTrace.rebuild(trace.to_json())
	eq(rebuilt.size(), trace.full.size(), "one rebuilt state per point")
	for index in trace.full.size():
		var expected: PackedStringArray = trace.full[index].duplicate()
		expected.sort()
		eq(rebuilt[index], expected, "rebuilt lines at point %d equal the canonical lines" % index)
		eq(StateHasher.sha256_hex("\n".join(trace.full[index])), trace.points[index]["hash"], "point %d hash" % index)
	check(trace.points[1]["lines"].size() < trace.points[0]["lines"].size(), "later points hold only what changed")


func test_trace_diff() -> void:
	var a := {"points": [
		{"i": 0, "turn": 0, "kind": "start", "actor": null, "ability": null, "target": null, "hash": "h0",
			"lines": ["+turn=0", "+effect=E1|res://x.tres|2|1|0", "+effect=E1|res://x.tres|2|1|0"]},
		{"i": 1, "turn": 1, "kind": "turn", "actor": "P1", "ability": "Fixture.Ability.Strike", "target": "E1", "hash": "h1",
			"lines": ["-turn=0", "+turn=1"]},
	]}
	eq(BattleTrace.diff(a, a), {}, "a trace matches itself")
	eq(BattleTrace.describe({}), "traces match", "describe a match")

	var b: Dictionary = JSON.parse_string(JSON.stringify(a))
	b["points"][1]["target"] = "E2"
	b["points"][1]["hash"] = "h1b"
	b["points"][1]["lines"] = ["-turn=0", "+turn=1", "-effect=E1|res://x.tres|2|1|0"]
	var found := BattleTrace.diff(a, b)
	eq(found.get("i"), 1, "first divergent point")
	eq(found.get("fields"), ["target", "hash"], "fields that differ")
	eq(found.get("only_a"), ["effect=E1|res://x.tres|2|1|0"], "a duplicate effect line counts once per copy")
	eq(found.get("only_b"), [], "nothing only in b")
	var text := BattleTrace.describe(found)
	check(text.contains("point 1") and text.contains("target: a=E1  b=E2") and text.contains("- effect=E1"), "describe: " + text)

	var hashes_only := {"points": [{"i": 0, "turn": 0, "kind": "start", "actor": null, "ability": null, "target": null, "hash": "h0"},
		{"i": 1, "turn": 1, "kind": "turn", "actor": "P1", "ability": "S", "target": "E1", "hash": "x"}]}
	var other: Dictionary = hashes_only.duplicate(true)
	other["points"][1]["hash"] = "y"
	found = BattleTrace.diff(hashes_only, other)
	eq(found.get("fields"), ["hash"], "hash-only traces report the hash")
	eq(found.get("only_a"), [], "no lines without --lines")

	var short := {"points": [a["points"][0]]}
	found = BattleTrace.diff(short, a)
	eq(found.get("fields"), ["end"], "one trace ends early")
	eq(found.get("a"), null, "a ended")
	check(BattleTrace.describe(found).contains("trace a ends there"), "describe an early end")


func test_trace_record_vs_replay() -> void:
	var recorded := BattleTrace.new(true)
	var request := await _record_traced(UltTests.ult_snapshot(), recorded)
	var replayed := await _replay_traced(copy(request), true)
	eq(replayed.verdict, "Verified", "replay verdict on the trace")
	eq(recorded.verdict, BattleTrace.RECORDED, "a client trace is Recorded")
	eq(BattleTrace.describe(BattleTrace.diff(recorded.to_json(), replayed.to_json())), "traces match",
		"the client's trace equals the replay trace of its own request")


func test_trace_two_processes() -> void:
	var request_path := ProjectSettings.globalize_path("user://trace-two-processes.request.json")
	var file := FileAccess.open(request_path, FileAccess.WRITE)
	file.store_string(FileAccess.get_file_as_string(GOLDEN + "ult-seed-7.json"))
	file.close()
	var outputs: Array[String] = []
	for run in 2:
		var out_path := ProjectSettings.globalize_path("user://trace-two-processes-%d.json" % run)
		DirAccess.remove_absolute(out_path)
		var exit_code := OS.execute(OS.get_executable_path(), PackedStringArray(["--headless", "--quit-after", "20000"])
			+ scene_args(TRACE_SCENE, ["--in", request_path, "--out", out_path, "--lines", "--content-root", FIXTURES]))
		eq(exit_code, 0, "trace_main run %d verifies" % run)
		outputs.append(out_path)
	var first := FileAccess.get_file_as_string(outputs[0])
	check(first.length() > 0, "trace_main wrote a trace")
	eq(FileAccess.get_file_as_string(outputs[1]), first, "two fresh processes write identical traces")
	var printed: Array = []
	var diff_exit := OS.execute(OS.get_executable_path(), PackedStringArray(["--headless", "--quit-after", "20000"])
		+ scene_args(TRACE_SCENE, ["--diff", outputs[0], outputs[1]]), printed)
	eq(diff_exit, 0, "trace_main --diff exits 0 on matching traces")
	check("".join(printed).contains("traces match"), "trace_main --diff prints the result")


func test_trace_locates_tamper() -> void:
	var honest := _golden("squad-seed-42")
	var tampered := _golden("squad-seed-42-tampered-target")
	var tampered_turn := -1
	for index in honest["actionLog"]["actions"].size():
		if honest["actionLog"]["actions"][index]["target"] != tampered["actionLog"]["actions"][index]["target"]:
			tampered_turn = int(honest["actionLog"]["actions"][index]["turn"])
			break
	var verdict: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "squad-seed-42-tampered-target.result.json"))
	check(int(verdict["mismatch"]["turn"]) > tampered_turn, "the verdict reports the tamper later than it happened")
	var found := BattleTrace.diff((await _replay_traced(honest, true)).to_json(), (await _replay_traced(tampered, true)).to_json())
	eq(found.get("a", {}).get("turn"), tampered_turn, "the trace finds the tampered turn")
	check("target" in found.get("fields", []), "the divergent field is the target: %s" % [found.get("fields")])
	check(not found.get("only_a", []).is_empty(), "the differing lines are shown")

