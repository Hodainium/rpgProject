## Spec playtest-fixes B9, B10: the connecting pop-up and the server status line in the demo UI policy (slot
## UI.Slot.Overlay), over a ServerLink on the fake bridge (no network). Hidden in local mode.
extends TestCase

const FakeBridge = preload("res://tests/game/test_server_mode.gd").FakeBridge

var _games: Array[GameMain] = []


func after_each() -> void:
	for game in _games:
		if is_instance_valid(game):
			game.free()
	_games.clear()
	super()


func _game() -> GameMain:
	var game: GameMain = load("res://game/game_main.tscn").instantiate()
	host.add_child(game)
	_games.append(game)
	game.content_root = FIXTURES
	game.load_content()
	return game


func _link(bridge: FakeBridge, player_name: String) -> ServerLink:
	var link := ServerLink.new(bridge)
	link.player = player_name
	link.saves_dir = "user://test_server_ui/saves_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	return link


func _wait(seconds: float) -> void:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < seconds * 1000.0:
		await host.get_tree().process_frame


func test_connecting_popup() -> void:
	var game := _game()
	var popup: Control = game.find_child("ConnectingPopup", true, false)
	check(popup != null, "the pop-up is in the overlay slot")
	if popup == null:
		return
	check(not popup.showing(), "hidden in local mode")
	var link := _link(FakeBridge.new(), "tester")
	game.use_server(link)
	link.begin_wait(&"start", "Starting the run…")
	check(not popup.showing(), "a quick answer never flashes it")
	await _wait(0.45)
	check(popup.showing(), "shown once the wait lasts")
	eq(popup.get_node("%Text").text, "Starting the run…", "saying what the player waits on")
	eq(popup.get_node("%Popup").mouse_filter, Control.MOUSE_FILTER_STOP, "and blocks clicks")
	check(popup.get_node("%Spinner") is UISpinner, "with a spinner")
	link.end_wait(&"start")
	check(not popup.showing(), "gone when the wait ends")
	eq(popup.mouse_filter, Control.MOUSE_FILTER_IGNORE, "and clicks pass again")


func test_server_status_line() -> void:
	var game := _game()
	var status: Control = game.find_child("ServerStatus", true, false)
	check(status != null, "the status line is in the overlay slot")
	if status == null:
		return
	var text: Label = status.get_node("%Text")
	check(not text.visible, "hidden in local mode")
	var bridge := FakeBridge.new()
	var link := _link(bridge, "tester")
	game.use_server(link)
	await link.heartbeat()
	check(text.visible, "shown in server mode")
	eq(text.text, "Connected: tester (p)", "with the player name and id")
	eq(text.get_theme_color(&"font_color"), status.connected_color, "in bright green")
	var rect := text.get_global_rect()
	var screen := game.get_viewport().get_visible_rect().size
	check(rect.position.x < 40.0 and rect.end.y > screen.y - 40.0, "in the bottom left corner (%s)" % rect)
	bridge.offline = true
	await link.heartbeat()
	check(text.text.begins_with("Offline: tester"), "offline when the server stops answering: " + text.text)
	game.use_server(null)
	check(not text.visible, "hidden again in local mode")
	await host.get_tree().process_frame  # leave the bridge's Completed emission before after_each frees the game


## Spec playtest-fixes B11: a server error on the message line is replaced once the server answers again, also
## through a new link (the console's `server <url>` after starting the server).
func test_server_error_cleared_when_connected() -> void:
	var game := _game()
	var line: Label = game.find_child("MessageLine", true, false).get_node("%Text")
	var offline := FakeBridge.new()
	offline.offline = true
	game.use_server(_link(offline, "tester"))
	eq(await game.resume_server_run(), "no connection: HttpRequestException", "the server is off")
	check(line.text.begins_with("Server: no connection"), "the message line says so: " + line.text)
	var link := _link(FakeBridge.new(), "tester")
	game.use_server(link)
	await link.heartbeat()
	eq(line.text, "Connected to the server as tester", "and is replaced once the server answers")
	await host.get_tree().process_frame  # leave the bridge's Completed emission before after_each frees the game


## Spec playtest-fixes B12, as replaced by main-menu M6: nothing resumes on its own when the server answers again (the
## main menu re-asks and Continue waits for a click); the heartbeat is quicker while the server is away.
func test_heartbeat_quicker_while_offline() -> void:
	var game := _game()
	var bridge := FakeBridge.new()
	bridge.offline = true
	bridge.answers = {"GetCurrentRun": [[true, null]]}
	var link := _link(bridge, "tester")
	game.use_server(link)
	await link.heartbeat()
	eq(link.get_node("Heartbeat").wait_time, link.offline_heartbeat_seconds, "the heartbeat is quicker while offline")
	bridge.offline = false
	await link.heartbeat()
	for frame in 30:
		await host.get_tree().process_frame
	eq(link.get_node("Heartbeat").wait_time, link.heartbeat_seconds, "and the heartbeat slows down again")
	check(game.run == null and bridge.count("Resume") == 0, "nothing resumed on its own (the menu only asks)")
