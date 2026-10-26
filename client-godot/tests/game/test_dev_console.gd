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


func _runner(script: String, out: String, extra: Array = []) -> int:
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--quit-after", "100000",
		"res://game/tools/dev_run.tscn", "--", "--script", script, "--out", out, "--content-root", FIXTURES]
	return OS.execute(OS.get_executable_path(), args + extra)


## A command that raises a script error fails its line (exit 2), even though its reply looks fine: the JSON names the
## line and carries the error. The throwaway command is removed from user://dev_commands/ afterwards.
func test_dev_script_runner_catches_errors() -> void:
	var folder := SCRATCH + "boom_commands/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	_write(folder + "boom.gd", "extends DevCommand


func _init() -> void:
	name = \"boom\"
	usage = \"boom\"
" +
		"	help = \"Test only: raises a script error.\"


func run(_ctx: DevContext, _args: PackedStringArray) -> String:
" +
		"	var values := {}
	return values.nope
")
	var script := ProjectSettings.globalize_path(SCRATCH + "boom.txt")
	var out := ProjectSettings.globalize_path(SCRATCH + "boom.json")
	_write(SCRATCH + "boom.txt", "new %s 7
boom
state
" % PARTY)
	var code := _runner(script, out, ["--commands", ProjectSettings.globalize_path(folder)])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DevConsole.USER_COMMANDS_DIR + "boom.gd"))
	eq(code, 2, "a script error fails the run")
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(out))
	eq(state["failed"].size(), 1, "one failed line")
	check(state["failed"][0].contains("line 2: boom") and state["failed"][0].contains("1 script or engine error"),
		"the boom line is named with its error count: %s" % [state["failed"]])
	check(state["commands"][1]["ok"] and state["commands"][1]["errors"][0].contains("'nope'"),
		"the reply was ok, the error is in the JSON")
	check(not state["commands"][2].has("errors"), "the next command is clean")


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
		"seed runner": "seeds", "screenshot": "shot", "party panel Equip": "wear", "party panel Unequip": "unwear",
		"animation preview": "anim", "battle panel status line": "status", "menu run picker": "new",
		"seed report --play": "autorun", "UI buttons, Back and screens (spec ui-framework)": "ui",
		"gameplay message log (spec gameplay-messages)": "messages"}
	for action in pairs:
		check(console.commands.has(pairs[action]), "%s has the command %s" % [action, pairs[action]])
	# The inspector grid commits *_result() through undo/redo; the console applies the same functions.
	var room: RoomDefinition = fixtures().rooms[&"fixture.room.cross"].duplicate(true)
	var undoable := RoomGridOps.paint_result(room, Vector2i(3, 3), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
	RoomGridOps.paint(room, Vector2i(3, 3), RoomPlacement.Kind.ITEM_PEDESTAL, 1)
	eq(room.placements.size(), undoable.size(), "grid paint: inspector and console agree")
	eq(RoomGridOps.toggle_door_result(room, RoomDefinition.DOOR_E), room.doors ^ RoomDefinition.DOOR_E, "grid door")



## Spec gameplay-messages 2.4: `messages on` logs the run's and the battle's messages; `last`, `off`.
func test_console_messages() -> void:
	var session := _session()
	await _ok(session, "messages on")
	await _ok(session, "new %s 7" % PARTY)
	await _ok(session, "spawn fixture.encounter.pack")
	var console: DevConsole = session[1]
	var text := "
".join(PackedStringArray(console.message_log))
	for line in ["[msg] Message.Run.Started Verb.Start", "[msg] Message.Run.FloorEntered Verb.Enter",
			"[msg] Message.Battle.Started Verb.Start →fixture.encounter.pack", "[msg] Message.Battle.Damage Verb.Damage P",
			"[msg] Message.Battle.Ended"]:
		check(text.contains(line), "the log has '%s'" % line)
	var last := await _ok(session, "messages last 1")
	eq(last["text"], console.message_log.back(), "last 1 is the newest line")
	await _ok(session, "messages off")
	var count := console.message_log.size()
	await _ok(session, "new %s 8" % PARTY)
	eq(console.message_log.size(), count, "nothing is logged while off")
	check(not (await _run(session, "messages on Battle"))["ok"], "a channel must be a Message tag")


## Promoted screenshot helpers (spec dev-tools): `xp` / `xp level` (on a copy of the run with an XP curve; the
## fixtures have none), `bossdone` and `goto`, each a logged cheat that refuses what it can't do.
func test_console_xp_bossdone_goto() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var game: GameMain = session[0]
	check(not (await _run(session, "xp 100"))["ok"], "a run without an XP curve refuses xp")
	var structure: RunStructure = game.run.structure.duplicate()
	structure.xp_to_level.assign([100, 300, 600])
	game.run.structure = structure
	await _ok(session, "xp 150")
	eq(game.run.state.party.map(func(member) -> int: return member["level"]), [2, 2], "150 XP: level 2 for both")
	await _ok(session, "xp level 2 1")
	eq([game.run.state.member(1)["level"], game.run.state.member(2)["level"]], [4, 2], "two free levels for slot 1 only")
	await _ok(session, "bossdone")
	check(game.run.state.boss_cleared and game.run.state.status == RunState.ACTIVE, "the stairs open on floor 1")
	check(not (await _run(session, "bossdone"))["ok"], "a beaten boss is refused")
	await _ok(session, "goto boss")
	eq(game.run.state.map.cells[game.run.state.current_cell]["role"], FloorMap.ROLE_BOSS, "goto walks into the boss room")
	check(not (await _run(session, "goto nowhere"))["ok"], "an unknown room is refused")
	var cheats: Array = game.run.run_log.filter(func(entry) -> bool: return entry["type"] == "dev").map(
		func(entry) -> String: return entry["command"])
	eq(cheats, ["xp", "level", "bossdone", "goto"], "every cheat is logged")
	check(game.run.state.dev, "and the run is marked dev")


## Spec animation-sets: `anim` shows a unit's view and set, plays a slot, refuses unknown slots; `create animation_set`
## writes a set that falls back to the default one.
func test_console_anim_and_animation_set_template() -> void:
	var session := _session()
	var shown := await _ok(session, "anim fixture.unit.striker")
	check(shown["text"].contains("(default)") and shown["text"].contains("idle"), "anim lists the default view's slots: " + shown["text"])
	var played := await _ok(session, "anim fixture.unit.striker hit")
	check(played["text"].contains("played hit"), "anim plays a slot: " + played["text"])
	check(not (await _run(session, "anim fixture.unit.striker dance"))["ok"], "an unknown slot is refused")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRATCH))
	var path := SCRATCH + "console_set.tres"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await _ok(session, "create animation_set test.anim.console_set " + SCRATCH)
	var created := load(path) as UnitAnimationSet
	check(created != null, "create writes an animation set")
	check(created != null and created.fallback != null, "that falls back to the default set")
	eq(ContentTemplates.default_folder("animation_set"), "res://presentation/demo/animation_sets/", "sets default to presentation")


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
	check(not not_effect["ok"] and not_effect["text"].contains("it is a RoomDefinition, not a GameplayEffect"),
		"a room file is refused, saying what it is: " + not_effect["text"])
	var missing := await _run(session, "effect res://nope.tres")
	check(not missing["ok"] and missing["text"].contains("could not open effect res://nope.tres: no such file"),
		"a missing file is refused, saying so: " + missing["text"])
	check((await _run(session, "effect"))["text"].begins_with("usage:"), "no argument → the usage")
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
## Spec ult-interrupts: `ult` queues a press for the next ult window; auto battles cast ready ults as interrupts.
func test_console_ult() -> void:
	var session := _session()
	await _ok(session, "new fixture.character.ultist,fixture.character.ultist 7")
	var run: RunController = session[0].run
	check(not (await _run(session, "ult P1 Fixture.Ability.UltSnipe E1"))["ok"], "ult outside a battle is refused")
	session[1].auto_battle = false
	await _ok(session, "spawn fixture.encounter.ult_trial")
	check(session[0].recorder.waiting_for != &"", "a party member waits")
	var refused := await _run(session, "ult P1 Fixture.Ability.Strike")
	check(not refused["ok"] and refused["text"].contains("Fixture.Ability.UltNova"), "not an ult: refused, ults listed: " + refused["text"])
	check(not (await _run(session, "ult E1 Fixture.Ability.UltSnipe"))["ok"], "an enemy can't be pressed")
	check(session[1].complete("ult P1 Fixture.Ability.UltS").has("ult P1 Fixture.Ability.UltSnipe"), "ult tags autocomplete")
	await _ok(session, "ult P1 Fixture.Ability.UltSnipe E3")
	var entries: Array = session[0].recorder.entries
	eq(entries.map(func(entry): return [entry["actor"], entry["ability"], entry["target"], entry.get("interrupt", false)]),
		[["P1", "Fixture.Ability.UltSnipe", "E3", true]], "the press fired in the waiting member's DECISION window")
	session[1].auto_battle = true
	await _ok(session, "act Fixture.Ability.Strike E1")
	check(run.pending_battle.is_empty(), "auto finishes the battle")
	var battle_entry: Dictionary = run.run_log[run.run_log.size() - 1]
	var interrupts: Array = battle_entry["actionLog"]["actions"].filter(func(entry): return entry.get("interrupt", false))
	check(interrupts.size() > 1, "auto battle casts ready ults out of turn: %d interrupts" % interrupts.size())


## Spec content-pass: `status` lists a unit's statuses (turns, stacks) in battle and is refused outside one.
func test_status_command() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	check(not (await _run(session, "status"))["ok"], "status outside a battle is refused")
	session[1].auto_battle = false
	await _ok(session, "spawn fixture.encounter.pack")
	var battle: Battle = session[0].run.get_node("RunBattle")
	var enemy := battle.unit_by_id(&"E1")
	for i in 2:
		enemy.asc.apply_gameplay_effect(load(FIXTURES + "effects/st_poison.tres"), enemy.asc, 1)
	eq((await _ok(session, "status E1"))["text"], "E1: Poison×2 3", "status shows stacks and turns left")
	check(not (await _run(session, "status E9"))["ok"], "an unknown unit is refused")
	check((await _ok(session, "status"))["text"].contains("P1: -"), "status alone lists every unit")


## Spec content-pass 3.8 (dev-tools remaining work): `kill` sent while an enemy acts is queued and applied at the next
## party decision, through the same RunController call the command makes.
func test_kill_queued_during_enemy_turn() -> void:
	var session := _session()
	await _ok(session, "new %s 7" % PARTY)
	var run: RunController = session[0].run
	session[1].auto_battle = false
	await _ok(session, "spawn fixture.encounter.pack")
	var battle: Battle = run.get_node("RunBattle")
	var queued := []
	battle.turn_started.connect(func(unit_id: StringName, turn: int) -> void:
		if queued.is_empty() and String(unit_id).begins_with("E"):
			queued.append(turn)
			check(session[0].recorder.waiting_for == &"", "no party member waits during an enemy turn")
			var reply: Dictionary = await session[1].execute("kill enemies")
			check(reply["ok"], "kill is accepted during an enemy turn: " + reply["text"]))
	for attempt in 6:
		if not queued.is_empty() or run.pending_battle.is_empty():
			break
		var waiting: StringName = session[0].recorder.waiting_for
		var unit: BattleUnit = battle.unit_by_id(waiting)
		var strike := unit.ability_by_tag(&"Fixture.Ability.Strike")
		await _run(session, "act %s %s" % [strike.ability_tag, battle.target_candidates(unit, strike)[0].unit_id])
	check(not queued.is_empty(), "an enemy turn came")
	if not run.pending_battle.is_empty() and session[0].recorder.waiting_for != &"":
		var waiting: StringName = session[0].recorder.waiting_for
		var unit: BattleUnit = battle.unit_by_id(waiting)
		var strike := unit.ability_by_tag(&"Fixture.Ability.Strike")
		await _run(session, "act %s %s" % [strike.ability_tag, battle.target_candidates(unit, strike)[0].unit_id])
	check(run.pending_battle.is_empty(), "the queued kill ended the battle at the next party decision")
	var battle_entry: Dictionary = run.run_log.filter(func(entry): return entry["type"] == "battle").back()
	eq(battle_entry["outcome"], Battle.VICTORY, "won through the kill")
	var kills: Array = battle_entry["actionLog"]["actions"].filter(func(entry): return entry["ability"] == "Dev.Kill")
	eq(kills.size(), 1, "the kill is logged once")
	check(not kills.is_empty() and int(kills[0]["turn"]) > int(queued[0]), "at a party decision after the enemy turn")


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


## Spec atomic-battles: `trace on` saves the client's trace and the request; the replay trace of that request matches.
func test_console_trace() -> void:
	var session := _session()
	var console: DevConsole = session[1]
	console.traces_dir = SCRATCH + "traces/"
	await _ok(session, "new fixture.character.ultist,fixture.character.ultist 7")
	check((await _ok(session, "trace on"))["text"].contains("trace on"), "trace on")
	await _ok(session, "spawn fixture.encounter.ult_trial")
	var run: RunController = session[0].run
	check(run.pending_battle.is_empty(), "the auto battle finished")
	var files := Array(DirAccess.get_files_at(console.traces_dir))
	var records := files.filter(func(file: String) -> bool: return file.ends_with(".record.json"))
	eq(records.size(), 1, "one battle traced: %s" % [files])
	if records.size() != 1:
		return
	var base: String = console.traces_dir + records[0].trim_suffix(".record.json")
	var recorded: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base + ".record.json"))
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base + ".request.json"))
	eq(recorded["verdict"], BattleTrace.RECORDED, "a client trace")
	check(recorded["points"].size() > 2 and recorded["points"][0].has("lines"), "with points and lines")
	var runner := ReplayRunner.new()
	runner.trace = BattleTrace.new(true)
	var result := await runner.run(request, FIXTURES, host)
	eq(result.get("verdict"), "Verified", "the saved request verifies")
	eq(BattleTrace.describe(BattleTrace.diff(recorded, runner.trace.to_json())), "traces match", "record vs replay")
	check((await _ok(session, "trace off"))["text"] == "trace off", "trace off")
	for file in DirAccess.get_files_at(console.traces_dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(console.traces_dir.path_join(file)))
