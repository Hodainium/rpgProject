## Golden vectors (spec "Golden vectors"): each committed request replays in a FRESH headless process, twice, and must
## produce its committed .result.json byte for byte (engineVersion is checked separately against the pinned build).
## Regenerate with: godot --headless --path client-godot res://tests/run_tests.tscn -- --update-goldens --filter test_golden
## Each golden also has a committed <name>.trace.json (spec atomic-battles): when a result changes, the test prints the
## first point where a fresh trace leaves the committed one.
extends TestCase

const PINNED_ENGINE: String = "4.7.2.stable.mono"
const REPLAY_SCENE: String = "res://combat/headless/replay_main.tscn"
const TRACE_SCENE: String = "res://combat/headless/trace_main.tscn"


static func _scenarios() -> Dictionary:
	return {
		"duel-seed-1": snapshot("duel", [[1, "sweeper"]], "1"),  # weak hits: several turns, the enemy acts too
		"squad-seed-42": squad_snapshot("42"),
		# Spec game-skeleton 3.5: inventory capture, enemy loadouts, elite, scaling, carry-over, a dead member.
		"run-v2-seed-7": preload("res://tests/combat/test_battle_v2.gd").v2_snapshot("7"),
		# Spec item-pass: weakness hits, breaks, One More actions ("extra": true), a follow-up passive.
		"break-seed-11": preload("res://tests/combat/test_item_pass_combat.gd").break_snapshot("brittle_pair",
			["fixture.item.chaser_charm"], "11"),
		# Spec ult-interrupts: ults in both windows ("interrupt": true), chains, an enemy ult, ult breaks with One More.
		"ult-seed-7": preload("res://tests/combat/test_ult_interrupts.gd").ult_snapshot(),
		# Spec content-pass: statuses, affinities and a frozen party turn (no entry); a boss with phases, a pattern brain,
		# party weakness hits with enemy One Mores (H7) and ults timed on a Downed party member.
		"status-seed-3": status_golden_snapshot(),
		"boss-seed-5": preload("res://tests/combat/test_bosses.gd").boss_snapshot("5"),
		# Spec playable-demo 3.8: a mirror boss copying the party's held items and armor, one stack per piece (H9, H10).
		"mirror-seed-9": preload("res://tests/combat/test_mirror.gd").mirror_snapshot("9"),
	}


## Spec content-pass: the status trial with the guard taunting (so enemies aim at it) while it holds the Fire-drain
## implant, and the hexer holding Frostguard: DoT stacks, statuses rolled and resisted, drained and resisted hits, a
## frozen party turn skipped, a cleansing ult.
static func status_golden_snapshot(seed_text: String = "3") -> Dictionary:
	return preload("res://tests/combat/test_statuses.gd").status_snapshot(["hexer", "guard"], "status_trial", seed_text,
		{1: ["frostguard"], 2: ["implant"]})


## Spec atomic-battles: a close ult trial (both ultists on half HP) whose outcome hangs on one interrupt. Not a golden
## itself; its tampered copy is.
static func _close_ult_snapshot() -> Dictionary:
	var snap: Dictionary = preload("res://tests/combat/test_ult_interrupts.gd").ult_snapshot(["ultist", "ultist"], "ult_trial", "2")
	snap["battleId"] = "ult-close-seed-2"
	var party: Array = []
	for member in snap["party"]:  # hp right after level: the PartyMemberSnapshot field order
		party.append({"slot": member["slot"], "unitDefId": member["unitDefId"], "level": member["level"], "hp": 60000,
			"skills": member["skills"], "equipmentIds": member["equipmentIds"], "items": member["items"],
			"useSlots": member["useSlots"]})
	snap["party"] = party
	return snap


func test_golden_replays() -> void:
	if update_goldens:
		await _write_goldens()
	var requests := PackedStringArray()
	for name in ResourceLoader.list_directory(GOLDEN):
		if name.ends_with(".json") and not name.ends_with(".result.json") and not name.ends_with(".trace.json"):
			requests.append(name.trim_suffix(".json"))
	requests.sort()
	eq(Array(requests), ["boss-seed-5", "break-seed-11", "duel-seed-1", "mirror-seed-9", "run-v2-seed-7", "squad-seed-42",
		"squad-seed-42-tampered-final", "squad-seed-42-tampered-target", "status-seed-3", "status-seed-3-tampered-skip",
		"ult-close-seed-2-tampered-outcome", "ult-seed-7", "ult-seed-7-tampered-turn"], "golden set")
	for name in requests:
		check(FileAccess.file_exists(GOLDEN + name + ".trace.json"), "%s has a committed trace" % name)
		var expected := FileAccess.get_file_as_string(GOLDEN + name + ".result.json")
		for run in 2:
			var replayed := _replay_fresh_process(GOLDEN + name + ".json")
			eq(_without_engine(replayed["text"]), _without_engine(expected), "%s run %d matches its golden result" % [name, run + 1])
			if _without_engine(replayed["text"]) != _without_engine(expected):
				_explain(name)
			var parsed: Variant = JSON.parse_string(replayed["text"])
			if parsed is Dictionary:
				var engine := str(parsed.get("engineVersion", ""))
				check(engine.begins_with(PINNED_ENGINE), "%s ran on the pinned Godot build, got %s" % [name, engine])
				eq(replayed["exit"], 0 if parsed.get("verdict") == "Verified" else 2, "%s exit code" % name)


## Spec atomic-battles: a changed golden explains itself. Traces it in a fresh process and prints the first point where
## it leaves the committed trace.
func _explain(name: String) -> void:
	var fresh := _trace_fresh_process(GOLDEN + name + ".json")
	var committed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + name + ".trace.json"))
	var parsed: Variant = JSON.parse_string(fresh)
	if committed is Dictionary and parsed is Dictionary:
		print("    %s: committed trace vs now:
      %s" % [name,
			BattleTrace.describe(BattleTrace.diff(committed, parsed)).replace("
", "
      ")])


func test_golden_trace_explains_a_change() -> void:
	var committed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN + "ult-seed-7.trace.json"))
	eq(committed.get("verdict"), "Verified", "the committed trace carries the replay verdict")
	var altered: Dictionary = committed.duplicate(true)
	var middle: Dictionary = altered["points"][altered["points"].size() / 2]
	middle["hash"] = "0".repeat(64)
	middle["lines"].append("+attr=E1|hp|1|1")
	var found := BattleTrace.diff(committed, altered)
	eq(found.get("i"), middle["i"], "the altered point is the first divergence")
	eq(found.get("only_b"), ["attr=E1|hp|1|1"], "with the line that differs")
	check(BattleTrace.describe(found).contains("first divergence at point"), "printable")


## Runs trace_main (with lines) in a new Godot process and returns the trace text.
func _trace_fresh_process(request_path: String) -> String:
	var out_path := ProjectSettings.globalize_path("user://golden-trace.json")
	DirAccess.remove_absolute(out_path)
	var args := PackedStringArray(["--headless", "--quit-after", "200000"]) + scene_args(TRACE_SCENE, [
		"--in", ProjectSettings.globalize_path(request_path), "--out", out_path, "--lines", "--content-root", FIXTURES])
	OS.execute(OS.get_executable_path(), args)
	return FileAccess.get_file_as_string(out_path)


## Runs replay_main in a new Godot process and returns {"exit": int, "text": String}.
func _replay_fresh_process(request_path: String) -> Dictionary:
	var out_path := ProjectSettings.globalize_path("user://golden-replay-result.json")
	DirAccess.remove_absolute(out_path)
	var args := PackedStringArray(["--headless"]) + scene_args(REPLAY_SCENE, [
		"--in", ProjectSettings.globalize_path(request_path), "--out", out_path, "--content-root", FIXTURES])
	var exit_code := OS.execute(OS.get_executable_path(), args)
	return {"exit": exit_code, "text": FileAccess.get_file_as_string(out_path)}


static func _without_engine(text: String) -> String:
	return RegEx.create_from_string("\"engineVersion\":\"[^\"]*\"").sub(text, "\"engineVersion\":\"\"")


func _write_goldens() -> void:
	var requests := {}
	for name in _scenarios():
		requests[name] = await record(_scenarios()[name])
	var tampered := copy(requests["squad-seed-42"])
	for entry in tampered["actionLog"]["actions"]:
		if entry["ability"] == "Fixture.Ability.Strike":
			entry["target"] = "E3" if entry["target"] != "E3" else "E1"
			break
	requests["squad-seed-42-tampered-target"] = tampered
	var moved := copy(requests["ult-seed-7"])
	for entry in moved["actionLog"]["actions"]:
		if entry.get("interrupt", false):
			entry["turn"] = int(entry["turn"]) + 1
			break
	requests["ult-seed-7-tampered-turn"] = moved
	# Spec atomic-battles: legal tampers that reach the end of the battle (found by searching one-entry changes).
	var final := copy(requests["squad-seed-42"])
	final["actionLog"]["actions"][3]["target"] = "E2"  # another living enemy: same Victory, different final state
	requests["squad-seed-42-tampered-final"] = final
	var outcome := copy(await record(_close_ult_snapshot()))
	outcome["actionLog"]["actions"].remove_at(11)  # one party entry fewer: the rest still fits, the party now loses
	requests["ult-close-seed-2-tampered-outcome"] = outcome
	# Spec content-pass H1: an entry claimed for a turn the simulation skips (the party unit is frozen) → TurnMismatch.
	var skip := await _first_party_skip(status_golden_snapshot())
	var skipped := copy(requests["status-seed-3"])
	var actions: Array = skipped["actionLog"]["actions"]
	var at := 0
	while at < actions.size() and int(actions[at]["turn"]) < int(skip["turn"]):
		at += 1
	actions.insert(at, {"turn": skip["turn"], "actor": str(skip["unit"]), "ability": "Fixture.Ability.Strike", "target": "E1"})
	requests["status-seed-3-tampered-skip"] = skipped
	for name in requests:
		_write(GOLDEN + name + ".json", WireJson.stringify(requests[name]))
		var replayed := _replay_fresh_process(GOLDEN + name + ".json")
		_write(GOLDEN + name + ".result.json", replayed["text"])
		_write(GOLDEN + name + ".trace.json", _trace_fresh_process(GOLDEN + name + ".json"))
	print("    goldens rewritten under ", GOLDEN)


## The first party turn the battle skips because the unit is controlled: {"unit", "turn"}.
func _first_party_skip(snap: Dictionary) -> Dictionary:
	var battle := new_battle(snap)
	var skips := []
	battle.turn_skipped.connect(func(unit_id): if String(unit_id).begins_with("P"): skips.append({"unit": unit_id, "turn": battle.turn}))
	await battle.run(ScriptedController.new())
	return skips[0]


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
