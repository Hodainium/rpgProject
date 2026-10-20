## The dev console (spec dev-tools 3.2-3.4, 2.6): registry, autocomplete, play commands, cheats through GAS and the
## run log, isolated dev streams, the windowless tool commands and the script runner. Fixtures and user:// only.
extends TestCase

const PARTY: String = "fixture.character.knight,fixture.character.medic"
const SCRATCH: String = "user://test_dev_console/"

var _games: Array[GameMain] = []


## A GameMain on the fixtures (with its screens, animations skipped) and a console attached to it.
func _session() -> Array:
	for old in _games:
		if is_instance_valid(old):
			old.free()
	_games.clear()
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	game.content_root = FIXTURES
	game.load_content()
	_games.append(game)
	var console := DevConsole.new(host.get_tree())
	console.keep_history = false
	console.load_commands()
	console.attach(game)
	console.auto_battle = true
	return [game, console]


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


## Runs a line and waits for any battle it started to finish (or to wait for `act`).
func _run(session: Array, line: String) -> Dictionary:
	var result: Dictionary = await session[1].execute(line)
	var game: GameMain = session[0]
	for frame in 3000:
		if game.run == null or game.run.pending_battle.is_empty():
			break
		if not session[1].auto_battle and game.recorder != null and game.recorder.waiting_for != &"":
			break
		await host.get_tree().process_frame
	return result


func _ok(session: Array, line: String) -> Dictionary:
	var result := await _run(session, line)
	check(result["ok"], "'%s' works: %s" % [line, result["text"]])
	return result


## A cell next to the start whose content is not a battle (or -1).
static func _quiet_cell(run: RunController) -> int:
	for index in run.state.map.sorted_indices():
		if run.can_enter(index) and run.state.map.cells[index]["content"]["kind"] != "encounter":
			return index
	return -1


func test_console_registry() -> void:
	var console := DevConsole.new()
	console.keep_history = false
	console.load_commands()
	eq(Array(console.warnings), [], "every command file loads")
	for name in console.commands:
		var command: DevCommand = console.commands[name]
		check(command.usage != "" and command.help != "", "%s has usage and help" % name)
	check(not console.commands.has("example"), "_template.gd is not registered")
	for name in ["help", "new", "state", "map", "enter", "give", "stat", "kill", "spawn", "create", "grid", "play"]:
		check(console.commands.has(name), "built-in command %s" % name)
	# Throwaway commands in user://dev_commands/: picked up without code changes, can't replace a built-in.
	var folder := ProjectSettings.globalize_path(DevConsole.USER_COMMANDS_DIR)
	DirAccess.make_dir_recursive_absolute(folder)
	var probe := 'extends DevCommand\n\n\nfunc _init() -> void:\n\tname = "%s"\n\tusage = "%s"\n\thelp = "test"\n\n\nfunc run(_ctx: DevContext, _args: PackedStringArray) -> String:\n\treturn "probe ok"\n'
	_write(DevConsole.USER_COMMANDS_DIR + "zz_probe.gd", probe % ["zzprobe", "zzprobe"])
	_write(DevConsole.USER_COMMANDS_DIR + "zz_shadow.gd", probe % ["give", "give"])
	console.load_commands()
	check(console.commands.has("zzprobe"), "a throwaway command is loaded")
	eq(console.commands["give"].get_script().resource_path, "res://game/dev/commands/give.gd", "a built-in can't be replaced")
	check(Array(console.warnings).any(func(warning: String) -> bool: return warning.contains("zz_shadow")), "the clash is reported")
	eq((await console.execute("zzprobe"))["text"], "probe ok", "and it runs")
	DirAccess.remove_absolute(folder.path_join("zz_probe.gd"))
	DirAccess.remove_absolute(folder.path_join("zz_shadow.gd"))


func test_console_autocomplete() -> void:
	var session := _session()
	var console: DevConsole = session[1]
	eq(console.complete("gi"), ["give "], "command names")
	var items := console.complete("give fixture.item.w")
	check(items.has("give fixture.item.whetstone"), "item ids from the content")
	var sorted := items.duplicate()
	sorted.sort()
	eq(items, sorted, "sorted")
	eq(console.complete("play ro"), ["play room"], "fixed values")
	check(console.complete("stat ").has("stat atk"), "dev stat attributes")


func test_console_errors_and_cheats_off() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	var log_size := run.run_log.size()
	var hash := run.state.run_hash()
	var unknown := await _run(session, "frobnicate")
	check(not unknown["ok"] and unknown["text"].contains("unknown command"), "unknown command")
	var bad_id := await _run(session, "give fixture.item.whetstne")
	check(not bad_id["ok"] and bad_id["text"].contains("did you mean"), "unknown id with suggestions: " + bad_id["text"])
	var bad_args := await _run(session, "coins lots")
	check(not bad_args["ok"], "a bad argument is refused")
	session[1].cheats_allowed = false
	var refused := await _run(session, "coins 5")
	check(not refused["ok"] and refused["text"].contains("cheats are off"), "cheats refused while off")
	eq(run.run_log.size(), log_size, "nothing logged")
	eq(run.state.run_hash(), hash, "nothing changed")
	check(not run.state.dev, "the run stays clean")


func test_console_play_commands_stay_clean() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	var cell := _quiet_cell(run)
	check(cell >= 0, "a quiet room next to the start")
	await _ok(session, "map")
	await _ok(session, "enter %d" % cell)
	await _ok(session, "state")
	check(not run.state.dev, "play commands never mark the run")
	check(not run.state.canonical_lines().has("dev=1"), "no dev line in the hash")
	var direct := RunController.new()
	host.add_child(direct)
	direct.start_run(fixtures(), Array(PARTY.split(",")), "7")
	direct.enter_room(cell)
	eq(run.state.run_hash(), direct.state.run_hash(), "the same choices on screen give the same run hash")
	direct.free()


func test_console_cheats() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	await _ok(session, "give fixture.item.whetstone 1")
	check(run.state.member(1)["items"].has(&"fixture.item.whetstone"), "give")
	await _ok(session, "remove fixture.item.whetstone")
	check(not run.state.member(1)["items"].has(&"fixture.item.whetstone"), "remove")
	await _ok(session, "equip fixture.equipment.blade 2")
	check(run.state.member(2)["equipment"].values().has(&"fixture.equipment.blade"), "equip")
	await _ok(session, "coins 12")
	eq(run.state.coins, 12, "coins")
	await _ok(session, "coins -50")
	eq(run.state.coins, 0, "never below 0")
	# stat: dev stat items, read back through GAS.
	var before := _stat(run, 1, "atk")
	await _ok(session, "stat atk 3 1")
	eq(run.state.member(1)["items"].count(&"dev.up.atk"), 3, "three dev stat items")
	eq(_stat(run, 1, "atk") - before, 3000, "+30 ATK through GAS (stored ×100)")
	await _ok(session, "stat atk -1 1")
	eq(_stat(run, 1, "atk") - before, 2000, "a down item lowers it")
	check(not (await _run(session, "stat luck 1"))["ok"], "an attribute without dev items is refused")
	# effect / heal / revive go through the field context.
	var mp_full: int = run.party_stats()[2]["mp"]
	await _ok(session, "effect res://tests/fixtures/effects/mp_cost.tres 2")
	check(run.party_stats()[2]["mp"] < mp_full, "effect: an instant effect sticks")
	await _ok(session, "heal 2")
	eq(run.party_stats()[2]["mp"], mp_full, "heal: back to max through GAS")
	await _ok(session, "effect res://game/dev/content/effects/dev_kill.tres 2")
	check(not run.state.member(2)["alive"], "a member can die out of battle")
	await _ok(session, "revive 2")
	check(run.state.member(2)["alive"] and run.state.member(2)["hp"] == 100, "revive: 1 HP")
	await _ok(session, "reveal")
	check(run.state.revealed, "reveal")
	await _ok(session, "spawn item fixture.item.banner 4")
	var pickups: Array = run.state.map.cells[run.state.current_cell]["pickups"]
	check(pickups.any(func(pickup) -> bool: return pickup["item"] == &"fixture.item.banner" and pickup["price"] == 4), "spawn item")
	await _ok(session, "spawn pool Fixture.Pool.Treasure")
	eq(pickups.size(), 2, "spawn pool")
	await _ok(session, "coins 10")
	await _ok(session, "take 1000 1")
	check(run.state.member(1)["items"].has(&"fixture.item.banner"), "a spawned shop slot is bought with the normal take")
	await _ok(session, "stage 1")
	eq(run.state.floor_index, 1, "stage 1 is the second floor (0-based)")
	var dev_entries := run.run_log.filter(func(entry) -> bool: return entry["type"] == "dev")
	check(dev_entries.size() >= 12, "every cheat is in the run log (%d)" % dev_entries.size())
	check(run.state.dev and run.state.canonical_lines().has("dev=1"), "the run is marked dev")
	await _ok(session, "win")
	eq(run.state.status, RunState.WON, "win")


func test_console_spawn_and_kill() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	check(not (await _run(session, "kill"))["ok"], "kill outside a battle is refused")
	await _ok(session, "spawn fixture.encounter.lone")
	check(run.pending_battle.is_empty() and run.state.status == RunState.ACTIVE, "spawn: an auto battle is fought and won")
	session[1].auto_battle = false
	await _ok(session, "spawn fixture.encounter.pack")
	check(not run.pending_battle.is_empty(), "with auto off the battle waits for the party")
	var log_before: int = run.run_log.size()
	await _ok(session, "kill")
	check(run.pending_battle.is_empty(), "kill ended the battle")
	eq(run.state.status, RunState.ACTIVE, "as a win")
	var battle_entry: Dictionary = run.run_log[run.run_log.size() - 1]
	eq(battle_entry["type"], "battle", "the battle is logged")
	eq(battle_entry["outcome"], Battle.VICTORY, "Victory")
	eq(battle_entry["actionLog"]["actions"][0]["ability"], "Dev.Kill", "the kill is an ordinary action entry")
	check(run.run_log.size() > log_before, "and a dev entry")
	await _ok(session, "spawn fixture.encounter.pack")
	await _ok(session, "kill party")
	eq(run.state.status, RunState.LOST, "kill party → Lost")


func test_console_create_grid_play() -> void:
	var session := _session()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var path := SCRATCH + "console_room.tres"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await _ok(session, "create room test.room.console_room " + SCRATCH)
	check(FileAccess.file_exists(path), "create writes the template")
	check(not (await _run(session, "create room test.room.console_room " + SCRATCH))["ok"], "never overwrites")
	var shown := await _ok(session, "grid %s show" % path)
	check(shown["text"].contains("P1"), "grid show draws the room: " + shown["text"])
	await _ok(session, "grid %s paint 6 3 pedestal" % path)
	await _ok(session, "grid %s door n" % path)
	var unsaved: RoomDefinition = session[1].grid_rooms[path]
	eq(RoomGridOps.label(unsaved.placements[RoomGridOps.placement_at(unsaved, Vector2i(6, 3))]), "I", "painted on the copy")
	await _ok(session, "play room " + path)
	var run: RunController = session[0].run
	check(run != null and run.state.sandbox, "play room starts a sandbox")
	eq(run.content.rooms[&"test.room.console_room"].doors, 14, "with the unsaved grid copy (north door toggled off)")
	await _ok(session, "grid %s save" % path)
	var saved: RoomDefinition = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	eq(saved.doors, 14, "grid save writes the file")
	await _ok(session, "play enemy fixture.enemy.grunt")
	check(session[0].run.state.sandbox, "play enemy")
	await _ok(session, "play character fixture.character.rogue")
	eq(session[0].run.state.party[0]["character"], &"fixture.character.rogue", "play character")


func test_dev_streams_isolated() -> void:
	var plain := RunController.new()
	host.add_child(plain)
	plain.start_run(fixtures(), Array(PARTY.split(",")), "11")
	var cheated := RunController.new()
	host.add_child(cheated)
	var content := fixtures().overlay([])
	content.add_root(RunController.DEV_CONTENT)
	cheated.start_run(content, Array(PARTY.split(",")), "11")
	cheated.dev_coins(30)
	cheated.dev_stat("atk", 2, 1)
	cheated.dev_spawn(fixtures().encounters[&"fixture.encounter.pack"])
	await cheated.fight(ScriptedController.new())
	plain.enter_floor(1)
	cheated.enter_floor(1)
	eq(cheated.state.map.canonical_lines(), plain.state.map.canonical_lines(), "cheats never shift a later floor")
	plain.free()
	cheated.free()


func test_dev_run_replays() -> void:
	var hashes: Array = []
	for attempt in 2:
		var session := _session()
		for line in ["new %s 5" % PARTY, "stat def 2 1", "spawn fixture.encounter.pack", "spawn pool Fixture.Pool.Treasure",
				"coins 9", "heal"]:
			await _ok(session, line)
		hashes.append(session[0].run.state.run_hash())
	eq(hashes[0], hashes[1], "the same dev commands give the same run hash")


func test_dev_script_runner() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var script := ProjectSettings.globalize_path(SCRATCH + "script.txt")
	var out := ProjectSettings.globalize_path(SCRATCH + "state.json")
	_write(SCRATCH + "script.txt", "# a comment\nnew %s 7\n\nmap\nstat atk 1\nstate\n" % PARTY)
	var code := _runner(script, out)
	eq(code, 0, "the runner exits 0")
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out))
	eq(state["commands"].size(), 4, "every command ran")
	check(state["dev"], "the JSON has the dev flag")
	_write(SCRATCH + "script.txt", "new %s 7\nfrobnicate\n" % PARTY)
	eq(_runner(script, out), 2, "a failed command exits 2")
	var failed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out))
	check(failed["failed"][0].contains("line 2"), "and names the line")


func _runner(script: String, out: String) -> int:
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--quit-after", "100000",
		"res://game/tools/dev_run.tscn", "--", "--script", script, "--out", out, "--content-root", FIXTURES]
	return OS.execute(OS.get_executable_path(), args)


static func _stat(run: RunController, slot: int, attribute_name: String) -> int:
	var battle := run._field_battle(0)
	var value := battle.unit_by_id(StringName("P%d" % slot)).stat(attribute_name)
	battle.free()
	return value


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


## Every editor action has a console command running the same code (spec dev-tools 1, "Claude parity").
func test_tool_parity() -> void:
	var console := DevConsole.new()
	console.keep_history = false
	console.load_commands()
	var pairs := {"dock Create": "create", "dock Validate": "validate", "room grid": "grid", "Play buttons": "play",
		"seed runner": "seeds", "screenshot": "shot"}
	for action in pairs:
		check(console.commands.has(pairs[action]), "%s has the command %s" % [action, pairs[action]])
	# The inspector grid commits *_result() through undo/redo; the console applies the same functions.
	var room: RoomDefinition = fixtures().rooms[&"fixture.room.cross"].duplicate(true)
	var undoable := RoomGridOps.paint_result(room, Vector2i(3, 3), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
	RoomGridOps.paint(room, Vector2i(3, 3), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
	eq(room.placements.size(), undoable.size(), "grid paint: inspector and console agree")
	eq(RoomGridOps.toggle_door_result(room, RoomDefinition.DOOR_E), room.doors ^ RoomDefinition.DOOR_E, "grid door")



func test_console_seed_codes() -> void:
	var session := _session()
	var code := RunSeeds.to_code(123456789)
	await _ok(session, "new %s %s" % [PARTY, code])
	eq(session[0].run.state.run_seed, 123456789, "new takes a code typed with its space")
	await _ok(session, "seed %s" % RunSeeds.to_code(42))
	eq(session[0].run.state.run_seed, 42, "seed takes one too")
	check(not (await _run(session, "seed ABCD EFGH"))["ok"], "a bad code is refused")


## `effect`: a file that isn't a GameplayEffect is refused (not a script error); refused during a battle; a lasting
## effect ends with the field context, as for any out-of-battle effect.
func test_console_effect() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	var log_size: int = run.run_log.size()
	var not_effect := await _run(session, "effect res://tests/fixtures/rooms/cross.tres")
	check(not not_effect["ok"] and not_effect["text"].contains("GameplayEffect"), "a room file is refused: " + not_effect["text"])
	check(not (await _run(session, "effect res://nope.tres"))["ok"], "a missing file is refused")
	eq(run.run_log.size(), log_size, "nothing logged")
	var atk := _stat(run, 1, "atk")
	await _ok(session, "effect res://tests/fixtures/effects/whetstone.tres 1")
	eq(_stat(run, 1, "atk"), atk, "a lasting (infinite) effect ends with the field context")
	session[1].auto_battle = false
	await _ok(session, "spawn fixture.encounter.pack")
	var in_battle := await _run(session, "effect res://tests/fixtures/effects/mp_cost.tres")
	check(not in_battle["ok"] and in_battle["text"].contains("battle"), "refused during a battle: " + in_battle["text"])


## In battle: give / stat apply from the next battle (and say so); kill <slot> kills one member and the same actor is
## asked again. Out of battle: give is refused when nobody can hold the item.
func test_console_battle_edges() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	# Usable items need a free use slot: fill them, then the next give is refused before anything changes.
	var refused: Dictionary = {}
	for attempt in 6:
		refused = await _run(session, "give fixture.item.feather")
		if not refused["ok"]:
			break
	check(not refused["ok"] and refused["text"].contains("nobody can hold fixture.item.feather"),
		"give refused when no one can hold it: " + refused["text"])
	var dev_entries := run.run_log.filter(func(entry) -> bool: return entry["type"] == "dev").size()
	await _run(session, "give fixture.item.feather")
	eq(run.run_log.filter(func(entry) -> bool: return entry["type"] == "dev").size(), dev_entries, "a refused give is not logged")
	session[1].auto_battle = false
	await _ok(session, "spawn fixture.encounter.pack")
	check(session[0].recorder.waiting_for != &"", "a party member waits")
	var give := await _ok(session, "give fixture.item.whetstone")
	check(give["text"].contains("next battle"), "give mid-battle says when it applies: " + give["text"])
	var stat := await _ok(session, "stat atk 1")
	check(stat["text"].contains("next battle"), "stat mid-battle says when it applies: " + stat["text"])
	var actor: StringName = session[0].recorder.waiting_for
	var victim := 2 if actor == &"P1" else 1
	await _ok(session, "kill %d" % victim)
	check(not run.pending_battle.is_empty(), "the battle goes on after killing one member")
	eq(session[0].recorder.waiting_for, actor, "the same actor is asked again (the kill used no turn)")
	var battle := run.get_node("RunBattle") as Battle
	check(not battle.unit_by_id(StringName("P%d" % victim)).alive, "that member is dead")
	var entry: Dictionary = session[0].recorder.entries[session[0].recorder.entries.size() - 1]
	eq([entry["ability"], entry["target"]], ["Dev.Kill", str(victim)], "logged as an ordinary entry with its target")
	await _ok(session, "kill")
	check(run.pending_battle.is_empty(), "kill enemies ends it")
