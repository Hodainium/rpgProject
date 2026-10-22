## Golden vectors (spec "Golden vectors"): each committed request replays in a FRESH headless process, twice, and must
## produce its committed .result.json byte for byte (engineVersion is checked separately against the pinned build).
## Regenerate with: godot --headless --path client-godot res://tests/run_tests.tscn -- --update-goldens --filter test_golden
extends TestCase

const PINNED_ENGINE: String = "4.7.2.stable.mono"
const REPLAY_SCENE: String = "res://combat/headless/replay_main.tscn"


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
	}


func test_golden_replays() -> void:
	if update_goldens:
		await _write_goldens()
	var requests := PackedStringArray()
	for name in ResourceLoader.list_directory(GOLDEN):
		if name.ends_with(".json") and not name.ends_with(".result.json"):
			requests.append(name.trim_suffix(".json"))
	requests.sort()
	eq(Array(requests), ["break-seed-11", "duel-seed-1", "run-v2-seed-7", "squad-seed-42", "squad-seed-42-tampered-target",
		"ult-seed-7", "ult-seed-7-tampered-turn"],
		"golden set")
	for name in requests:
		var expected := FileAccess.get_file_as_string(GOLDEN + name + ".result.json")
		for run in 2:
			var replayed := _replay_fresh_process(GOLDEN + name + ".json")
			eq(_without_engine(replayed["text"]), _without_engine(expected), "%s run %d matches its golden result" % [name, run + 1])
			var parsed: Variant = JSON.parse_string(replayed["text"])
			if parsed is Dictionary:
				var engine := str(parsed.get("engineVersion", ""))
				check(engine.begins_with(PINNED_ENGINE), "%s ran on the pinned Godot build, got %s" % [name, engine])
				eq(replayed["exit"], 0 if parsed.get("verdict") == "Verified" else 2, "%s exit code" % name)


## Runs replay_main in a new Godot process and returns {"exit": int, "text": String}.
func _replay_fresh_process(request_path: String) -> Dictionary:
	var out_path := ProjectSettings.globalize_path("user://golden-replay-result.json")
	DirAccess.remove_absolute(out_path)
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), REPLAY_SCENE, "--",
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
	for name in requests:
		_write(GOLDEN + name + ".json", WireJson.stringify(requests[name]))
		var replayed := _replay_fresh_process(GOLDEN + name + ".json")
		_write(GOLDEN + name + ".result.json", replayed["text"])
	print("    goldens rewritten under ", GOLDEN)


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
