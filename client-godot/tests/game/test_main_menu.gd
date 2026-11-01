## Spec main-menu: the main menu in the Menu layer (Continue with a Local / Synced tag, New run, Settings, Quit, the mode
## line), the local save written after every action, Continue in local and server mode (fake bridge), the New run
## confirm, the seed field following the mode, and the run menu's Save and quit / Abandon run. Fixtures only.
extends TestCase

const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge
const PARTY: Array = ["fixture.character.knight", "fixture.character.medic"]
const RUN: StringName = &"fixture.run.two_floors"
const MENU: StringName = &"UI.Layer.Menu"
const MODAL: StringName = &"UI.Layer.Modal"
const RUN_ID: String = "019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b"

var _games: Array[GameMain] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


func _path() -> String:
	return "user://test_main_menu/%d_%d/run.json" % [OS.get_process_id(), Time.get_ticks_usec()]


func _game(save_path: String = "") -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	game.skip_animations = true
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	game.local_saves = true
	game.local_save_path = save_path if save_path != "" else _path()
	return game


func _link(bridge: FakeBridge, player_name: String = "tester") -> ServerLink:
	var link := ServerLink.new(bridge)
	link.player = player_name
	link.url = "http://fake:5000"
	link.saves_dir = "user://test_main_menu/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	return link


func _frames(count: int) -> void:
	for i in count:
		await host.get_tree().process_frame


func _menu(game: GameMain) -> UIScreen:
	return game.ui.top(MENU)


## Answers the confirm dialog that is up on the Modal layer.
func _answer(game: GameMain, yes: bool) -> bool:
	for i in 30:
		var dialog := game.ui.top(MODAL)
		if dialog is UIConfirm:
			dialog.decided.emit(yes)
			return true
		await host.get_tree().process_frame
	return false


func _current_run(status: String = "Active") -> Array:
	return [true, {"runId": RUN_ID, "status": status, "currentFloor": 1, "lastSeq": 3,
		"rulesetVersion": "x", "startedAt": "2026-11-01T10:00:00+00:00"}]


## Enters the first room the run lets the player enter (a logged action, so the save moves on).
func _enter_a_room(run: RunController) -> void:
	for index in range(0, 40):
		if run.can_enter(index):
			run.enter_room(index)
			return
	check(false, "the fixture run has a room to enter")


# --- M1, M4 ---------------------------------------------------------------------------------------------------------

func test_main_menu_in_local_mode() -> void:
	var game := _game()
	await _frames(3)
	var menu := _menu(game)
	check(menu != null and menu.name == "MainMenu", "the Menu layer shows the main menu")
	if menu == null:
		return
	for node in ["Continue", "NewRun", "Quit"]:
		check(menu.get_node("%" + node) != null, node + " exists")
	check(menu.get_node("%Continue").disabled, "no save: Continue is greyed")
	eq(menu.get_node("%ContinueInfo").text, "No run to continue", "and says why")
	eq(menu.get_node("%ModeLine").text, "Local mode (offline)", "the mode line")


func test_mode_line_in_server_mode() -> void:
	var game := _game()
	await _frames(2)
	game.use_server(_link(FakeBridge.new()))
	await _frames(3)
	eq(_menu(game).get_node("%ModeLine").text, "Server mode: http://fake:5000 as tester", "the mode line names url and player")
	game.use_server(null)
	await _frames(3)
	eq(_menu(game).get_node("%ModeLine").text, "Local mode (offline)", "and follows the mode")


# --- M2, M8 ---------------------------------------------------------------------------------------------------------

func test_new_run_pushes_class_pick_and_back_returns() -> void:
	var game := _game()
	await _frames(2)
	_menu(game).get_node("%NewRun").pressed.emit()
	await _frames(2)
	check(_menu(game).name == "TitleMenu", "New run opens the class pick")
	game.ui.back()
	await _frames(2)
	check(_menu(game).name == "MainMenu", "Back returns to the main menu")


func test_seed_field_follows_the_mode() -> void:
	var game := _game()
	await _frames(2)
	_menu(game).get_node("%NewRun").pressed.emit()
	await _frames(2)
	var title := _menu(game)
	check(title.get_node("%Seed").editable, "local mode: the seed can be typed")
	game.use_server(_link(FakeBridge.new()))
	check(not title.get_node("%Seed").editable, "linking disables the seed field at once")
	eq(title.get_node("%Seed").placeholder_text, "Seed: issued by the server", "with the note")
	game.use_server(null)
	check(title.get_node("%Seed").editable, "unlinking enables it again")
	await _frames(1)


func test_new_run_confirms_when_a_run_can_continue() -> void:
	var game := _game()
	eq(game.start_run(PARTY, "7", RUN), "", "a run to continue")
	game.save_and_quit()
	await _frames(3)
	_menu(game).get_node("%NewRun").pressed.emit()
	await _frames(2)
	_menu(game).get_node("%Start").pressed.emit()
	check(await _answer(game, false), "Start run asks first")
	await _frames(3)
	eq(game.mode, "menu", "No starts nothing")
	_menu(game).get_node("%Start").pressed.emit()
	check(await _answer(game, true), "asked again")
	await _frames(3)
	eq(game.mode, "run", "Yes starts the new run")


# --- M3, M5, M11 ----------------------------------------------------------------------------------------------------

func test_local_save_continue_round_trip() -> void:
	var path := _path()
	var game := _game(path)
	check(not FileAccess.file_exists(path), "no save before a run")
	eq(game.start_run(PARTY, "7", RUN), "", "the run starts")
	check(FileAccess.file_exists(path), "the first action wrote the save")
	_enter_a_room(game.run)
	var before := game.run.state.run_hash()
	game.save_and_quit()
	eq(game.mode, "menu", "Save and quit goes to the menu")
	await _frames(3)
	var menu := _menu(game)
	check(not menu.get_node("%Continue").disabled, "Continue is enabled")
	check(menu.get_node("%ContinueInfo").text.contains("floor 1"), "with the run: " + menu.get_node("%ContinueInfo").text)
	eq(menu.get_node("%Tag").text, "LOCAL", "tagged Local")
	eq(game.continue_local_run(), "", "Continue loads the save")
	eq(game.mode, "run", "and plays")
	eq(game.run.state.run_hash(), before, "the state hash equals the one before quitting")
	# An app restart: a fresh GameMain reads the same file.
	var again := _game(path)
	var info: Dictionary = await again.can_continue()
	check(info["enabled"], "a fresh game finds the save")
	eq(again.continue_local_run(), "", "and continues it")
	eq(again.run.state.run_hash(), before, "with the same state hash")


func test_continue_asks_first_and_no_loads_nothing() -> void:
	var game := _game()
	game.start_run(PARTY, "7", RUN)
	game.save_and_quit()
	await _frames(3)
	var hud_run := game.run
	_menu(game).get_node("%Continue").pressed.emit()
	check(await _answer(game, false), "Continue asks which kind of save it is")
	await _frames(2)
	eq(game.mode, "menu", "No stays on the main menu")
	check(game.run == hud_run, "and loads nothing")
	_menu(game).get_node("%Continue").pressed.emit()
	check(await _answer(game, true), "asked again")
	await _frames(3)
	eq(game.mode, "run", "Yes continues")


func test_save_deleted_when_the_run_ends_or_stops() -> void:
	var path := _path()
	var game := _game(path)
	game.start_run(PARTY, "7", RUN)
	check(FileAccess.file_exists(path), "saved")
	game.run.run_ended.emit("Lost")
	check(not FileAccess.file_exists(path), "a lost run deletes the save")
	game.start_run(PARTY, "8", RUN)
	check(FileAccess.file_exists(path), "a new run saves again")
	game.run.stop_on_server_error("boom")
	check(not FileAccess.file_exists(path), "a stopped run deletes the save")


func test_sandbox_and_headless_default_write_no_save() -> void:
	var path := _path()
	var game := _game(path)
	game.start_run(PARTY, "7", RUN)
	LocalSave.delete(path)
	game.run.state.sandbox = true
	game.save_local_run()
	check(not FileAccess.file_exists(path), "a sandbox run writes none")
	var plain: GameMain = load("res://game/game_main.tscn").instantiate()
	host.add_child(plain)
	_games.append(plain)
	check(not plain.local_saves, "headless runs save nothing unless a test turns it on")


func test_local_save_unreadable() -> void:
	var path := _path()
	var game := _game(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{ not json")
	file.close()
	var info: Dictionary = await game.can_continue()
	eq(info["reason"], "unreadable", "treated as no save")
	check(FileAccess.file_exists(path + ".bad") and not FileAccess.file_exists(path), "the file is kept as .bad")


func test_local_save_wont_load() -> void:
	var path := _path()
	var game := _game(path)
	game.start_run(PARTY, "7", RUN)
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	saved["snapshot"]["schemaVersion"] = 99
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(saved))
	file.close()
	game.back_to_menu()
	check(game.continue_local_run() != "", "the error comes back")
	eq(game.mode, "menu", "the mode stays the menu")
	check(FileAccess.file_exists(path), "and the save stays")


func test_local_save_atomic() -> void:
	var path := _path()
	var game := _game(path)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string("half a fi")
	file.close()
	var info: Dictionary = await game.can_continue()
	eq(info["reason"], "none", "a leftover .tmp is ignored")
	game.start_run(PARTY, "7", RUN)
	check(LocalSave.read(path)["state"] == "ok", "and replaced by a whole save")
	check(not FileAccess.file_exists(path + ".tmp"), "the tmp file is renamed away")


# --- M6, M11 (server) -----------------------------------------------------------------------------------------------

func test_server_continue_follows_connection() -> void:
	var game := _game()
	await _frames(2)
	var bridge := FakeBridge.new()
	bridge.offline = true
	bridge.answers = {"GetCurrentRun": [_current_run()]}
	var link := _link(bridge)
	game.use_server(link)
	await _frames(10)
	var menu := _menu(game)
	check(menu.get_node("%Continue").disabled, "offline: Continue is greyed")
	eq(menu.get_node("%ContinueInfo").text, "Can't reach the server", "with the reason")
	eq(bridge.count("GetCurrentRun"), 0, "nothing was asked of the server on its own at start-up")
	bridge.offline = false
	await link.heartbeat()
	await _frames(20)
	check(not menu.get_node("%Continue").disabled, "the server answers again: the menu asks again and enables Continue")
	eq(menu.get_node("%Tag").text, "SYNCED", "tagged Synced")
	check(game.run == null, "nothing resumed without a click")


func test_server_no_run_and_verifying() -> void:
	var game := _game()
	await _frames(2)
	var bridge := FakeBridge.new()
	bridge.answers = {"GetCurrentRun": [[true, null]]}
	game.use_server(_link(bridge))
	await _frames(15)
	eq(_menu(game).get_node("%ContinueInfo").text, "No run to continue", "204: no run")
	bridge.answers = {"GetCurrentRun": [_current_run("Verifying")]}
	var info: Dictionary = await game.can_continue()
	eq(info["reason"], "verifying", "a run being verified")
	await _frames(2)


func test_server_continue_pop_up_names_the_save() -> void:
	var game := _game()
	await _frames(2)
	var bridge := FakeBridge.new()
	bridge.answers = {"GetCurrentRun": [_current_run()]}
	game.use_server(_link(bridge))
	await _frames(15)
	_menu(game).get_node("%Continue").pressed.emit()
	for i in 30:
		if game.ui.top(MODAL) is UIConfirm:
			break
		await host.get_tree().process_frame
	var dialog := game.ui.top(MODAL)
	check(dialog is UIConfirm, "Continue asks first")
	if dialog is UIConfirm:
		check(dialog.get_node("%Text").text.contains("synced with the server as tester"), dialog.get_node("%Text").text)
		dialog.decided.emit(false)
	await _frames(3)
	eq(game.mode, "menu", "No stays on the menu")
	eq(bridge.count("Resume"), 0, "and resumes nothing")


# --- M7 -------------------------------------------------------------------------------------------------------------

func test_settings_server_section() -> void:
	var game := _game()
	await _frames(2)
	eq(game.connect_server("  "), "Enter the server url", "an empty url is refused")
	game.start_run(PARTY, "7", RUN)
	await _frames(2)
	var settings: UIScreen = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/settings.tscn"))
	await _frames(2)
	check(not settings.get_node("%Connect").is_queued_for_deletion() and settings.get_node("%Connect").disabled,
		"during a run Connect is off")
	check(not settings.get_node("%Url").editable, "and the fields are read-only")
	eq(settings.get_node("%ServerNote").text, "Switch modes from the main menu", "with the note")
	game.ui.back()
	game.back_to_menu()
	await _frames(2)
	var from_menu: UIScreen = game.ui.push(MENU, load("res://presentation/demo/ui/settings.tscn"))
	await _frames(2)
	check(from_menu.get_node("%Url").editable and not from_menu.get_node("%Connect").disabled, "on the main menu it is editable")
	check(from_menu.get_node("%Disconnect").disabled, "Disconnect needs a link")


# --- M9 -------------------------------------------------------------------------------------------------------------

func test_run_menu_save_and_quit_and_abandon() -> void:
	var path := _path()
	var game := _game(path)
	game.start_run(PARTY, "7", RUN)
	await _frames(2)
	var run_menu: UIScreen = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/run_menu.tscn"))
	await _frames(2)
	check(run_menu.get_node("%Abandon").visible, "local mode offers Abandon run")
	run_menu.get_node("%Abandon").pressed.emit()
	check(await _answer(game, true), "Abandon asks first")
	await _frames(3)
	eq(game.mode, "menu", "back at the main menu")
	check(not FileAccess.file_exists(path), "the save is deleted")
	game.start_run(PARTY, "7", RUN)
	await _frames(2)
	run_menu = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/run_menu.tscn"))
	await _frames(2)
	run_menu.get_node("%SaveQuit").pressed.emit()
	await _frames(3)
	eq(game.mode, "menu", "Save and quit goes to the menu")
	check(FileAccess.file_exists(path), "with the save kept")
	game.start_run(PARTY, "7", RUN)
	game.use_server(_link(FakeBridge.new()))
	await _frames(2)
	run_menu = game.ui.push(&"UI.Layer.GameMenu", load("res://presentation/demo/ui/run_menu.tscn"))
	await _frames(2)
	check(not run_menu.get_node("%Abandon").visible, "server mode has no Abandon run")


## Offline Continue: the server can't be reached but the player's server-mode save is playable; the pop-up says it isn't
## synced, and Continue loads the save without asking the server.
func test_server_offline_continue_from_the_save() -> void:
	var game := _game()
	game.start_run(PARTY, "7", RUN)
	_enter_a_room(game.run)
	var hash := game.run.state.run_hash()
	var snapshot := game.run.snapshot()
	game.back_to_menu()
	var bridge := FakeBridge.new()
	bridge.offline = true
	var link := _link(bridge)
	DirAccess.make_dir_recursive_absolute(link.save_path().get_base_dir())
	var file := FileAccess.open(link.save_path(), FileAccess.WRITE)
	file.store_string(WireJson.stringify({"schemaVersion": 1, "runId": RUN_ID, "player": "tester", "floorSeeds": {},
		"snapshot": snapshot, "queue": [], "lastAckedSeq": 0, "end": {}}))
	file.close()
	game.use_server(link)
	await _frames(15)
	var menu := _menu(game)
	check(not menu.get_node("%Continue").disabled, "offline with a save: Continue is enabled")
	eq(menu.get_node("%Tag").text, "NOT SYNCED", "tagged as not synced")
	menu.get_node("%Continue").pressed.emit()
	for i in 30:
		if game.ui.top(MODAL) is UIConfirm:
			break
		await host.get_tree().process_frame
	var dialog := game.ui.top(MODAL)
	check(dialog is UIConfirm and dialog.get_node("%Text").text.contains("hasn't been synced"), "the pop-up says so")
	if dialog is UIConfirm:
		dialog.decided.emit(true)
	await _frames(5)
	eq(game.mode, "run", "Yes continues")
	eq(game.run.state.run_hash(), hash, "from the saved state")
	eq(bridge.count("Resume"), 0, "without rebuilding from the server")
